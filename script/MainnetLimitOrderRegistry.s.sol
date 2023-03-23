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
 *      `source .env && forge script script/MainnetLimitOrderRegistry.s.sol:MainnetLimitOrderRegistryScript --rpc-url $MAINNET_RPC_URL  --private-key $PRIVATE_KEY —optimize —optimizer-runs 200 --with-gas-price 15000000000 --verify --etherscan-api-key $ETHERSCAN_KEY --broadcast --slow`
 * @dev Optionally can change `--with-gas-price` to something more reasonable
 */
contract MainnetLimitOrderRegistryScript is Script {
    LimitOrderRegistry private registry;
    LimitOrderRegistryLens private lens;
    TradeManagerFactory private factory;
    TradeManager private manager;

    ERC20 private USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    ERC20 private WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address private owner = 0xf416e1FE92527c56Db9DC8Eaff7630F6e5a2E2eD;
    INonFungiblePositionManager private positionManger =
        INonFungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    ERC20 private WrappedNative = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    LinkTokenInterface private LINK = LinkTokenInterface(0x514910771AF9Ca656af840dff83E8264EcF986CA);
    KeeperRegistrar private REGISTRAR = KeeperRegistrar(0xDb8e8e2ccb5C033938736aa89Fe4fa1eDfD15a1d);

    IUniswapV3Pool private USDC_WETH_05_POOL = IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);

    address private fastGasFeed = 0x169E633A2D1E6c10dD91238Ba11c4A708dfEF37C;

    function run() public {
        vm.startBroadcast();

        // Deploy limit order registry.
        registry = new LimitOrderRegistry(owner, positionManger, WrappedNative, LINK, REGISTRAR, fastGasFeed);
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

        registry.setMinimumAssets(100e6, USDC);
        registry.setMinimumAssets(0.05e18, WETH);

        // Setup pool.
        uint256 upkeepFunds = 0;
        // LINK.approve(address(registry), upkeepFunds);
        registry.setupLimitOrder(USDC_WETH_05_POOL, upkeepFunds);

        // Create Trade Manager.
        // LINK.approve(address(factory), upkeepFunds);
        manager = factory.createTradeManager(registry, LINK, REGISTRAR, upkeepFunds);

        vm.stopBroadcast();
    }
}
