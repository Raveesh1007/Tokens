// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
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

    function test_fullRepayClearsDebtAndCounts() public {
        _pay(10e18, 700e6);
        vm.warp(block.timestamp + MIN_AGE + 1);
        uint256 before = usdc.balanceOf(alice);
        uint256 routerBefore = usdc.balanceOf(address(router));

        vm.expectEmit(true, false, false, true, address(router));
        emit CreditUpdated(alice, 1, 3500, 100);
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

        (bool found,) = _log(_repayLogs(type(uint256).max), CreditUpdated.selector);

        assertFalse(found);
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

        vm.expectEmit(true, false, false, true, address(router));
        emit CreditUpdated(alice, -5, 2500, 150);
        _liquidate();

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

        vm.expectRevert(bytes("position is healthy"));
        _liquidate();

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

        _liquidate();

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
        _liquidate();

        assertEq(_score(alice), -5);
        assertEq(rep.feedbackCount(), 0);
    }

    function test_payEmitsPaidForMerchant() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit Paid(alice, shop, address(nvda), 700e6, 7e6, 10e18, REF);
        _pay(10e18, 700e6);
    }

    function test_selfDrawEmitsPaidAndChargesFee() public {
        uint256 before = usdc.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(router));
        emit Paid(alice, alice, address(nvda), 100e6, 1e6, 10e18, REF);
        vm.prank(alice);
        router.pay(10e18, 100e6, alice, REF);

        assertEq(usdc.balanceOf(alice) - before, 99e6);
    }

    function test_liquidatedEventCarriesDebtAndSeized() public {
        _pay(10e18, 700e6);
        oracle.setPrice(_crashPrice());
        _fund(liq, 1_000e6);

        vm.recordLogs();
        _liquidate();
        (bool found, Vm.Log memory l) = _log(vm.getRecordedLogs(), Liquidated.selector);

        assertTrue(found);
        assertEq(address(uint160(uint256(l.topics[1]))), alice);
        assertEq(address(uint160(uint256(l.topics[2]))), address(nvda));
        (address liquidator, uint256 debt, uint256 seized, uint256 returned) =
            abi.decode(l.data, (address, uint256, uint256, uint256));
        assertEq(liquidator, liq);
        assertApproxEqAbs(debt, 700e6, 10);
        assertEq(debt, 1_000e6 - usdc.balanceOf(liq));
        assertEq(seized, nvda.balanceOf(liq));
        assertEq(returned, 0);
    }

    function test_sweepSendsTheFeeToTheTarget() public {
        _pay(10e18, 700e6);
        assertEq(usdc.balanceOf(address(router)), 7e6);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        router.sweep(bob);

        address treasury = address(0x7EA);
        router.sweep(treasury);

        assertEq(usdc.balanceOf(treasury), 7e6);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_underwaterLiquidationStillSucceeds() public {
        _pay(10e18, 700e6);
        oracle.setPrice(60e6);
        _fund(liq, 1_000e6);

        _liquidate();

        assertEq(nvda.balanceOf(liq), 10e18);
        assertLe(1_000e6 - usdc.balanceOf(liq), 600e6);
        _assertRouterHolds(7e6);
        assertEq(_pos(alice).borrowShares, 0);
        assertEq(_pos(alice).collateral, 0);
        assertEq(_score(alice), -5);
    }

    function test_routerHoldsOnlyTheFeeThroughPayRepayLiquidate() public {
        _pay(10e18, 700e6);
        _assertRouterHolds(7e6);

        _ageThenRepayAll();
        _assertRouterHolds(7e6);

        _pay(0, 700e6);
        _assertRouterHolds(14e6);

        oracle.setPrice(_crashPrice());
        _fund(liq, 1_000e6);
        _liquidate();
        _assertRouterHolds(14e6);
    }
}
