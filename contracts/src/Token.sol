// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// Mock testnet token. Stocks use openMint (public faucet); USDC is owner-mint only.
contract Token is ERC20, Ownable {
    uint8 private immutable _dec;
    bool public immutable openMint;

    constructor(string memory name, string memory symbol, uint8 dec, bool openMint_)
        ERC20(name, symbol)
        Ownable(msg.sender)
    {
        _dec = dec;
        openMint = openMint_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        // ponytail: unlimited faucet, fine on testnet; cap per address if someone griefs
        require(openMint || msg.sender == owner(), "mint closed");
        _mint(to, amount);
    }
}
