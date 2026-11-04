// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Token} from "../src/Token.sol";
import {Vault} from "../src/Vault.sol";

contract VaultTest is Test {
    Token usdc;
    Token nvda;
    Vault vault;
    address alice = address(0xA11CE);
    address shop = address(0x5409);

    function setUp() public {
        usdc = new Token("Mock USDC", "mUSDC", 6, false);
        nvda = new Token("Mock NVIDIA", "mNVDA", 18, true);
        vault = new Vault(usdc);
        usdc.mint(address(vault), 1_000_000e6);
        vault.setPrice(address(nvda), 200e6); // $200/share
        nvda.mint(alice, 10e18); // $2000 of shares
        vm.prank(alice);
        nvda.approve(address(vault), type(uint256).max);
    }

    function test_flow() public {
        // max borrow on $2000 at 35% = $700; quote matches
        assertEq(vault.collateralFor(address(nvda), 700e6), 10e18);

        vm.prank(alice);
        vm.expectRevert(bytes("LTV"));
        vault.pay(address(nvda), 10e18, 701e6, shop, "x");

        vm.prank(alice);
        vault.pay(address(nvda), 10e18, 700e6, shop, "order-1");
        assertEq(usdc.balanceOf(shop), 693e6); // 1% fee
        assertEq(nvda.balanceOf(alice), 0);

        // can't pull collateral while in debt
        vm.prank(alice);
        vm.expectRevert(bytes("LTV"));
        vault.withdraw(address(nvda), 1e18);

        // repay and unlock
        usdc.mint(alice, 700e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.repay(address(nvda), type(uint256).max);
        vault.withdraw(address(nvda), type(uint256).max);
        vm.stopPrank();
        assertEq(nvda.balanceOf(alice), 10e18);
    }

    function test_liquidation() public {
        vm.prank(alice);
        vault.pay(address(nvda), 10e18, 700e6, alice, ""); // self-draw, no fee
        assertEq(usdc.balanceOf(alice), 700e6);

        vm.expectRevert(bytes("healthy"));
        vault.liquidate(alice, address(nvda));

        vault.setPrice(address(nvda), 100e6); // crash: $1000 collateral, 70% LTV > 65%
        assertTrue(vault.liquidatable(alice, address(nvda)));

        usdc.mint(address(this), 700e6);
        usdc.approve(address(vault), 700e6);
        vault.liquidate(alice, address(nvda));
        assertEq(nvda.balanceOf(address(this)), 10e18);
        (uint256 c, uint256 d) = vault.positions(alice, address(nvda));
        assertEq(c + d, 0);
    }
}
