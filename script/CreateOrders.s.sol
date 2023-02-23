// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { LimitOrderRegistry } from "src/LimitOrderRegistry.sol";
import { LimitOrderRegistryLens } from "src/LimitOrderRegistryLens.sol";
import { TradeManagerFactory } from "src/TradeManagerFactory.sol";
import { TradeManager } from "src/TradeManager.sol";
import { NonfungiblePositionManager as INonfungiblePositionManager } from "src/interfaces/uniswapV3/NonfungiblePositionManager.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import { IKeeperRegistrar as KeeperRegistrar } from "src/interfaces/chainlink/IKeeperRegistrar.sol";
import { UniswapV3Pool as IUniswapV3Pool } from "src/interfaces/uniswapV3/UniswapV3Pool.sol";

import "forge-std/Script.sol";

/**
 * @dev Run
 *      `source .env && forge script script/CreateOrders.s.sol:CreateOrdersScript --rpc-url $MATIC_RPC_URL  --private-key $PRIVATE_KEY —optimize —optimizer-runs 200 --with-gas-price 100000000000 --verify --etherscan-api-key $POLYGONSCAN_KEY --broadcast --slow`
 * @dev Optionally can change `--with-gas-price` to something more reasonable
 */
contract CreateOrdersScript is Script {
    // implementation 0xad312ae385316ef976b929d863407d6d8907177b
    LimitOrderRegistry private registry = LimitOrderRegistry(0x7ABeF7696AD43ABC28090F93E3F8dD58954390Da);
    LimitOrderRegistryLens private lens = LimitOrderRegistryLens(0x537244F4873e8FD1384F3B908E0e09536ff9481B);
    TradeManagerFactory private factory = TradeManagerFactory(0x3C69d3BF51abf4D43CAF0BE2cF9C0dd4271D473f);
    TradeManager private manager = TradeManager(payable(0x10C9E439e528c540De8c1797C69B71FD71710791));

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

        // Approve manager to spend assets.
        USDC.approve(address(manager), 10e6);
        WETH.approve(address(manager), 5 * 0.0006e18);
        WrappedNative.approve(address(manager), 5 * 0.74e18);

        // Create orders to BUY ETH.
        _createOrder(USDC_WETH_05_POOL, 100, USDC, 1e6);
        _createOrder(USDC_WETH_05_POOL, 200, USDC, 1e6);
        _createOrder(USDC_WETH_05_POOL, 300, USDC, 1e6);
        _createOrder(USDC_WETH_05_POOL, 400, USDC, 1e6);
        _createOrder(USDC_WETH_05_POOL, 500, USDC, 1e6);

        // Create orders to SELL ETH.
        _createOrder(USDC_WETH_05_POOL, -100, WETH, 0.0006e18);
        _createOrder(USDC_WETH_05_POOL, -200, WETH, 0.0006e18);
        _createOrder(USDC_WETH_05_POOL, -300, WETH, 0.0006e18);
        _createOrder(USDC_WETH_05_POOL, -400, WETH, 0.0006e18);
        _createOrder(USDC_WETH_05_POOL, -500, WETH, 0.0006e18);

        // Create orders to BUY WMATIC.
        _createOrder(WMATIC_USDC_05_POOL, -100, USDC, 1e6);
        _createOrder(WMATIC_USDC_05_POOL, -200, USDC, 1e6);
        _createOrder(WMATIC_USDC_05_POOL, -300, USDC, 1e6);
        _createOrder(WMATIC_USDC_05_POOL, -400, USDC, 1e6);
        _createOrder(WMATIC_USDC_05_POOL, -500, USDC, 1e6);

        // Create orders to SELL WMATIC.
        _createOrder(WMATIC_USDC_05_POOL, 100, WrappedNative, 0.74e18);
        _createOrder(WMATIC_USDC_05_POOL, 200, WrappedNative, 0.74e18);
        _createOrder(WMATIC_USDC_05_POOL, 300, WrappedNative, 0.74e18);
        _createOrder(WMATIC_USDC_05_POOL, 400, WrappedNative, 0.74e18);
        _createOrder(WMATIC_USDC_05_POOL, 500, WrappedNative, 0.74e18);

        vm.stopBroadcast();
    }

    function _createOrder(
        IUniswapV3Pool pool,
        int24 tickDelta,
        ERC20 assetIn,
        uint96 amount
    ) internal returns (int24 targetTick) {
        require(tickDelta > 10 || tickDelta < -10);
        (, int24 tick, , , , , ) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        targetTick = tick - (tick % tickSpacing);
        targetTick += tickDelta;

        bool direction = tickDelta > 0;
        manager.newOrder(pool, assetIn, targetTick, amount, direction, 0);

        return targetTick;
    }
}
