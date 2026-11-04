// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// Lock tokenized stock, borrow USDC at 35% LTV, and pay a merchant in one tx.
contract Vault is Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant LTV_BPS = 3500; // max borrow
    uint256 public constant LIQ_BPS = 6500; // liquidation threshold
    uint256 public constant FEE_BPS = 100; // 1% merchant fee, stays in the vault as liquidity

    struct Position {
        uint256 collateral; // stock units (18 dec)
        uint256 debt; // USDC units (6 dec)
    }

    IERC20 public immutable usdc;
    address public oracle;
    // Share price in USDC (6 dec) per 1e18 stock units, set by the oracle; 0 = unlisted.
    mapping(address stock => uint256) public price;
    mapping(address user => mapping(address stock => Position)) public positions;

    event Paid(address indexed user, address indexed to, address indexed stock, uint256 amount, uint256 fee, uint256 collateralIn, bytes32 ref);
    event Repaid(address indexed user, address indexed stock, uint256 amount);
    event Withdrawn(address indexed user, address indexed stock, uint256 amount);
    event Liquidated(address indexed user, address indexed stock, address liquidator, uint256 debt, uint256 collateral);
    event PriceSet(address indexed stock, uint256 price);

    constructor(IERC20 usdc_) Ownable(msg.sender) {
        usdc = usdc_;
        oracle = msg.sender;
    }

    // ---- views ----

    function value(address stock, uint256 amount) public view returns (uint256) {
        return amount * price[stock] / 1e18;
    }

    /// Collateral needed to borrow `amount` USDC from an empty position (rounded up).
    function collateralFor(address stock, uint256 amount) external view returns (uint256) {
        uint256 p = price[stock];
        require(p > 0, "unlisted");
        return (amount * 1e18 * 10_000 + p * LTV_BPS - 1) / (p * LTV_BPS);
    }

    function liquidatable(address user, address stock) public view returns (bool) {
        Position memory p = positions[user][stock];
        return p.debt > 0 && p.debt * 10_000 > value(stock, p.collateral) * LIQ_BPS;
    }

    // ---- user ----

    // Lock collateral, borrow `amount` USDC, send it minus fee to `to` (no fee if to == msg.sender).
    function pay(address stock, uint256 collateralIn, uint256 amount, address to, bytes32 ref) external {
        require(price[stock] > 0, "unlisted");
        require(amount > 0 && to != address(0), "bad args");
        Position storage p = positions[msg.sender][stock];
        if (collateralIn > 0) IERC20(stock).safeTransferFrom(msg.sender, address(this), collateralIn);
        p.collateral += collateralIn;
        p.debt += amount;
        require(_healthy(p, stock), "LTV");
        uint256 fee = to == msg.sender ? 0 : amount * FEE_BPS / 10_000;
        usdc.safeTransfer(to, amount - fee);
        emit Paid(msg.sender, to, stock, amount, fee, collateralIn, ref);
    }

    function repay(address stock, uint256 amount) external {
        Position storage p = positions[msg.sender][stock];
        if (amount > p.debt) amount = p.debt;
        p.debt -= amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Repaid(msg.sender, stock, amount);
    }

    function withdraw(address stock, uint256 amount) external {
        Position storage p = positions[msg.sender][stock];
        if (amount > p.collateral) amount = p.collateral;
        p.collateral -= amount;
        require(_healthy(p, stock), "LTV");
        IERC20(stock).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, stock, amount);
    }

    /// Anyone can repay an unhealthy position's full debt and take all its collateral.
    function liquidate(address user, address stock) external {
        require(liquidatable(user, stock), "healthy");
        Position memory p = positions[user][stock];
        delete positions[user][stock];
        usdc.safeTransferFrom(msg.sender, address(this), p.debt);
        IERC20(stock).safeTransfer(msg.sender, p.collateral);
        emit Liquidated(user, stock, msg.sender, p.debt, p.collateral);
    }

    // ---- admin ----

    function setPrice(address stock, uint256 p) external {
        require(msg.sender == oracle, "not oracle");
        price[stock] = p;
        emit PriceSet(stock, p);
    }

    function setOracle(address o) external onlyOwner {
        oracle = o;
    }

    function _healthy(Position storage p, address stock) private view returns (bool) {
        return p.debt * 10_000 <= value(stock, p.collateral) * LTV_BPS;
    }
}
