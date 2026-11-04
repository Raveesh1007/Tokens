// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIdentityRegistry, IReputationRegistry} from "./interfaces/IERC8004.sol";

// Assumes 18 decimal stocks and 6 decimal USDC throughout
contract Vault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant LIQ_BPS = 6500;
    uint256 public constant LIQ_BONUS_BPS = 500;
    uint256 public constant MIN_LOAN_USDC = 10e6;
    int64 public constant PENALTY = 5;
    int64 public constant MAX_SCORE = 10;

    struct Position {
        uint256 collateral; // stock units (18 dec)
        uint256 debt; // USDC units (6 dec)
        uint256 principal; // USDC borrowed since the position was last empty
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

    IERC20 public immutable usdc;
    uint64 public immutable minLoanAge;
    address public oracle;
    // USDC units per 1e18 stock units, 0 = unlisted; owner-set for now, Pyth is the swap
    mapping(address stock => uint256) public price;
    mapping(address user => mapping(address stock => Position)) public positions;
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
    event Withdrawn(address indexed user, address indexed stock, uint256 amount);
    event Liquidated(
        address indexed user, address indexed stock, address liquidator, uint256 debt, uint256 seized, uint256 returned
    );
    event CreditUpdated(address indexed user, int256 score, uint256 ltvBps, uint256 feeBps);
    event AgentLinked(address indexed user, uint256 agentId);
    event MirrorFailed(address indexed user);
    event PriceSet(address indexed stock, uint256 price);

    constructor(IERC20 usdc_, uint64 minLoanAge_) Ownable(msg.sender) {
        usdc = usdc_;
        minLoanAge = minLoanAge_;
        oracle = msg.sender;
    }

    function terms(address user) public view returns (uint256 ltvBps, uint256 feeBps, int256 score) {
        score = credit[user].score;
        if (score < 0) return (2500, 150, score);
        if (score < 3) return (3500, 100, score);
        if (score < 10) return (4000, 50, score);
        return (4500, 0, score);
    }

    function value(address stock, uint256 amount) public view returns (uint256) {
        return amount * price[stock] / 1e18;
    }

    function collateralFor(address stock, uint256 amount, address user) external view returns (uint256) {
        uint256 p = price[stock];
        require(p > 0, "unlisted");
        (uint256 ltv,,) = terms(user);
        // round the needed value up first so value() of the result still clears the LTV check
        uint256 need = (amount * 10_000 + ltv - 1) / ltv;
        return (need * 1e18 + p - 1) / p;
    }

    function liquidatable(address user, address stock) public view returns (bool) {
        Position memory p = positions[user][stock];
        return p.debt * 10_000 > value(stock, p.collateral) * LIQ_BPS;
    }

    function pay(address stock, uint256 collateralIn, uint256 amount, address to, bytes32 ref) external nonReentrant {
        require(price[stock] > 0, "unlisted");
        require(amount > 0 && to != address(0), "bad args");
        Position storage p = positions[msg.sender][stock];
        if (p.debt == 0) {
            p.openedAt = uint64(block.timestamp);
            p.principal = 0;
        }
        p.collateral += collateralIn;
        p.debt += amount;
        p.principal += amount;
        (uint256 ltv, uint256 feeBps,) = terms(msg.sender);
        require(_healthy(p, stock, ltv), "LTV");
        uint256 fee = amount * feeBps / 10_000;
        if (collateralIn > 0) IERC20(stock).safeTransferFrom(msg.sender, address(this), collateralIn);
        usdc.safeTransfer(to, amount - fee);
        emit Paid(msg.sender, to, stock, amount, fee, collateralIn, ref);
    }

    function repay(address stock, uint256 amount) external nonReentrant {
        Position storage p = positions[msg.sender][stock];
        if (amount > p.debt) amount = p.debt;
        bool cleared = amount > 0 && amount == p.debt;
        bool counted = cleared && block.timestamp - p.openedAt >= minLoanAge && p.principal >= MIN_LOAN_USDC
            && credit[msg.sender].score < MAX_SCORE;
        p.debt -= amount;
        if (cleared) {
            p.principal = 0;
            p.openedAt = 0;
        }
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        if (counted) _score(msg.sender, 1, "repay");
        emit Repaid(msg.sender, stock, amount, counted);
    }

    function withdraw(address stock, uint256 amount) external nonReentrant {
        Position storage p = positions[msg.sender][stock];
        if (amount > p.collateral) amount = p.collateral;
        p.collateral -= amount;
        (uint256 ltv,,) = terms(msg.sender);
        require(_healthy(p, stock, ltv), "LTV");
        IERC20(stock).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, stock, amount);
    }

    function liquidate(address user, address stock) external nonReentrant {
        uint256 px = price[stock];
        require(px > 0, "unlisted");
        require(liquidatable(user, stock), "healthy");
        Position memory p = positions[user][stock];
        uint256 owed = (p.debt * (10_000 + LIQ_BONUS_BPS) * 1e18 + px * 10_000 - 1) / (px * 10_000);
        uint256 seized = owed < p.collateral ? owed : p.collateral;
        uint256 returned = p.collateral - seized;
        delete positions[user][stock];
        usdc.safeTransferFrom(msg.sender, address(this), p.debt);
        IERC20(stock).safeTransfer(msg.sender, seized);
        if (returned > 0) IERC20(stock).safeTransfer(user, returned);
        _score(user, -PENALTY, "liquidation");
        emit Liquidated(user, stock, msg.sender, p.debt, seized, returned);
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

    function setPrice(address stock, uint256 p) external {
        require(msg.sender == oracle, "not oracle");
        price[stock] = p;
        emit PriceSet(stock, p);
    }

    function setOracle(address o) external onlyOwner {
        oracle = o;
    }

    function _healthy(Position storage p, address stock, uint256 ltvBps) private view returns (bool) {
        return p.debt * 10_000 <= value(stock, p.collateral) * ltvBps;
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
