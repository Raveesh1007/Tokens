// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IMorpho, MarketParams, Id, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
import {Token} from "../src/Token.sol";
import {MockMorphoOracle} from "../src/MockMorphoOracle.sol";
import {MorphoCreditRouter} from "../src/MorphoCreditRouter.sol";

// Shared Morpho market, router and actors for the fork suites; skips itself unless chain id is 143
abstract contract MorphoForkBase is Test {
    using MarketParamsLib for MarketParams;

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
    event MirrorFailed(address indexed user);

    IMorpho constant MORPHO = IMorpho(0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee);
    address constant IRM = 0x09475a3D6eA8c314c592b1a3799bDE044E2F400F;
    uint64 constant MIN_AGE = 1 hours;
    uint256 constant AGENT = 7;
    bytes32 constant REF = keccak256("order-1");

    Token usdc;
    Token nvda;
    MockMorphoOracle oracle;
    MorphoCreditRouter router;
    MarketParams params;
    Id id;
    uint256 lltv;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address shop = address(0x5409);
    address liq = address(0x11C);

    function setUp() public virtual {
        if (block.chainid != 143) {
            vm.skip(true);
            return;
        }
        lltv = vm.envOr("LLTV", uint256(0.625e18));
        usdc = new Token("Mock USDC", "mUSDC", 6, false);
        nvda = new Token("Mock NVIDIA", "mNVDA", 18, true);
        oracle = new MockMorphoOracle(200e6);
        params = MarketParams(address(usdc), address(nvda), address(oracle), IRM, lltv);
        id = params.id();
        MORPHO.createMarket(params);

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(MORPHO), type(uint256).max);
        MORPHO.supply(params, 1_000_000e6, 0, address(this), "");

        router = new MorphoCreditRouter(MORPHO, params, MIN_AGE);

        // borrowed USDC goes to the shop, so alice needs her own to repay
        _fund(alice, 5_000e6);
        nvda.mint(alice, 10e18);
        vm.startPrank(alice);
        nvda.approve(address(router), type(uint256).max);
        MORPHO.setAuthorization(address(router), true);
        vm.stopPrank();

        nvda.mint(bob, 10e18);
        vm.prank(bob);
        nvda.approve(address(router), type(uint256).max);
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(router), type(uint256).max);
    }

    function _pay(uint256 collateralIn, uint256 amount) internal {
        vm.prank(alice);
        router.pay(collateralIn, amount, shop, REF);
    }

    function _pos(address who) internal view returns (Position memory) {
        return MORPHO.position(id, who);
    }

    function _score(address who) internal view returns (int256 score) {
        (score,,) = router.credit(who);
    }

    function _log(Vm.Log[] memory logs, bytes32 sig) internal view returns (bool found, Vm.Log memory l) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == sig) return (true, logs[i]);
        }
    }

    function _repayLogs(uint256 amount) internal returns (Vm.Log[] memory) {
        vm.recordLogs();
        vm.prank(alice);
        router.repay(amount);
        return vm.getRecordedLogs();
    }

    function _repay(uint256 amount) internal returns (bool counted) {
        (bool found, Vm.Log memory l) = _log(_repayLogs(amount), Repaid.selector);
        require(found, "no Repaid event");
        (, counted) = abi.decode(l.data, (uint256, bool));
    }

    function _liquidate() internal {
        vm.prank(liq);
        router.liquidate(alice);
    }

    function _assertRouterHolds(uint256 fees) internal view {
        assertEq(nvda.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(address(router)), fees);
    }

    function _ageThenRepayAll() internal returns (bool) {
        vm.warp(block.timestamp + MIN_AGE + 1);
        return _repay(type(uint256).max);
    }

    function _loops(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            _pay(i == 0 ? 10e18 : 0, 100e6);
            assertTrue(_ageThenRepayAll());
        }
    }

    // 700e6 of debt against $2000 collateral, then a price that puts LTV just above the market LLTV
    function _crashPrice() internal view returns (uint256) {
        return 700e6 * 1e18 * 98 / lltv / 1000;
    }

    // Morpho's published liquidation incentive factor, capped at 1.15
    function _expectedSeized(uint256 debt, uint256 price) internal view returns (uint256) {
        uint256 lif = 1e36 / (1e18 - 0.3e18 * (1e18 - lltv) / 1e18);
        if (lif > 1.15e18) lif = 1.15e18;
        return debt * lif / 1e18 * 1e18 / price;
    }
}
