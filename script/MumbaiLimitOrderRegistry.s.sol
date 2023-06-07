// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { MockERC20 } from "src/MockERC20.sol";
import { LimitOrderRegistry } from "src/LimitOrderRegistry.sol";
import { NonFungiblePositionManager as INonFungiblePositionManager } from "src/interfaces/uniswapV3/NonFungiblePositionManager.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import { IKeeperRegistrar as KeeperRegistrar } from "src/interfaces/chainlink/IKeeperRegistrar.sol";
import { UniswapV3Pool } from "src/interfaces/uniswapV3/UniswapV3Pool.sol";

import "forge-std/Script.sol";

interface Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address);
}

/**
 * @dev Run
 *      `source .env && forge script script/MumbaiLimitOrderRegistry.s.sol:MumbaiLimitOrderRegistryScript --rpc-url $MUMBAI_RPC_URL  --private-key $PRIVATE_KEY —optimize —optimizer-runs 200 --with-gas-price 300000000000 --verify --etherscan-api-key $POLYGONSCAN_KEY --broadcast --slow`
 * @dev Optionally can change `--with-gas-price` to something more reasonable
 */
contract MumbaiLimitOrderRegistryScript is Script {
    MockERC20 private token0;
    MockERC20 private token1;
    MockERC20 private tokenA;
    MockERC20 private tokenB;
    LimitOrderRegistry private registry;

    address private owner = 0xa5E5860B34ac0C55884F2D0E9576d545e1c7Dfd4;
    INonFungiblePositionManager private positionManger =
        INonFungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    Factory private factory = Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    ERC20 private WrappedNative = ERC20(0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889);
    LinkTokenInterface private LINK = LinkTokenInterface(0x326C977E6efc84E512bB9C30f76E30c160eD06FB);
    KeeperRegistrar private REGISTRAR = KeeperRegistrar(0x57A4a13b35d25EE78e084168aBaC5ad360252467);
    KeeperRegistrar private REGISTRARV1 = KeeperRegistrar(0xDb8e8e2ccb5C033938736aa89Fe4fa1eDfD15a1d);

    function run() public {
        vm.startBroadcast();

        // Deploy four fake ERC20 tokens to create a new pool with.
        token0 = new MockERC20("Crispy", "C");
        token1 = new MockERC20("Mangoes", "M");

        tokenA = new MockERC20("Crispy", "C");
        tokenB = new MockERC20("Mangoes", "M");

        address pool0 = factory.createPool(address(tokenA), address(tokenB), 500);
        address pool1 = factory.createPool(address(token0), address(token1), 500);

        // Deploy limit order registry.
        registry = new LimitOrderRegistry(msg.sender, positionManger, WrappedNative, LINK, REGISTRAR, address(0));

        registry.setMinimumAssets(1, token0);
        registry.setMinimumAssets(1, token1);

        LINK.approve(address(registry), 10e18);

        registry.setupLimitOrder(UniswapV3Pool(pool0), 5e18);
        registry.setRegistrar(REGISTRARV1);
        registry.setupLimitOrder(UniswapV3Pool(pool1), 5e18);

        registry.transferOwnership(owner);

        vm.stopBroadcast();
    }
}
