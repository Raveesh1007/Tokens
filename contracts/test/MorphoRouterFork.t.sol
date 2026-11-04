// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IMorpho, MarketParams, Id, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
import {Token} from "../src/Token.sol";
import {MockMorphoOracle} from "../src/MockMorphoOracle.sol";
import {MorphoCreditRouter} from "../src/MorphoCreditRouter.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {MockReputationRegistry} from "../src/mocks/MockReputationRegistry.sol";

// Run with: forge test --fork-url https://rpc.monad.xyz --match-contract MorphoRouterFork -vv
contract MorphoRouterFork is Test {
    using MarketParamsLib for MarketParams;

    event Repaid(address indexed user, address indexed stock, uint256 amount, bool counted);
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

    function setUp() public {
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

    function _repay(uint256 amount) internal returns (bool counted) {
        vm.recordLogs();
        vm.prank(alice);
        router.repay(amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == Repaid.selector) {
                (, counted) = abi.decode(logs[i].data, (uint256, bool));
                return counted;
            }
        }
        revert("no Repaid event");
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

    // pay

    function test_payBorrowsAtBaseTermsAndPaysShopNetOfFee() public {
        _pay(10e18, 700e6);

        assertEq(usdc.balanceOf(shop), 693e6);
        Position memory p = _pos(alice);
        assertEq(p.collateral, 10e18);
        assertGt(p.borrowShares, 0);
        assertEq(nvda.balanceOf(address(router)), 0);
        assertEq(nvda.balanceOf(alice), 0);
    }

    function test_payRevertsAboveTierLtv() public {
        vm.expectRevert(bytes("LTV"));
        _pay(10e18, 701e6);
    }

    function test_payRevertsWithoutMorphoAuthorization() public {
        vm.prank(bob);
        vm.expectRevert(bytes("unauthorized"));
        router.pay(10e18, 100e6, shop, REF);
    }

    // repay

    function test_fullRepayClearsDebtAndCounts() public {
        _pay(10e18, 700e6);
        vm.warp(block.timestamp + MIN_AGE + 1);
        uint256 before = usdc.balanceOf(alice);
        uint256 routerBefore = usdc.balanceOf(address(router));

        assertTrue(_repay(type(uint256).max));

        assertEq(_pos(alice).borrowShares, 0);
        assertEq(_score(alice), 1);
        (, uint32 repaid,) = router.credit(alice);
        assertEq(repaid, 1);
        uint256 spent = before - usdc.balanceOf(alice);
        assertGe(spent, 700e6);
        assertLt(spent, 701e6);
        assertEq(usdc.balanceOf(address(router)), routerBefore);
    }

    function test_repayAboveDebtRefundsSurplus() public {
        _pay(10e18, 700e6);
        vm.warp(block.timestamp + MIN_AGE + 1);
        uint256 before = usdc.balanceOf(alice);
        uint256 routerBefore = usdc.balanceOf(address(router));

        assertTrue(_repay(2_000e6));

        assertEq(_pos(alice).borrowShares, 0);
        assertLt(before - usdc.balanceOf(alice), 701e6);
        assertEq(usdc.balanceOf(address(router)), routerBefore);
    }

    function test_threeCountedLoopsReachTierOne() public {
        _loops(3);

        (uint256 ltvBps, uint256 feeBps, int256 score) = router.terms(alice);
        assertEq(ltvBps, 4000);
        assertEq(feeBps, 50);
        assertEq(score, 3);
    }

    function test_higherTierBorrowsMoreOnSameCollateral() public {
        _loops(3);

        vm.expectRevert(bytes("LTV"));
        _pay(0, 801e6);
        _pay(0, 800e6);
        assertEq(usdc.balanceOf(shop), 3 * 99e6 + 796e6);
    }

    function test_repayBeforeMinAgeDoesNotCount() public {
        _pay(10e18, 700e6);
        vm.warp(block.timestamp + MIN_AGE - 1);

        assertFalse(_repay(type(uint256).max));

        assertEq(_pos(alice).borrowShares, 0);
        assertEq(_score(alice), 0);
    }

    function test_sameBlockRepayDoesNotCount() public {
        _pay(10e18, 700e6);

        assertFalse(_repay(type(uint256).max));
        assertEq(_score(alice), 0);
    }

    function test_secondLoanRestartsTheClock() public {
        _pay(10e18, 700e6);
        assertTrue(_ageThenRepayAll());

        _pay(0, 100e6);
        vm.warp(block.timestamp + MIN_AGE / 2);
        assertFalse(_repay(type(uint256).max));

        assertEq(_score(alice), 1);
    }

    function test_partialRepayNeverCounts() public {
        _pay(10e18, 700e6);
        vm.warp(block.timestamp + MIN_AGE + 1);

        assertFalse(_repay(100e6));

        assertGt(_pos(alice).borrowShares, 0);
        assertEq(_score(alice), 0);
    }

    function test_fullClearAfterPartialCounts() public {
        _pay(10e18, 700e6);
        vm.warp(block.timestamp + MIN_AGE + 1);
        _repay(100e6);

        assertTrue(_repay(type(uint256).max));

        assertEq(_pos(alice).borrowShares, 0);
        assertEq(_score(alice), 1);
    }

    function test_directMorphoRepayDoesNotChangeScore() public {
        _pay(10e18, 700e6);
        vm.warp(block.timestamp + MIN_AGE + 1);
        uint128 shares = _pos(alice).borrowShares;

        vm.startPrank(alice);
        usdc.approve(address(MORPHO), type(uint256).max);
        MORPHO.repay(params, 0, shares, alice, "");
        vm.stopPrank();

        assertEq(_pos(alice).borrowShares, 0);
        (int256 score, uint32 repaid, uint32 liquidated) = router.credit(alice);
        assertEq(score, 0);
        assertEq(repaid, 0);
        assertEq(liquidated, 0);
    }

    // liquidation

    function test_liquidateSeizesToLiquidatorAndDropsScore() public {
        _pay(10e18, 700e6);
        uint256 price = _crashPrice();
        oracle.setPrice(price);
        _fund(liq, 1_000e6);

        vm.prank(liq);
        router.liquidate(alice);

        assertApproxEqAbs(1_000e6 - usdc.balanceOf(liq), 700e6, 10);
        assertApproxEqRel(nvda.balanceOf(liq), _expectedSeized(700e6, price), 1e12);
        assertEq(_pos(alice).borrowShares, 0);
        (int256 score, uint32 repaid, uint32 liquidated) = router.credit(alice);
        assertEq(score, -5);
        assertEq(repaid, 0);
        assertEq(liquidated, 1);
        (uint256 ltvBps, uint256 feeBps,) = router.terms(alice);
        assertEq(ltvBps, 2500);
        assertEq(feeBps, 150);
    }

    function test_liquidateRevertsWhenHealthy() public {
        _pay(10e18, 700e6);
        _fund(liq, 1_000e6);

        vm.prank(liq);
        vm.expectRevert(bytes("position is healthy"));
        router.liquidate(alice);

        assertEq(_score(alice), 0);
        assertGt(_pos(alice).borrowShares, 0);
    }

    // erc-8004 mirror

    function _linkAlice() internal returns (MockReputationRegistry rep) {
        MockIdentityRegistry ids = new MockIdentityRegistry();
        rep = new MockReputationRegistry();
        router.setRegistries(address(ids), address(rep));
        ids.setOwner(AGENT, alice);
        vm.prank(alice);
        router.linkAgent(AGENT);
    }

    function test_linkAgentRevertsForNonOwner() public {
        MockIdentityRegistry ids = new MockIdentityRegistry();
        router.setRegistries(address(ids), address(new MockReputationRegistry()));
        ids.setOwner(AGENT, alice);

        vm.prank(bob);
        vm.expectRevert(bytes("not agent owner"));
        router.linkAgent(AGENT);
    }

    function test_fullRepayWritesOneFeedback() public {
        MockReputationRegistry rep = _linkAlice();
        _pay(10e18, 700e6);

        assertTrue(_ageThenRepayAll());

        assertEq(rep.feedbackCount(), 1);
        (uint256 agentId, int128 value, uint8 decimals, string memory tag1, string memory tag2) = rep.feedbacks(0);
        assertEq(agentId, AGENT);
        assertEq(value, 1);
        assertEq(decimals, 0);
        assertEq(tag1, "credit");
        assertEq(tag2, "repay");
    }

    function test_liquidationWritesMinusFiveFeedback() public {
        MockReputationRegistry rep = _linkAlice();
        _pay(10e18, 700e6);
        oracle.setPrice(_crashPrice());
        _fund(liq, 1_000e6);

        vm.prank(liq);
        router.liquidate(alice);

        assertEq(rep.feedbackCount(), 1);
        (uint256 agentId, int128 value,, string memory tag1, string memory tag2) = rep.feedbacks(0);
        assertEq(agentId, AGENT);
        assertEq(value, -5);
        assertEq(tag1, "credit");
        assertEq(tag2, "liquidation");
    }

    function test_revertingRegistryDoesNotBlockRepay() public {
        MockReputationRegistry rep = _linkAlice();
        rep.setShouldRevert(true);
        _pay(10e18, 700e6);
        vm.warp(block.timestamp + MIN_AGE + 1);

        vm.expectEmit(true, false, false, false, address(router));
        emit MirrorFailed(alice);
        assertTrue(_repay(type(uint256).max));

        assertEq(_pos(alice).borrowShares, 0);
        assertEq(_score(alice), 1);
        assertEq(rep.feedbackCount(), 0);
    }

    function test_revertingRegistryDoesNotBlockLiquidate() public {
        MockReputationRegistry rep = _linkAlice();
        rep.setShouldRevert(true);
        _pay(10e18, 700e6);
        oracle.setPrice(_crashPrice());
        _fund(liq, 1_000e6);

        vm.expectEmit(true, false, false, false, address(router));
        emit MirrorFailed(alice);
        vm.prank(liq);
        router.liquidate(alice);

        assertEq(_score(alice), -5);
        assertEq(rep.feedbackCount(), 0);
    }
}
