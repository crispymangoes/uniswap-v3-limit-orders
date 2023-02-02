// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { MockERC20 } from "src/MockERC20.sol";
import { LimitOrderRegistry } from "src/LimitOrderRegistry.sol";
import { NonfungiblePositionManager as INonfungiblePositionManager } from "src/interfaces/uniswapV3/NonfungiblePositionManager.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import { IKeeperRegistrar as KeeperRegistrar } from "src/interfaces/chainlink/IKeeperRegistrar.sol";
import { UniswapV3Pool as IUniswapV3Pool } from "src/interfaces/uniswapV3/UniswapV3Pool.sol";

import "forge-std/Script.sol";

/**
 * @dev Run
 *      `source .env && forge script script/MaticLimitOrderRegistry.s.sol:MaticLimitOrderRegistryScript --rpc-url $MATIC_RPC_URL  --private-key $PRIVATE_KEY —optimize —optimizer-runs 200 --with-gas-price 100000000000 --verify --etherscan-api-key $POLYGONSCAN_KEY --broadcast --slow`
 * @dev Optionally can change `--with-gas-price` to something more reasonable
 */
contract MaticLimitOrderRegistryScript is Script {
    LimitOrderRegistry private registry;

    ERC20 private USDC = ERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    ERC20 private WETH = ERC20(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);

    address private owner = 0xf416e1FE92527c56Db9DC8Eaff7630F6e5a2E2eD;
    INonfungiblePositionManager private positionManger =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    ERC20 private WrappedNative = ERC20(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);
    LinkTokenInterface private LINK = LinkTokenInterface(0xb0897686c545045aFc77CF20eC7A532E3120E0F1);
    KeeperRegistrar private REGISTRAR = KeeperRegistrar(0x9a811502d843E5a03913d5A2cfb646c11463467A);

    IUniswapV3Pool private USDC_WETH_05_POOL = IUniswapV3Pool(0x45dDa9cb7c25131DF268515131f647d726f50608);
    IUniswapV3Pool private WMATIC_USDC_05_POOL = IUniswapV3Pool(0xA374094527e1673A86dE625aa59517c5dE346d32);

    function run() public {
        vm.startBroadcast();

        // Deploy two fake ERC20 tokens to create a new pool with.
        // token0 = new MockERC20("Crispy", "C");
        // token1 = new MockERC20("Mangoes", "M");

        // Deploy limit order registry.
        registry = new LimitOrderRegistry(msg.sender, positionManger, WrappedNative, LINK, REGISTRAR);

        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);

        // Setup pool.
        uint256 upkeepFunds = 5e18;
        LINK.approve(address(registry), 2 * upkeepFunds);
        registry.setupLimitOrder(USDC_WETH_05_POOL, upkeepFunds);
        registry.setupLimitOrder(WMATIC_USDC_05_POOL, upkeepFunds);

        vm.stopBroadcast();
    }
}
