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
 *      `source .env && forge script script/GoerliLimitOrderRegistry.s.sol:GoerliLimitOrderRegistryScript --rpc-url $GOERLI_RPC_URL  --private-key $PRIVATE_KEY —optimize —optimizer-runs 200 --verify --etherscan-api-key $ETHERSCAN_KEY --broadcast --slow`
 * @dev Optionally can change `--with-gas-price` to something more reasonable
 */
contract GoerliLimitOrderRegistryScript is Script {
    LimitOrderRegistry private registry;
    LimitOrderRegistryLens private lens;
    TradeManagerFactory private factory;
    TradeManager private manager;

    ERC20 private USDC = ERC20(0x3a034FE373B6304f98b7A24A3F21C958946d4075);
    ERC20 private WETH = ERC20(0x695364ffAA20F205e337f9e6226e5e22525838d9);

    address private owner = 0xf416e1FE92527c56Db9DC8Eaff7630F6e5a2E2eD;
    INonFungiblePositionManager private positionManger =
        INonFungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    ERC20 private WrappedNative = ERC20(0x695364ffAA20F205e337f9e6226e5e22525838d9);
    LinkTokenInterface private LINK = LinkTokenInterface(0x326C977E6efc84E512bB9C30f76E30c160eD06FB);
    KeeperRegistrar private REGISTRAR = KeeperRegistrar(0x57A4a13b35d25EE78e084168aBaC5ad360252467);

    IUniswapV3Pool private USDC_WETH_05_POOL = IUniswapV3Pool(0xD11ee14805642dCb5BF840845836AFe3cfc16383);
    IUniswapV3Pool private NEW_POOL = IUniswapV3Pool(0x7F5EEDeCE2c8a494CE98EfEF69751Fd6A3fBC42c);

    address private fastGasFeed = address(0);

    function run() public {
        vm.startBroadcast();

        // Deploy limit order registry.
        // registry = new LimitOrderRegistry(owner, positionManger, WrappedNative, LINK, REGISTRAR, fastGasFeed);
        registry = LimitOrderRegistry(0xe9aa337139f4E8aBB9A5cF0Ef1f70D5F8187aa8d);
        // lens = new LimitOrderRegistryLens(registry);
        // TradeManager implementation = new TradeManager();
        // Initialize implementation.
        // implementation.initialize(
        //     address(0),
        //     LimitOrderRegistry(address(0)),
        //     LinkTokenInterface(address(0)),
        //     KeeperRegistrar(address(0)),
        //     0
        // );
        // factory = new TradeManagerFactory(address(implementation));

        // registry.setMinimumAssets(1, USDC);
        // registry.setMinimumAssets(1, WETH);

        // Setup pool.
        uint256 upkeepFunds = 5e18;
        LINK.approve(address(registry), upkeepFunds);
        registry.setupLimitOrder(NEW_POOL, upkeepFunds);

        registry.transferOwnership(0x958892b4a0512b28AaAC890FC938868BBD42f064);

        // Create Trade Manager.
        // LINK.approve(address(factory), upkeepFunds);
        // manager = factory.createTradeManager(registry, LINK, REGISTRAR, upkeepFunds);

        vm.stopBroadcast();
    }
}
