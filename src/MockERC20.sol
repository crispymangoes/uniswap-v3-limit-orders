// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import { ERC20 } from "@solmate/tokens/ERC20.sol";

// MockERC20 is an ERC20 token for mocking.
contract MockERC20 is ERC20 {
    // constructor hard coded to 18 decimals
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol, 18) {}

    // gives 1 million of the token to the sender
    function makeMeMillionare() external {
        _mint(msg.sender, 1_000_000e18);
    }
}
