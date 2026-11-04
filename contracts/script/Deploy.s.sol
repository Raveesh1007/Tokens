// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Token} from "../src/Token.sol";
import {Vault} from "../src/Vault.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {MockReputationRegistry} from "../src/mocks/MockReputationRegistry.sol";

// forge script script/Deploy.s.sol --rpc-url $RPC_URL --account <keystore> --sender <addr> --broadcast --gas-estimate-multiplier 120
contract Deploy is Script {
    function run() external {
        uint64 minLoanAge = uint64(vm.envOr("MIN_LOAN_AGE", uint256(10)));
        address identity = vm.envOr("IDENTITY", address(0));
        address reputation = vm.envOr("REPUTATION", address(0));
        bool mocks = identity == address(0) && reputation == address(0);
        require(
            mocks || (identity != address(0) && reputation != address(0)), "set both IDENTITY and REPUTATION or neither"
        );

        vm.startBroadcast();
        Token usdc = new Token("Mock USDC", "mUSDC", 6, true);
        Vault vault = new Vault(usdc, minLoanAge);
        usdc.mint(address(vault), 10_000_000e6);

        // prices are USDC with 6 decimals per share; refresh later with vault.setPrice
        string[3] memory names = ["Mock NVIDIA", "Mock Tesla", "Mock Apple"];
        string[3] memory syms = ["mNVDA", "mTSLA", "mAAPL"];
        uint256[3] memory prices = [uint256(200e6), 450e6, 270e6];
        address[3] memory stocks;
        for (uint256 i; i < 3; i++) {
            Token s = new Token(names[i], syms[i], 18, true);
            vault.setPrice(address(s), prices[i]);
            stocks[i] = address(s);
        }

        if (mocks) {
            identity = address(new MockIdentityRegistry());
            reputation = address(new MockReputationRegistry());
        }
        vault.setRegistries(identity, reputation);
        vm.stopBroadcast();

        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "minLoanAge", minLoanAge);
        vm.serializeBool(k, "mocks", mocks);
        vm.serializeAddress(k, "usdc", address(usdc));
        vm.serializeAddress(k, "vault", address(vault));
        vm.serializeAddress(k, "mNVDA", stocks[0]);
        vm.serializeAddress(k, "mTSLA", stocks[1]);
        vm.serializeAddress(k, "mAAPL", stocks[2]);
        vm.serializeAddress(k, "identity", identity);
        string memory json = vm.serializeAddress(k, "reputation", reputation);

        string memory dir = string.concat(vm.projectRoot(), "/deployments");
        vm.createDir(dir, true);
        vm.writeJson(json, string.concat(dir, "/", vm.toString(block.chainid), ".json"));

        console.log("mUSDC", address(usdc));
        console.log("Vault", address(vault));
        for (uint256 i; i < 3; i++) {
            console.log(syms[i], stocks[i]);
        }
        console.log("identity", identity);
        console.log("reputation", reputation);
    }
}
