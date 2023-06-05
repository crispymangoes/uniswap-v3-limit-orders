// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import "forge-std/Test.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {LimitOrderRegistry} from "src/LimitOrderRegistry.sol";
import {NonFungiblePositionManager as INonFungiblePositionManager} from
    "src/interfaces/uniswapV3/NonFungiblePositionManager.sol";
import {UniswapV3Pool as IUniswapV3Pool} from "src/interfaces/uniswapV3/UniswapV3Pool.sol";
import {IUniswapV3Router} from "src/interfaces/uniswapV3/IUniswapV3Router.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import {IKeeperRegistrar as KeeperRegistrar} from "src/interfaces/chainlink/IKeeperRegistrar.sol";
import {Handler} from "./Handler.t.sol";

contract Invariants is Test {
    LimitOrderRegistry public registry;

    INonFungiblePositionManager private positionManger =
        INonFungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    IUniswapV3Router private router = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    LinkTokenInterface private LINK = LinkTokenInterface(0xb0897686c545045aFc77CF20eC7A532E3120E0F1);

    KeeperRegistrar private REGISTRAR = KeeperRegistrar(0x9a811502d843E5a03913d5A2cfb646c11463467A);
    KeeperRegistrar private REGISTRAR_V1 = KeeperRegistrar(0xDb8e8e2ccb5C033938736aa89Fe4fa1eDfD15a1d);

    ERC20 private USDC = ERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    ERC20 private WETH = ERC20(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
    ERC20 private WMATIC = ERC20(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);

    IUniswapV3Pool private USDC_WETH_05_POOL = IUniswapV3Pool(0x45dDa9cb7c25131DF268515131f647d726f50608);
    IUniswapV3Pool private USDC_WETH_3_POOL = IUniswapV3Pool(0x0e44cEb592AcFC5D3F09D996302eB4C499ff8c10);

    address private fastGasFeed = address(0);

    // Token Ids for polygon block number 37834659.
    uint256 private id0 = 614120;
    uint256 private id1 = 614121;
    uint256 private id2 = 614122;
    uint256 private id3 = 614123;
    uint256 private id4 = 614124;
    uint256 private id5 = 614125;
    uint256 private id6 = 614126;
    uint256 private id7 = 614127;
    uint256 private id8 = 614128;
    uint256 private id9 = 614129;
    uint256 private id10 = 614130;
    uint256 private id11 = 614131;
    uint256 private id12 = 614132;
    uint256 private id13 = 614133;
    uint256 private id14 = 614134;
    uint256 private id15 = 614135;
    uint256 private id16 = 614136;
    uint256 private id17 = 614137;
    uint256 private id18 = 614138;
    uint256 private id19 = 614139;

    Handler internal s_handler;

    function setUp() public {
        registry = new LimitOrderRegistry(address(this), positionManger, WMATIC, LINK, REGISTRAR, fastGasFeed);
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);

        // deal(address(LINK), address(this), 10e18);
        // LINK.approve(address(registry), 10e18);
        registry.setupLimitOrder(USDC_WETH_05_POOL, 0);
        s_handler = new Handler(registry, USDC, WETH, USDC_WETH_05_POOL);

        // add the handler selectors to the fuzzing targets
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = Handler.pokeBlockchain.selector;
        // Added multiple times to increase the probability of being selected
        selectors[1] = Handler.placeNewOrder.selector;
        selectors[2] = Handler.placeNewOrder.selector;
        selectors[3] = Handler.cancelOrder.selector;
        selectors[4] = Handler.performUpkeep.selector;
        // Added multiple times to increase the probability of being selected
        // as swaps are the most common operation.
        selectors[5] = Handler.swap.selector;
        selectors[6] = Handler.swap.selector;
        selectors[7] = Handler.swap.selector;
        selectors[8] = Handler.swap.selector;
        selectors[9] = Handler.claimOrders.selector;

        targetSelector(FuzzSelector({addr: address(s_handler), selectors: selectors}));
        targetContract(address(s_handler));

        vm.startPrank(address(s_handler));
    }

    /// @dev Print ghost variables to the console when run with -vvv
    function invariant_printGhosts() public view {
        s_handler.printGhosts();
    }

    /// @dev This will fail if these views revert at any point
    function invariant_viewsShouldNotRevert() public view {
        registry.getGasPrice();
        registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));
        uint256[] memory ids = s_handler.getBatchIds();
        if (ids.length > 0) {
            uint128 id = uint128(ids[0]);
            registry.getFeePerUser(id);
            registry.isOrderReadyForClaim(id);
            registry.getClaim(id);
        }
    }
}
