// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import { ERC20 } from "@solmate/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol, 18) {}

    function makeMeMillionare() external {
        _mint(msg.sender, 1_000_000e18);
    }
}
