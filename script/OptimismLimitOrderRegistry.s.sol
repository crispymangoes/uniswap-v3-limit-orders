// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { LimitOrderRegistry } from "src/LimitOrderRegistry.sol";
import { LimitOrderRegistryLens } from "src/LimitOrderRegistryLens.sol";
import { TradeManagerFactory } from "src/TradeManagerFactory.sol";
import { TradeManager } from "src/TradeManager.sol";
import { NonFungiblePositionManager as INonFungiblePositionManager } from "src/interfaces/uniswapV3/NonFungiblePositionManager.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import { IKeeperRegistrar as KeeperRegistrar } from "src/interfaces/chainlink/IKeeperRegistrar.sol";
import { UniswapV3Pool as IUniswapV3Pool } from "src/interfaces/uniswapV3/UniswapV3Pool.sol";

import "forge-std/Script.sol";

/**
 * @dev Run
 *      `source .env && forge script script/OptimismLimitOrderRegistry.s.sol:OptimismLimitOrderRegistryScript --rpc-url $OPTIMISM_RPC_URL  --private-key $PRIVATE_KEY —optimize —optimizer-runs 200 --with-gas-price 300000000000 --verify --etherscan-api-key $OPTIMISTIC_ETHERSCAN_KEY --broadcast --slow`
 * @dev Optionally can change `--with-gas-price` to something more reasonable
 */
contract OptimismLimitOrderRegistryScript is Script {
    LimitOrderRegistry private registry;
    LimitOrderRegistryLens private lens;
    TradeManagerFactory private factory;
    TradeManager private manager;

    address private owner = 0x958892b4a0512b28AaAC890FC938868BBD42f064;

    INonFungiblePositionManager private positionManger =
        INonFungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    ERC20 private WrappedNative = ERC20(0x4200000000000000000000000000000000000006);
    LinkTokenInterface private LINK = LinkTokenInterface(0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6);
    KeeperRegistrar private REGISTRAR = KeeperRegistrar(0x4F3AF332A30973106Fe146Af0B4220bBBeA748eC);

    function run() public {
        vm.startBroadcast();

        // Deploy limit order registry.
        registry = new LimitOrderRegistry(owner, positionManger, WrappedNative, LINK, REGISTRAR, address(0));
        lens = new LimitOrderRegistryLens(registry);
        TradeManager implementation = new TradeManager();
        // Initialize implementation.
        implementation.initialize(
            address(0),
            LimitOrderRegistry(address(0)),
            LinkTokenInterface(address(0)),
            KeeperRegistrar(address(0)),
            0
        );
        factory = new TradeManagerFactory(address(implementation));

        vm.stopBroadcast();
    }
}
