// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMorpho, Id, Market, MarketParams, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "morpho-blue/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/src/libraries/SharesMathLib.sol";
import {IIdentityRegistry, IReputationRegistry} from "./interfaces/IERC8004.sol";

// Assumes 18 decimal collateral and 6 decimal loan token throughout
contract MorphoCreditRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    uint256 public constant MIN_LOAN_USDC = 10e6;
    int64 public constant PENALTY = 5;
    int64 public constant MAX_SCORE = 10;

    struct Loan {
        uint256 principal; // loan token borrowed through the router since the user was last debt free
        uint64 openedAt;
    }

    struct Credit {
        int64 score;
        uint32 repaid;
        uint32 liquidated;
    }

    struct AgentLink {
        uint256 id;
        bool set;
    }

    IMorpho public immutable morpho;
    uint64 public immutable minLoanAge;
    Id public immutable marketId;
    MarketParams public params;
    mapping(address user => Loan) public loans;
    mapping(address user => Credit) public credit;
    mapping(address user => AgentLink) public agentOf;
    IIdentityRegistry public identity;
    IReputationRegistry public reputation;

    event Paid(
        address indexed user,
        address indexed to,
        address indexed stock,
        uint256 amount,
        uint256 fee,
        uint256 collateralIn,
        bytes32 ref
    );
    event Repaid(address indexed user, address indexed stock, uint256 amount, bool counted);
    event Liquidated(
        address indexed user, address indexed stock, address liquidator, uint256 debt, uint256 seized, uint256 returned
    );
    event CreditUpdated(address indexed user, int256 score, uint256 ltvBps, uint256 feeBps);
    event AgentLinked(address indexed user, uint256 agentId);
    event MirrorFailed(address indexed user);

    constructor(IMorpho morpho_, MarketParams memory params_, uint64 minLoanAge_) Ownable(msg.sender) {
        morpho = morpho_;
        params = params_;
        marketId = params_.id();
        minLoanAge = minLoanAge_;
        IERC20(params_.loanToken).forceApprove(address(morpho_), type(uint256).max);
        IERC20(params_.collateralToken).forceApprove(address(morpho_), type(uint256).max);
    }

    function terms(address user) public view returns (uint256 ltvBps, uint256 feeBps, int256 score) {
        score = credit[user].score;
        if (score < 0) return (2500, 150, score);
        if (score < 3) return (3500, 100, score);
        if (score < 10) return (4000, 50, score);
        return (4500, 0, score);
    }

    // views cannot accrue, so this lags by the interest since the last Morpho accrual; state changing calls accrue first
    function debtOf(address user) public view returns (uint256) {
        return _assets(_shares(user));
    }

    function collateralValue(address user) public view returns (uint256) {
        return uint256(morpho.position(marketId, user).collateral) * IOracle(params.oracle).price() / 1e36;
    }

    function pay(uint256 collateralIn, uint256 amount, address to, bytes32 ref) external nonReentrant {
        require(amount > 0 && to != address(0), "bad args");
        MarketParams memory p = params;
        morpho.accrueInterest(p);
        uint256 debt = debtOf(msg.sender);
        Loan storage l = loans[msg.sender];
        // debt opened directly on Morpho has no openedAt, so the clock starts here
        if (debt == 0 || l.openedAt == 0) {
            l.openedAt = uint64(block.timestamp);
            l.principal = 0;
        }
        if (collateralIn > 0) {
            IERC20(p.collateralToken).safeTransferFrom(msg.sender, address(this), collateralIn);
            morpho.supplyCollateral(p, collateralIn, msg.sender, "");
        }
        l.principal += amount;
        (uint256 ltv, uint256 feeBps,) = terms(msg.sender);
        require((debt + amount) * 10_000 <= collateralValue(msg.sender) * ltv, "LTV");
        morpho.borrow(p, amount, 0, msg.sender, address(this));
        uint256 fee = amount * feeBps / 10_000;
        IERC20(p.loanToken).safeTransfer(to, amount - fee);
        emit Paid(msg.sender, to, p.collateralToken, amount, fee, collateralIn, ref);
    }

    function repay(uint256 amount) external nonReentrant {
        MarketParams memory p = params;
        morpho.accrueInterest(p);
        uint256 shares = _shares(msg.sender);
        require(shares > 0, "no debt");
        uint256 debt = _assets(shares);
        bool full = amount >= debt;
        uint256 repaid;
        // a full repay goes by shares, by assets it would leave dust
        if (full) {
            IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), debt);
            (repaid,) = morpho.repay(p, 0, shares, msg.sender, "");
        } else {
            IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), amount);
            (repaid,) = morpho.repay(p, amount, 0, msg.sender, "");
        }
        Loan memory l = loans[msg.sender];
        bool counted = full && block.timestamp - l.openedAt >= minLoanAge && l.principal >= MIN_LOAN_USDC
            && credit[msg.sender].score < MAX_SCORE;
        if (full) delete loans[msg.sender];
        if (counted) _score(msg.sender, 1, "repay");
        emit Repaid(msg.sender, p.collateralToken, repaid, counted);
    }

    function liquidate(address user) external nonReentrant {
        MarketParams memory p = params;
        morpho.accrueInterest(p);
        Position memory pos = morpho.position(marketId, user);
        require(pos.borrowShares > 0, "no debt");
        uint256 debt = _assets(pos.borrowShares);
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), debt);
        uint256 seized;
        uint256 repaid;
        // seizing for the whole debt exceeds the collateral once underwater, so take all collateral then
        try morpho.liquidate(p, user, 0, pos.borrowShares, "") returns (uint256 s, uint256 r) {
            (seized, repaid) = (s, r);
        } catch {
            (seized, repaid) = morpho.liquidate(p, user, pos.collateral, 0, "");
        }
        if (debt > repaid) IERC20(p.loanToken).safeTransfer(msg.sender, debt - repaid);
        IERC20(p.collateralToken).safeTransfer(msg.sender, seized);
        delete loans[user];
        _score(user, -PENALTY, "liquidation");
        emit Liquidated(user, p.collateralToken, msg.sender, repaid, seized, 0);
    }

    function linkAgent(uint256 agentId) external {
        require(address(identity) != address(0), "no identity");
        require(identity.isAuthorizedOrOwner(msg.sender, agentId), "not agent owner");
        agentOf[msg.sender] = AgentLink(agentId, true);
        emit AgentLinked(msg.sender, agentId);
    }

    function setRegistries(address identity_, address reputation_) external onlyOwner {
        identity = IIdentityRegistry(identity_);
        reputation = IReputationRegistry(reputation_);
    }

    function sweep(address to) external onlyOwner {
        IERC20 loan = IERC20(params.loanToken);
        loan.safeTransfer(to, loan.balanceOf(address(this)));
    }

    function _shares(address user) private view returns (uint256) {
        return morpho.position(marketId, user).borrowShares;
    }

    function _assets(uint256 shares) private view returns (uint256) {
        Market memory m = morpho.market(marketId);
        return shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }

    function _score(address user, int64 delta, string memory tag2) private {
        Credit storage c = credit[user];
        c.score += delta;
        if (delta > 0) c.repaid++;
        else c.liquidated++;
        (uint256 ltv, uint256 feeBps, int256 score) = terms(user);
        emit CreditUpdated(user, score, ltv, feeBps);
        _mirror(user, delta, tag2);
    }

    function _mirror(address user, int128 v, string memory tag2) internal {
        AgentLink memory a = agentOf[user];
        // calling an address without code reverts outside the try, so skip it
        if (!a.set || address(reputation).code.length == 0) return;
        try reputation.giveFeedback{gas: 300_000}(a.id, v, 0, "credit", tag2, "", "", bytes32(0)) {}
        catch {
            emit MirrorFailed(user);
        }
    }
}
