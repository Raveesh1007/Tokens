// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMorpho, Id, MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
import {Token} from "../src/Token.sol";
import {MockMorphoOracle} from "../src/MockMorphoOracle.sol";
import {MorphoCreditRouter} from "../src/MorphoCreditRouter.sol";

// forge script script/DeployMorpho.s.sol --rpc-url https://rpc.monad.xyz --private-key $DEPLOYER_KEY --broadcast --slow --gas-estimate-multiplier 120
contract DeployMorpho is Script {
    using MarketParamsLib for MarketParams;

    address constant MORPHO = 0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee;
    address constant IRM = 0x09475a3D6eA8c314c592b1a3799bDE044E2F400F;
    uint256 constant SUPPLY = 1_000_000e6;

    struct Deployed {
        MarketParams params;
        address router;
        uint64 minLoanAge;
    }

    function run() external {
        Deployed memory d = _deploy(
            vm.envOr("LLTV", uint256(0.625e18)),
            uint64(vm.envOr("MIN_LOAN_AGE", uint256(10))),
            vm.envOr("IDENTITY", 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            vm.envOr("REPUTATION", 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63)
        );
        _write(d);
        console.log("router", d.router);
        console.log("oracle", d.params.oracle);
        console.log("mUSDC", d.params.loanToken);
        console.log("mNVDA", d.params.collateralToken);
        console.log("marketId", vm.toString(Id.unwrap(d.params.id())));
    }

    function _deploy(uint256 lltv, uint64 minLoanAge, address identity, address reputation)
        private
        returns (Deployed memory d)
    {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Token usdc = new Token("Mock USDC (test)", "mUSDC", 6, false);
        Token nvda = new Token("Mock NVIDIA (test)", "mNVDA", 18, true);
        MockMorphoOracle oracle = new MockMorphoOracle(200e6);
        d.params = MarketParams(address(usdc), address(nvda), address(oracle), IRM, lltv);
        IMorpho(MORPHO).createMarket(d.params);
        usdc.mint(deployer, SUPPLY);
        usdc.approve(MORPHO, SUPPLY);
        IMorpho(MORPHO).supply(d.params, SUPPLY, 0, deployer, "");
        MorphoCreditRouter router = new MorphoCreditRouter(IMorpho(MORPHO), d.params, minLoanAge);
        router.setRegistries(identity, reputation);
        vm.stopBroadcast();
        d.router = address(router);
        d.minLoanAge = minLoanAge;
    }

    function _write(Deployed memory d) private {
        string memory k = "morpho";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "minLoanAge", d.minLoanAge);
        vm.serializeAddress(k, "router", d.router);
        vm.serializeAddress(k, "morpho", MORPHO);
        vm.serializeBytes32(k, "marketId", Id.unwrap(d.params.id()));
        vm.serializeAddress(k, "oracle", d.params.oracle);
        vm.serializeAddress(k, "usdc", d.params.loanToken);
        vm.serializeAddress(k, "nvda", d.params.collateralToken);
        vm.serializeAddress(k, "irm", IRM);
        string memory json = vm.serializeString(k, "lltv", vm.toString(d.params.lltv));

        string memory dir = string.concat(vm.projectRoot(), "/deployments");
        vm.createDir(dir, true);
        vm.writeJson(json, string.concat(dir, "/", vm.toString(block.chainid), "-morpho.json"));
    }
}
