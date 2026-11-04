// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOracle} from "morpho-blue/src/interfaces/IOracle.sol";

// Assumes 18 decimal collateral and 6 decimal loan token, so Morpho's 1e36 scale gives usdcPer1e18 * 1e18
contract MockMorphoOracle is IOracle, Ownable {
    uint256 public price;

    event PriceSet(uint256 price);

    constructor(uint256 usdcPer1e18) Ownable(msg.sender) {
        _set(usdcPer1e18);
    }

    function setPrice(uint256 usdcPer1e18) external onlyOwner {
        _set(usdcPer1e18);
    }

    function _set(uint256 usdcPer1e18) private {
        price = usdcPer1e18 * 1e18;
        emit PriceSet(usdcPer1e18);
    }
}
