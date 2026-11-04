// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Token} from "../src/Token.sol";
import {Vault} from "../src/Vault.sol";

/// forge script script/Deploy.s.sol --rpc-url https://testnet-rpc.monad.xyz --private-key $PRIVATE_KEY --broadcast
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Token usdc = new Token("Mock USDC", "mUSDC", 6, false);
        Vault vault = new Vault(usdc);
        usdc.mint(address(vault), 10_000_000e6);

        // Prices are USD with 6 decimals; refresh later with `cast send <vault> "setPrice(address,uint256)"`.
        string[3] memory names = ["Mock NVIDIA", "Mock Tesla", "Mock Apple"];
        string[3] memory syms = ["mNVDA", "mTSLA", "mAAPL"];
        uint256[3] memory prices = [uint256(200e6), 450e6, 270e6];
        for (uint256 i; i < 3; i++) {
            Token s = new Token(names[i], syms[i], 18, true);
            vault.setPrice(address(s), prices[i]);
            console.log(syms[i], address(s));
        }
        vm.stopBroadcast();
        console.log("mUSDC", address(usdc));
        console.log("Vault", address(vault));
    }
}
