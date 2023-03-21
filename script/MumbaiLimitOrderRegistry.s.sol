// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { MockERC20 } from "src/MockERC20.sol";
import { LimitOrderRegistry } from "src/LimitOrderRegistry.sol";
import { NonfungiblePositionManager as INonfungiblePositionManager } from "src/interfaces/uniswapV3/NonfungiblePositionManager.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import { IKeeperRegistrar as KeeperRegistrar } from "src/interfaces/chainlink/IKeeperRegistrar.sol";

import "forge-std/Script.sol";

contract LimitOrderRegistryScript is Script {
    MockERC20 private token0 = MockERC20(0xD1B6e83c3D7908A794793BaE257475bc8a6d9527);
    MockERC20 private token1 = MockERC20(0xfC7D504C6323FCd42d540A2dF167D6F24D177B3c);
    LimitOrderRegistry private registry;

    address private owner = 0xa5E5860B34ac0C55884F2D0E9576d545e1c7Dfd4;
    INonfungiblePositionManager private positionManger =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    ERC20 private WrappedNative = ERC20(0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889);
    LinkTokenInterface private LINK = LinkTokenInterface(0x326C977E6efc84E512bB9C30f76E30c160eD06FB);
    KeeperRegistrar private REGISTRAR = KeeperRegistrar(0x57A4a13b35d25EE78e084168aBaC5ad360252467);

    function run() public {
        vm.startBroadcast();

        // Deploy two fake ERC20 tokens to create a new pool with.
        // token0 = new MockERC20("Crispy", "C");
        // token1 = new MockERC20("Mangoes", "M");

        // Deploy limit order registry.
        registry = new LimitOrderRegistry(msg.sender, positionManger, WrappedNative, LINK, REGISTRAR, address(0));

        registry.setMinimumAssets(1, token0);
        registry.setMinimumAssets(1, token1);

        registry.transferOwnership(owner);

        vm.stopBroadcast();
    }
}
