// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IReputationRegistry} from "../interfaces/IERC8004.sol";

// Test and testnet stand-in for the ERC-8004 reputation registry. Records feedback and can be told to revert.
contract MockReputationRegistry is IReputationRegistry {
    struct Feedback {
        uint256 agentId;
        int128 value;
        uint8 valueDecimals;
        string tag1;
        string tag2;
    }

    Feedback[] public feedbacks;
    bool public shouldRevert;

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string memory tag1,
        string memory tag2,
        string memory,
        string memory,
        bytes32
    ) public {
        require(!shouldRevert, "mock revert");
        feedbacks.push(Feedback(agentId, value, valueDecimals, tag1, tag2));
    }

    function feedbackCount() external view returns (uint256) {
        return feedbacks.length;
    }

    function setShouldRevert(bool b) external {
        shouldRevert = b;
    }
}
