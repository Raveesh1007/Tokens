// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Token} from "../src/Token.sol";
import {Vault} from "../src/Vault.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {MockReputationRegistry} from "../src/mocks/MockReputationRegistry.sol";

// any call burns all the gas it is given
contract GasBurner {
    fallback() external {
        while (true) {}
    }
}

contract VaultTest is Test {
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

    uint64 constant MIN_AGE = 1 hours;
    uint256 constant AGENT = 7;
    uint256 constant TX_GAS = 5_000_000;
    uint256 constant MAX_GAS_USED = 450_000;

    Token usdc;
    Token nvda;
    Vault vault;
    MockIdentityRegistry ids;
    MockReputationRegistry rep;
    address alice = address(0xA11CE);
    address shop = address(0x5409);
    address liq = address(0x11C);

    function setUp() public {
        usdc = new Token("Mock USDC", "mUSDC", 6, false);
        nvda = new Token("Mock NVIDIA", "mNVDA", 18, true);
        vault = new Vault(usdc, MIN_AGE);
        ids = new MockIdentityRegistry();
        rep = new MockReputationRegistry();
        vault.setRegistries(address(ids), address(rep));
        ids.setOwner(AGENT, alice);
        usdc.mint(address(vault), 10_000_000e6);
        vault.setPrice(address(nvda), 200e6); // $200/share, so 10e18 is $2000
        nvda.mint(alice, 10e18);
        usdc.mint(alice, 10_000e6);
        usdc.mint(liq, 10_000e6);
        vm.startPrank(alice);
        nvda.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(liq);
        nvda.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _pay(address who, uint256 collateralIn, uint256 amount) internal {
        vm.prank(who);
        vault.pay(address(nvda), collateralIn, amount, shop, "");
    }

    function _repayAll(address who) internal {
        vm.prank(who);
        vault.repay(address(nvda), type(uint256).max);
    }

    // opens a loan (depositing 10e18 on first use), waits, clears it and checks the counted flag
    function _cycle(address who, uint256 amount, uint256 age, bool counted) internal {
        (uint256 held,,,) = _position(who);
        _pay(who, held == 0 ? 10e18 : 0, amount);
        vm.warp(block.timestamp + age);
        _expectRepaid(who, amount, counted);
        _repayAll(who);
    }

    function _counted(address who, uint256 n) internal {
        for (uint256 i; i < n; i++) {
            _cycle(who, 100e6, MIN_AGE, true);
        }
    }

    function _repayExpectingCredit(int256 score, uint256 ltv, uint256 fee) internal {
        _pay(alice, 0, 100e6);
        vm.warp(block.timestamp + MIN_AGE);
        vm.expectEmit(address(vault));
        emit CreditUpdated(alice, score, ltv, fee);
        _repayAll(alice);
    }

    function _liquidate() internal {
        vm.prank(liq);
        vault.liquidate(alice, address(nvda));
    }

    function _link() internal {
        vm.prank(alice);
        vault.linkAgent(AGENT);
    }

    function _assertTerms(address who, uint256 ltv, uint256 fee, int256 score) internal view {
        (uint256 l, uint256 f, int256 s) = vault.terms(who);
        assertEq(l, ltv);
        assertEq(f, fee);
        assertEq(s, score);
    }

    function _assertFeedback(uint256 i, int128 value, string memory tag2) internal view {
        (uint256 id, int128 v, uint8 dec, string memory t1, string memory t2) = rep.feedbacks(i);
        assertEq(id, AGENT);
        assertEq(v, value);
        assertEq(dec, 0);
        assertEq(t1, "credit");
        assertEq(t2, tag2);
    }

    function _expectRepaid(address who, uint256 amount, bool counted) internal {
        vm.expectEmit(address(vault));
        emit Repaid(who, address(nvda), amount, counted);
    }

    function _position(address who) internal view returns (uint256 c, uint256 d, uint256 p, uint64 t) {
        return vault.positions(who, address(nvda));
    }

    function _score(address who) internal view returns (int64 s) {
        (s,,) = vault.credit(who);
    }

    function test_newWalletTerms() public view {
        _assertTerms(alice, 3500, 100, 0);
    }

    function test_payAtExactLtvSucceedsAndOneAboveReverts() public {
        vm.expectRevert(bytes("LTV"));
        _pay(alice, 10e18, 700e6 + 1);

        vm.expectEmit(address(vault));
        emit Paid(alice, shop, address(nvda), 700e6, 7e6, 10e18, "order-1");
        vm.prank(alice);
        vault.pay(address(nvda), 10e18, 700e6, shop, "order-1");

        assertEq(nvda.balanceOf(alice), 0);
    }

    function test_collateralForMatchesMaxBorrow() public {
        assertEq(vault.collateralFor(address(nvda), 700e6, alice), 10e18);
        assertGt(vault.collateralFor(address(nvda), 700e6 + 1, alice), 10e18);

        _counted(alice, 3);
        assertEq(vault.collateralFor(address(nvda), 800e6, alice), 10e18);
        uint256 need = vault.collateralFor(address(nvda), 1_234_567, alice);
        nvda.mint(alice, need);
        _pay(alice, need, 1_234_567);
    }

    function test_feeOnMerchantPayAndSelfDraw() public {
        _pay(alice, 10e18, 100e6);
        assertEq(usdc.balanceOf(shop), 99e6);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.pay(address(nvda), 0, 100e6, alice, "");
        assertEq(usdc.balanceOf(alice) - before, 99e6);
    }

    function test_repayBeforeMinAgeDoesNotCount() public {
        _cycle(alice, 100e6, MIN_AGE - 1, false);
        _assertTerms(alice, 3500, 100, 0);

        // exactly minLoanAge is old enough
        _cycle(alice, 100e6, MIN_AGE, true);
        assertEq(_score(alice), 1);
    }

    function test_repayBelowMinLoanDoesNotCount() public {
        _cycle(alice, 10e6 - 1, MIN_AGE, false);
        assertEq(_score(alice), 0);

        // exactly 10 USDC is big enough
        _cycle(alice, 10e6, MIN_AGE, true);
        assertEq(_score(alice), 1);
    }

    function test_topUpsAddUpToMinLoan() public {
        _pay(alice, 10e18, 6e6);
        _pay(alice, 0, 6e6);
        vm.warp(block.timestamp + MIN_AGE);
        _expectRepaid(alice, 12e6, true);
        _repayAll(alice);
        assertEq(_score(alice), 1);
    }

    function test_partialRepayNeverCounts() public {
        _pay(alice, 10e18, 100e6);
        vm.warp(block.timestamp + MIN_AGE);

        _expectRepaid(alice, 40e6, false);
        vm.prank(alice);
        vault.repay(address(nvda), 40e6);
        assertEq(_score(alice), 0);

        _expectRepaid(alice, 60e6, true);
        _repayAll(alice);
        assertEq(_score(alice), 1);
    }

    function test_countedRepaysMoveTiers() public {
        _counted(alice, 2);
        _assertTerms(alice, 3500, 100, 2);
        _repayExpectingCredit(3, 4000, 50);
        _assertTerms(alice, 4000, 50, 3);
        _counted(alice, 6);
        _assertTerms(alice, 4000, 50, 9);
        _repayExpectingCredit(10, 4500, 0);
        _assertTerms(alice, 4500, 0, 10);
        (, uint32 repaid,) = vault.credit(alice);
        assertEq(repaid, 10);
    }

    function test_higherTiersBorrowMoreOnSameCollateral() public {
        _counted(alice, 3);
        uint256 before = usdc.balanceOf(shop);
        vm.expectRevert(bytes("LTV"));
        _pay(alice, 0, 800e6 + 1);
        _cycle(alice, 800e6, MIN_AGE, true);
        assertEq(usdc.balanceOf(shop) - before, 796e6);

        _counted(alice, 6);
        before = usdc.balanceOf(shop);
        vm.expectRevert(bytes("LTV"));
        _pay(alice, 0, 900e6 + 1);
        _pay(alice, 0, 900e6);
        assertEq(usdc.balanceOf(shop) - before, 900e6);
    }

    function test_liquidationSeizesDebtPlusBonus() public {
        _pay(alice, 10e18, 700e6);
        vault.setPrice(address(nvda), 100e6);
        assertTrue(vault.liquidatable(alice, address(nvda)));
        uint256 liqUsdc = usdc.balanceOf(liq);

        vm.expectEmit(address(vault));
        emit CreditUpdated(alice, -5, 2500, 150);
        vm.expectEmit(address(vault));
        emit Liquidated(alice, address(nvda), liq, 700e6, 7.35e18, 2.65e18);
        _liquidate();

        assertEq(nvda.balanceOf(liq), 7.35e18);
        assertEq(nvda.balanceOf(alice), 2.65e18);
        assertEq(liqUsdc - usdc.balanceOf(liq), 700e6);
        (uint256 c, uint256 d, uint256 p, uint64 t) = _position(alice);
        assertEq(c + d + p + t, 0);
        (int64 s, uint32 repaid, uint32 liquidated) = vault.credit(alice);
        assertEq(s, -5);
        assertEq(repaid, 0);
        assertEq(liquidated, 1);
        _assertTerms(alice, 2500, 150, -5);
    }

    function test_liquidationCapsSeizedAtCollateral() public {
        _pay(alice, 10e18, 700e6);
        vault.setPrice(address(nvda), 60e6);

        vm.expectEmit(address(vault));
        emit Liquidated(alice, address(nvda), liq, 700e6, 10e18, 0);
        _liquidate();
        assertEq(nvda.balanceOf(liq), 10e18);
    }

    function test_liquidationRoundsSeizedUp() public {
        _pay(alice, 10e18, 700e6);
        vault.setPrice(address(nvda), 107e6);
        assertTrue(vault.liquidatable(alice, address(nvda)));
        _liquidate();
        // 735e6 usdc of shares at 107e6 per share, 735e6 * 1e18 / 107e6 rounded up
        assertEq(nvda.balanceOf(liq), 6_869_158_878_504_672_898);
        assertEq(nvda.balanceOf(alice), 10e18 - 6_869_158_878_504_672_898);
    }

    function test_liquidateHealthyReverts() public {
        vm.expectRevert(bytes("healthy"));
        _liquidate();

        _pay(alice, 10e18, 650e6);
        // value 1000e6, debt exactly 65% of it
        vault.setPrice(address(nvda), 100e6);
        assertFalse(vault.liquidatable(alice, address(nvda)));
        vm.expectRevert(bytes("healthy"));
        _liquidate();

        vault.setPrice(address(nvda), 100e6 - 1);
        assertTrue(vault.liquidatable(alice, address(nvda)));
    }

    function test_liquidateAtZeroPriceReverts() public {
        _pay(alice, 10e18, 700e6);
        vault.setPrice(address(nvda), 0);
        vm.expectRevert(bytes("unlisted"));
        _liquidate();
    }

    function test_withdrawRespectsBaseTier() public {
        _pay(alice, 10e18, 350e6);
        vm.startPrank(alice);
        vm.expectRevert(bytes("LTV"));
        vault.withdraw(address(nvda), 5e18 + 1);

        vm.expectEmit(address(vault));
        emit Withdrawn(alice, address(nvda), 5e18);
        vault.withdraw(address(nvda), 5e18);
        vm.stopPrank();

        assertEq(nvda.balanceOf(alice), 5e18);
    }

    function test_withdrawRespectsHigherTier() public {
        _counted(alice, 3);
        _pay(alice, 0, 400e6);
        vm.startPrank(alice);
        vm.expectRevert(bytes("LTV"));
        vault.withdraw(address(nvda), 5e18 + 1);
        // base tier would need 5.71e18 left against this debt
        vault.withdraw(address(nvda), 5e18);
        vm.stopPrank();
        assertEq(nvda.balanceOf(alice), 5e18);
    }

    function test_flow() public {
        _pay(alice, 10e18, 700e6);
        assertEq(usdc.balanceOf(shop), 693e6);

        vm.prank(alice);
        vm.expectRevert(bytes("LTV"));
        vault.withdraw(address(nvda), 1e18);

        _repayAll(alice);
        vm.prank(alice);
        vault.withdraw(address(nvda), type(uint256).max);
        assertEq(nvda.balanceOf(alice), 10e18);
    }

    function test_sameBlockBorrowAndRepayNeverCounts() public {
        _counted(alice, 1);
        for (uint256 i; i < 5; i++) {
            _cycle(alice, 500e6, 0, false);
        }
        _assertTerms(alice, 3500, 100, 1);
    }

    function test_repayAtMaxScoreDoesNotCount() public {
        _link();
        _counted(alice, 10);
        assertEq(vault.MAX_SCORE(), 10);

        vm.recordLogs();
        _cycle(alice, 100e6, MIN_AGE, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], CreditUpdated.selector);
        }

        (int64 s, uint32 repaid,) = vault.credit(alice);
        assertEq(s, 10);
        assertEq(repaid, 10);
        assertEq(rep.feedbackCount(), 10);
    }

    function test_linkAgentRevertsForNonOwner() public {
        vm.prank(liq);
        vm.expectRevert(bytes("not agent owner"));
        vault.linkAgent(AGENT);

        vault.setRegistries(address(0), address(rep));
        vm.prank(alice);
        vm.expectRevert(bytes("no identity"));
        vault.linkAgent(AGENT);
    }

    function test_linkAgentByOwner() public {
        vm.expectEmit(address(vault));
        emit AgentLinked(alice, AGENT);
        _link();
        (uint256 id, bool set) = vault.agentOf(alice);
        assertEq(id, AGENT);
        assertTrue(set);
    }

    function test_repayAndLiquidationMirrorToRegistry() public {
        _link();
        _counted(alice, 1);
        assertEq(rep.feedbackCount(), 1);
        _assertFeedback(0, 1, "repay");

        _pay(alice, 0, 700e6);
        vault.setPrice(address(nvda), 100e6);
        _liquidate();
        assertEq(rep.feedbackCount(), 2);
        _assertFeedback(1, -5, "liquidation");
    }

    function test_uncountedRepayAndUnlinkedWalletAreNotMirrored() public {
        _link();
        _cycle(alice, 100e6, 0, false);
        assertEq(rep.feedbackCount(), 0);

        nvda.mint(liq, 10e18);
        _counted(liq, 1);
        assertEq(_score(liq), 1);
        assertEq(rep.feedbackCount(), 0);
    }

    // a failing registry must neither block repay and liquidate nor make them expensive
    function _brokenRegistryCannotBlock(address registry) internal {
        vault.setRegistries(address(ids), registry);
        _link();

        _pay(alice, 10e18, 100e6);
        vm.warp(block.timestamp + MIN_AGE);
        vm.expectEmit(address(vault));
        emit MirrorFailed(alice);
        vm.prank(alice);
        uint256 g = gasleft();
        vault.repay{gas: TX_GAS}(address(nvda), type(uint256).max);
        assertLt(g - gasleft(), MAX_GAS_USED);
        assertEq(_score(alice), 1);

        _pay(alice, 0, 700e6);
        vault.setPrice(address(nvda), 100e6);
        vm.expectEmit(address(vault));
        emit MirrorFailed(alice);
        vm.prank(liq);
        g = gasleft();
        vault.liquidate{gas: TX_GAS}(alice, address(nvda));
        assertLt(g - gasleft(), MAX_GAS_USED);
        assertEq(_score(alice), -4);
        assertEq(nvda.balanceOf(liq), 7.35e18);
    }

    function test_revertingRegistryDoesNotBlockRepayOrLiquidate() public {
        rep.setShouldRevert(true);
        _brokenRegistryCannotBlock(address(rep));
    }

    function test_gasBurningRegistryDoesNotBlockRepayOrLiquidate() public {
        _brokenRegistryCannotBlock(address(new GasBurner()));
    }

    function testFuzz_payNeverExceedsTierLtv(uint8 cycles, uint256 collateralIn, uint256 amount, uint256 px) public {
        cycles = uint8(bound(cycles, 0, 10));
        collateralIn = bound(collateralIn, 0, 100e18);
        px = bound(px, 1e6, 10_000e6);
        nvda.mint(alice, 100e18);
        _counted(alice, cycles);
        vault.setPrice(address(nvda), px);

        (uint256 held,,,) = _position(alice);
        amount = bound(amount, 1, vault.value(address(nvda), held + collateralIn) * 6 / 10 + 1);

        vm.prank(alice);
        try vault.pay(address(nvda), collateralIn, amount, shop, "") {
            (uint256 c, uint256 d,,) = _position(alice);
            (uint256 ltv,,) = vault.terms(alice);
            assertLe(d * 10000, vault.value(address(nvda), c) * ltv);
        } catch {}
    }

    function test_badInputsAndNonOracleRevert() public {
        Token other = new Token("Other", "OTH", 18, true);
        vm.startPrank(alice);
        vm.expectRevert(bytes("bad args"));
        vault.pay(address(nvda), 10e18, 0, shop, "");
        vm.expectRevert(bytes("bad args"));
        vault.pay(address(nvda), 10e18, 1e6, address(0), "");
        vm.expectRevert(bytes("unlisted"));
        vault.pay(address(other), 0, 1e6, shop, "");
        vm.expectRevert(bytes("not oracle"));
        vault.setPrice(address(nvda), 1);
        vm.stopPrank();
    }
}
