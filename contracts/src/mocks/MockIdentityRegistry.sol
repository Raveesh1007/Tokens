// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IIdentityRegistry} from "../interfaces/IERC8004.sol";

// Test and testnet stand-in for the ERC-8004 identity registry. Anyone can assign owners.
contract MockIdentityRegistry is IIdentityRegistry {
    mapping(uint256 agentId => address) public ownerOf;

    function setOwner(uint256 agentId, address owner_) external {
        ownerOf[agentId] = owner_;
    }

    function isAuthorizedOrOwner(address spender, uint256 agentId) external view returns (bool) {
        return ownerOf[agentId] == spender;
    }
}
