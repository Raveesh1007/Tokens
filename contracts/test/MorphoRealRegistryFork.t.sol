// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {MorphoForkBase} from "./MorphoForkBase.sol";

interface IRealIdentity {
    function register(string calldata agentURI) external returns (uint256 agentId);
    function ownerOf(uint256 agentId) external view returns (address);
}

interface IRealReputation {
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;
    function getLastIndex(uint256 agentId, address client) external view returns (uint64);
    function getClients(uint256 agentId) external view returns (address[] memory);
    function readFeedback(uint256 agentId, address client, uint64 index)
        external
        view
        returns (int128 value, uint8 valueDecimals, string memory tag1, string memory tag2, bool isRevoked);
}

// Run with: forge test --fork-url https://rpc.monad.xyz --match-contract MorphoRealRegistryFork -vv
contract MorphoRealRegistryFork is MorphoForkBase {
    IRealIdentity constant REAL_ID = IRealIdentity(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
    IRealReputation constant REAL_REP = IRealReputation(0x8004BAa17C55a88189AE136b182e5fdA19dE9b63);
    // the router passes at most this much gas to the registry
    uint256 constant MIRROR_GAS_CAP = 300_000;

    uint256 agentId;

    function setUp() public override {
        super.setUp();
        vm.prank(alice);
        agentId = REAL_ID.register("ipfs://standing-test");
        router.setRegistries(address(REAL_ID), address(REAL_REP));
        vm.prank(alice);
        router.linkAgent(agentId);
    }

    function _assertFeedback(uint64 index, int128 value, string memory tag2) internal view {
        (int128 v, uint8 dec, string memory t1, string memory t2, bool revoked) =
            REAL_REP.readFeedback(agentId, address(router), index);
        assertEq(v, value);
        assertEq(dec, 0);
        assertEq(t1, "credit");
        assertEq(t2, tag2);
        assertFalse(revoked);
    }

    function test_realRegistryAcceptsTheRepayMirror() public {
        _pay(10e18, 700e6);
        vm.warp(block.timestamp + MIN_AGE + 1);

        Vm.Log[] memory logs = _repayLogs(type(uint256).max);

        (bool repaid, Vm.Log memory l) = _log(logs, Repaid.selector);
        (, bool counted) = abi.decode(l.data, (uint256, bool));
        (bool failed,) = _log(logs, MirrorFailed.selector);
        assertTrue(repaid && counted);
        assertFalse(failed);
        assertEq(REAL_REP.getLastIndex(agentId, address(router)), 1);
        assertEq(REAL_REP.getClients(agentId)[0], address(router));
        _assertFeedback(1, 1, "repay");
    }

    function test_realRegistryAcceptsTheLiquidationMirror() public {
        _pay(10e18, 700e6);
        oracle.setPrice(_crashPrice());
        _fund(liq, 1_000e6);

        vm.recordLogs();
        _liquidate();
        (bool failed,) = _log(vm.getRecordedLogs(), MirrorFailed.selector);

        assertFalse(failed);
        assertEq(REAL_REP.getLastIndex(agentId, address(router)), 1);
        _assertFeedback(1, -5, "liquidation");
    }

    function test_realRegistryOrdersRepayThenLiquidation() public {
        _pay(10e18, 700e6);
        assertTrue(_ageThenRepayAll());
        _pay(0, 700e6);
        oracle.setPrice(_crashPrice());
        _fund(liq, 1_000e6);

        _liquidate();

        assertEq(REAL_REP.getLastIndex(agentId, address(router)), 2);
        _assertFeedback(1, 1, "repay");
        _assertFeedback(2, -5, "liquidation");
    }

    // forge meters with Ethereum gas costs; Monad charges more for cold access, so this understates the real figure
    function test_realGiveFeedbackFitsUnderTheRouterGasCap() public {
        vm.startPrank(address(router));
        uint256 g = gasleft();
        REAL_REP.giveFeedback(agentId, -5, 0, "credit", "liquidation", "", "", bytes32(0));
        uint256 first = g - gasleft();
        g = gasleft();
        REAL_REP.giveFeedback(agentId, -5, 0, "credit", "liquidation", "", "", bytes32(0));
        uint256 second = g - gasleft();
        vm.stopPrank();

        emit log_named_uint("giveFeedback gas, first from a new client", first);
        emit log_named_uint("giveFeedback gas, repeat client", second);
        assertLt(first, MIRROR_GAS_CAP);
    }
}
