// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import { LimitOrderRegistry } from "src/LimitOrderRegistry.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { NonfungiblePositionManager as INonfungiblePositionManager } from "src/interfaces/uniswapV3/NonfungiblePositionManager.sol";
import { UniswapV3Pool as IUniswapV3Pool } from "src/interfaces/uniswapV3/UniswapV3Pool.sol";
import { IUniswapV3Router } from "src/interfaces/uniswapV3/IUniswapV3Router.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import { IKeeperRegistrar as KeeperRegistrar } from "src/interfaces/chainlink/IKeeperRegistrar.sol";

import { Test, console } from "@forge-std/Test.sol";

// TODO tests failed after changing gas price numbers.
contract LimitOrderRegistryTest is Test {
    LimitOrderRegistry public registry;

    INonfungiblePositionManager private positionManger =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    IUniswapV3Router private router = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    LinkTokenInterface private LINK = LinkTokenInterface(0xb0897686c545045aFc77CF20eC7A532E3120E0F1);

    KeeperRegistrar private REGISTRAR = KeeperRegistrar(0x9a811502d843E5a03913d5A2cfb646c11463467A);

    ERC20 private USDC = ERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    ERC20 private WETH = ERC20(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
    ERC20 private WMATIC = ERC20(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);

    IUniswapV3Pool private USDC_WETH_05_POOL = IUniswapV3Pool(0x45dDa9cb7c25131DF268515131f647d726f50608);

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

    function setUp() external {
        registry = new LimitOrderRegistry(address(this), positionManger, WMATIC, LINK, REGISTRAR);
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);

        deal(address(LINK), address(this), 10e18);
        LINK.approve(address(registry), 10e18);
        registry.setupLimitOrder(USDC_WETH_05_POOL, 10e18);
    }

    // ========================================= INITIALIZATION TEST =========================================

    // ============================================= HAPPY PATH TEST =============================================

    function testHappyPath() external {
        deal(address(LINK), address(this), 10e18);
        LINK.approve(address(registry), 10e18);

        uint256 amount = 1_000e6;
        deal(address(USDC), address(this), amount);

        // Current tick 204332
        // 204367
        // Current block 16371089
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204910, uint96(amount), true, 0);

        // Make a large swap to move the pool tick.
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(USDC);

        uint24[] memory poolFees = new uint24[](1);
        poolFees[0] = 500;

        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        uint256 swapAmount = 1_000e18;
        deal(address(WETH), address(this), swapAmount);
        _swap(path, poolFees, swapAmount);

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        assertTrue(upkeepNeeded, "Upkeep should be needed.");

        registry.performUpkeep(performData);

        deal(address(USDC), address(this), 0);
        deal(address(WMATIC), address(this), 300_000 * 30e9);
        WMATIC.approve(address(registry), 300_000 * 30e9);
        registry.claimOrder(USDC_WETH_05_POOL, 1, address(this));

        // Now create an order to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);

        // Current tick 204360
        // Current block 16371089
        WETH.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204900, uint96(amount), false, 0);

        // Make a large swap to move the pool tick.
        path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);

        poolFees = new uint24[](1);
        poolFees[0] = 500;

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        swapAmount = 2_000_000e6;
        deal(address(USDC), address(this), swapAmount);
        _swap(path, poolFees, swapAmount);

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        assertTrue(upkeepNeeded, "Upkeep should be needed.");

        registry.performUpkeep(performData);

        deal(address(USDC), address(this), 0);
        deal(address(WMATIC), address(this), 300_000 * 30e9);
        WMATIC.approve(address(registry), 300_000 * 30e9);
        registry.claimOrder(USDC_WETH_05_POOL, 2, address(this));
    }

    function testLinkedListCreation() external {
        // Current tick 204888
        // Current block 16371089

        // Create orders to buy WETH.
        uint256 amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204900, uint96(amount), true, 0);

        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204950, uint96(amount), true, 0);

        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204970, uint96(amount), true, 0);

        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204920, uint96(amount), true, 0);

        // Now create an orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204820, uint96(amount), false, 0);

        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204640, uint96(amount), false, 0);

        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204340, uint96(amount), false, 0);

        // (uint256[10] memory heads, uint256[10] memory tails) = registry.viewList(USDC_WETH_05_POOL);
        // for (uint256 i; i < 10; i++) {
        //     console.log(i, heads[i], tails[i]);
        // }

        // Make 3 swaps to generate fees in both token0 and token1.
        {
            address[] memory path = new address[](2);
            path[0] = address(WETH);
            path[1] = address(USDC);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 300e18;
            deal(address(WETH), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }
        {
            address[] memory path = new address[](2);
            path[0] = address(USDC);
            path[1] = address(WETH);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 390_000e6;
            deal(address(USDC), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }
        {
            address[] memory path = new address[](2);
            path[0] = address(WETH);
            path[1] = address(USDC);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 300e18;
            deal(address(WETH), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));
        // (IUniswapV3Pool pool, uint256[10] memory ordersToFulFill) = abi.decode(
        //     performData,
        //     (IUniswapV3Pool, uint256[10])
        // );

        // for (uint256 i; i < 10; ++i) {
        //     console.log("Order", ordersToFulFill[i]);
        // }

        assertTrue(upkeepNeeded, "Upkeep should be needed.");

        registry.performUpkeep(performData);

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        assertTrue(!upkeepNeeded, "Upkeep should not be needed.");

        // Swap in the other direction to trigger other limit orders.
        {
            address[] memory path = new address[](2);
            path[0] = address(USDC);
            path[1] = address(WETH);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 2_000_000e6;
            deal(address(USDC), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        // (, int24 tick, , , , , ) = USDC_WETH_05_POOL.slot0();
        // console.log(uint24(tick));

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        assertTrue(upkeepNeeded, "Upkeep should be needed.");

        registry.performUpkeep(performData);

        // (uint256[10] memory heads, uint256[10] memory tails) = registry.viewList(USDC_WETH_05_POOL);
        // for (uint256 i; i < 10; i++) {
        //     console.log(i, heads[i], tails[i]);
        // }

        // Claim everything.
        deal(address(WMATIC), address(this), 100e18);
        WMATIC.approve(address(registry), type(uint256).max);
        registry.claimOrder(USDC_WETH_05_POOL, 1, address(this));
        registry.claimOrder(USDC_WETH_05_POOL, 2, address(this));
        registry.claimOrder(USDC_WETH_05_POOL, 3, address(this));
        registry.claimOrder(USDC_WETH_05_POOL, 4, address(this));
        registry.claimOrder(USDC_WETH_05_POOL, 5, address(this));
        registry.claimOrder(USDC_WETH_05_POOL, 6, address(this));
        registry.claimOrder(USDC_WETH_05_POOL, 7, address(this));
    }

    function testMulitipleUsersInOneOrder() external {
        address userA = vm.addr(10);
        address userB = vm.addr(100);
        // Current tick 204888
        // Current block 16371089
        vm.startPrank(userA);
        uint256 amount = 1_000e6;
        deal(address(USDC), userA, amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204900, uint96(amount), true, 0);
        vm.stopPrank();

        vm.startPrank(userB);
        deal(address(USDC), userB, amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204900, uint96(amount), true, 0);
        vm.stopPrank();

        // Swap to move pool tick.
        {
            address[] memory path = new address[](2);
            path[0] = address(WETH);
            path[1] = address(USDC);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 300e18;
            deal(address(WETH), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        registry.performUpkeep(performData);

        // Have both users claim their orders.
        uint256 expectedFeePerUser = (300_000 * 30 * 1e9) / 2;
        vm.startPrank(userA);
        deal(address(WMATIC), userA, expectedFeePerUser);
        WMATIC.approve(address(registry), expectedFeePerUser);
        registry.claimOrder(USDC_WETH_05_POOL, 1, userA);
        vm.stopPrank();

        vm.startPrank(userB);
        deal(address(WMATIC), userB, expectedFeePerUser);
        WMATIC.approve(address(registry), expectedFeePerUser);
        registry.claimOrder(USDC_WETH_05_POOL, 1, userB);
        vm.stopPrank();

        uint256 userAWETH = WETH.balanceOf(userA);
        uint256 userBWETH = WETH.balanceOf(userB);

        assertEq(userAWETH, userBWETH, "Both users should have got the same amount of WETH.");
    }

    function testCancellingAnOrder() external {
        address userA = vm.addr(10);
        address userB = vm.addr(100);
        // Current tick 204332
        // Current block 16371089
        vm.startPrank(userA);
        uint256 amount = 1_000e6;
        deal(address(USDC), userA, amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204900, uint96(amount), true, 0);
        vm.stopPrank();

        vm.startPrank(userB);
        deal(address(USDC), userB, amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204900, uint96(amount), true, 0);
        vm.stopPrank();

        vm.prank(userA);
        registry.cancelOrder(USDC_WETH_05_POOL, 204900, true);

        vm.prank(userB);
        registry.cancelOrder(USDC_WETH_05_POOL, 204900, true);
    }

    //     //                     Current Tick: 204162
    //     //                             v
    //     // NULL <-> (204140 - 204150) <-> (204240 - 204250) <-> (204320 - 204330) <-> (204340 - 204350) <-> (204360 - 204370) <-> (204440 - 204450) <-> (204540 - 204550) <-> NULL

    function testNewOrderCenterUpdating() external {
        uint256[10] memory expectedHeads;
        uint256[10] memory expectedTails;

        uint96 usdcAmount = 1_000e6;
        uint96 wethAmount = 1e18;

        // Create orders to buy WETH.
        _createOrder(address(this), USDC_WETH_05_POOL, 500, USDC, usdcAmount);

        // Center Head should be updated.
        expectedHeads[0] = id0;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Create orders to sell WETH.
        _createOrder(address(this), USDC_WETH_05_POOL, -500, WETH, wethAmount);

        // Center tail should be updated.
        expectedTails[0] = id1;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Create orders to buy WETH.
        _createOrder(address(this), USDC_WETH_05_POOL, 400, USDC, usdcAmount);

        // New order should have been set to centerHead.
        expectedHeads[0] = id2;
        expectedHeads[1] = id0;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Create orders to sell WETH.
        _createOrder(address(this), USDC_WETH_05_POOL, -400, WETH, wethAmount);

        // New order should have been set to centerTail.
        expectedTails[0] = id3;
        expectedTails[1] = id1;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Create orders to buy WETH.
        _createOrder(address(this), USDC_WETH_05_POOL, 700, USDC, usdcAmount);

        // New order should not update centerHead.
        expectedHeads[2] = id4;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Create orders to sell WETH.
        _createOrder(address(this), USDC_WETH_05_POOL, -700, WETH, wethAmount);

        // New order should have not set centerTail.
        expectedTails[2] = id5;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);
    }

    function testUpdatingCenterWhilePoolTickManipulated() external {
        uint256[10] memory expectedHeads;
        uint256[10] memory expectedTails;

        // Create orders to buy WETH.
        uint256 amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204910, uint96(amount), true, 0);

        // Create orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204860, uint96(amount), false, 0);

        // Skew pool tick before placing order.
        {
            address[] memory path = new address[](2);
            path[0] = address(WETH);
            path[1] = address(USDC);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 900e18;
            deal(address(WETH), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        // Create orders to buy WETH.
        // This is allowed since the new order does not update the center.
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 205300, uint96(amount), true, 0);

        expectedHeads[0] = id0;
        expectedHeads[1] = id2;
        expectedTails[0] = id1;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // But this should fail because new order tries to update center head.
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        vm.expectRevert(
            abi.encodeWithSelector(LimitOrderRegistry.LimitOrderRegistry__OrderITM.selector, 205240, 204900, true)
        );
        registry.newOrder(USDC_WETH_05_POOL, 204900, uint96(amount), true, 0);

        // Skew pool tick before placing order.
        {
            address[] memory path = new address[](2);
            path[0] = address(USDC);
            path[1] = address(WETH);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 1_500_000e6;
            deal(address(USDC), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        // Create orders to sell WETH.
        // This is allowed since the new order does not update the center tail.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204700, uint96(amount), false, 0);

        // But this should fail because new order tries to update center tail.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        vm.expectRevert(
            abi.encodeWithSelector(LimitOrderRegistry.LimitOrderRegistry__OrderITM.selector, 204771, 204870, false)
        );
        registry.newOrder(USDC_WETH_05_POOL, 204870, uint96(amount), false, 0);
    }

    function testCancellingOrders() external {
        uint96 usdcAmount = 1_000e6;
        uint96 wethAmount = 1e18;

        uint256[10] memory expectedHeads = [id0, id1, id2, 0, 0, 0, 0, 0, 0, 0];
        uint256[10] memory expectedTails = [id3, id4, id5, 0, 0, 0, 0, 0, 0, 0];

        address userA = vm.addr(10);
        address userB = vm.addr(20);

        int24 poolTick;
        {
            (, int24 tick, , , , , ) = USDC_WETH_05_POOL.slot0();
            poolTick = tick - (tick % USDC_WETH_05_POOL.tickSpacing());
        }

        // Fill List with orders.
        vm.startPrank(userA);
        // User A places a repeat order.
        _createOrder(userA, USDC_WETH_05_POOL, 20, USDC, usdcAmount);
        _createOrder(userA, USDC_WETH_05_POOL, 20, USDC, usdcAmount);
        _createOrder(userA, USDC_WETH_05_POOL, 40, USDC, usdcAmount);
        _createOrder(userA, USDC_WETH_05_POOL, 80, USDC, usdcAmount);
        vm.stopPrank();

        vm.startPrank(userB);
        // User B joins User A's order.
        _createOrder(userB, USDC_WETH_05_POOL, 40, USDC, usdcAmount);
        _createOrder(userB, USDC_WETH_05_POOL, -20, WETH, wethAmount);
        _createOrder(userB, USDC_WETH_05_POOL, -40, WETH, wethAmount);
        _createOrder(userB, USDC_WETH_05_POOL, -80, WETH, wethAmount);
        vm.stopPrank();

        // Cancelling orders with multiple people in them.
        // User B leaves 40 tick delta order.
        vm.prank(userB);
        registry.cancelOrder(USDC_WETH_05_POOL, poolTick + 40, true);
        // Order should still be in Linked List.
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Cancelling orders that are between two orders.
        vm.prank(userA);
        registry.cancelOrder(USDC_WETH_05_POOL, poolTick + 40, true);

        // Should have removed id1 from list.
        expectedHeads[1] = id2;
        expectedHeads[2] = 0;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        vm.prank(userB);
        registry.cancelOrder(USDC_WETH_05_POOL, poolTick - 40, false);
        expectedTails[1] = id5;
        expectedTails[2] = 0;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Try to have User B cancel an order they are not in.
        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(LimitOrderRegistry.LimitOrderRegistry__UserNotFound.selector, userB, 3));
        registry.cancelOrder(USDC_WETH_05_POOL, poolTick + 80, true);

        // Cancelling orders that are leafs.
        vm.prank(userA);
        registry.cancelOrder(USDC_WETH_05_POOL, poolTick + 80, true);
        expectedHeads[1] = 0;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        vm.prank(userB);
        registry.cancelOrder(USDC_WETH_05_POOL, poolTick - 80, false);
        expectedTails[1] = 0;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Generate some fees in for the remaining head order.
        {
            address[] memory path = new address[](2);
            path[0] = address(USDC);
            path[1] = address(WETH);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 1_000_000e6;
            deal(address(USDC), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);

            path[0] = address(WETH);
            path[1] = address(USDC);
            swapAmount = 770e18;
            deal(address(WETH), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        // Cancelling an order that has generated swap fees.
        deal(address(USDC), userA, 0);
        vm.prank(userA);
        registry.cancelOrder(USDC_WETH_05_POOL, poolTick + 20, true);
        assertGt(USDC.balanceOf(userA), usdcAmount, "User A should have received some swap fees.");
        expectedHeads[0] = 0;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Cancelling orders that are the center.
        vm.prank(userB);
        registry.cancelOrder(USDC_WETH_05_POOL, poolTick - 20, false);
        expectedTails[0] = 0;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);
    }

    function testEnteringAnITMOrder() external {
        (, int24 tick, , , , , ) = USDC_WETH_05_POOL.slot0();
        int24 poolTick = tick - (tick % USDC_WETH_05_POOL.tickSpacing());

        // Create orders to buy WETH.
        uint256 amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        vm.expectRevert(
            abi.encodeWithSelector(LimitOrderRegistry.LimitOrderRegistry__OrderITM.selector, tick, poolTick + 10, true)
        );
        registry.newOrder(USDC_WETH_05_POOL, poolTick + 10, uint96(amount), true, 0);

        // Create orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        vm.expectRevert(
            abi.encodeWithSelector(LimitOrderRegistry.LimitOrderRegistry__OrderITM.selector, tick, poolTick, false)
        );
        registry.newOrder(USDC_WETH_05_POOL, poolTick, uint96(amount), false, 0);
    }

    function testCancellingITMOrder() external {
        uint96 usdcAmount = 1_000e6;
        uint96 wethAmount = 1e18;

        int24 poolTick;
        {
            (, int24 tick, , , , , ) = USDC_WETH_05_POOL.slot0();
            poolTick = tick - (tick % USDC_WETH_05_POOL.tickSpacing());
        }

        // Create orders.
        _createOrder(address(this), USDC_WETH_05_POOL, 20, USDC, usdcAmount);
        _createOrder(address(this), USDC_WETH_05_POOL, -20, WETH, wethAmount);

        // Make first order ITM.
        {
            address[] memory path = new address[](2);
            path[0] = address(WETH);
            path[1] = address(USDC);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 770e18;
            deal(address(WETH), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        (, int24 currentTick, , , , , ) = USDC_WETH_05_POOL.slot0();

        // Try to cancel it.
        vm.expectRevert(
            abi.encodeWithSelector(
                LimitOrderRegistry.LimitOrderRegistry__OrderITM.selector,
                currentTick,
                poolTick + 20,
                true
            )
        );
        registry.cancelOrder(USDC_WETH_05_POOL, poolTick + 20, true);

        // Make second order ITM.
        {
            address[] memory path = new address[](2);
            path[0] = address(USDC);
            path[1] = address(WETH);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 2_000_000e6;
            deal(address(USDC), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }
        (, currentTick, , , , , ) = USDC_WETH_05_POOL.slot0();

        // Try to cancel it.
        vm.expectRevert(
            abi.encodeWithSelector(
                LimitOrderRegistry.LimitOrderRegistry__OrderITM.selector,
                currentTick,
                poolTick - 20,
                false
            )
        );
        registry.cancelOrder(USDC_WETH_05_POOL, poolTick - 20, false);
    }

    function testOrderCreationWrongDirection() external {
        (, int24 currentTick, , , , , ) = USDC_WETH_05_POOL.slot0();

        // Create orders to buy WETH.
        uint256 amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        vm.expectRevert(
            abi.encodeWithSelector(LimitOrderRegistry.LimitOrderRegistry__OrderITM.selector, currentTick, 204910, false)
        );
        registry.newOrder(USDC_WETH_05_POOL, 204910, uint96(amount), false, 0);

        // Create orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        vm.expectRevert(
            abi.encodeWithSelector(LimitOrderRegistry.LimitOrderRegistry__OrderITM.selector, currentTick, 204860, true)
        );
        registry.newOrder(USDC_WETH_05_POOL, 204860, uint96(amount), true, 0);
    }

    function testUpkeepFulfillingOrders() external {
        (, int24 currentTick, , , , , ) = USDC_WETH_05_POOL.slot0();
        // console.log("Pool Tick", uint24(currentTick));
        uint96 usdcAmount = 1_000e6;
        uint96 wethAmount = 1e18;

        uint256[10] memory expectedHeads = [id0, id1, id2, 0, 0, 0, 0, 0, 0, 0];
        uint256[10] memory expectedTails = [id3, id4, id5, 0, 0, 0, 0, 0, 0, 0];

        address userA = vm.addr(10);
        address userB = vm.addr(20);

        // Fill List with orders.
        vm.startPrank(userA);
        // User A places a repeat order.
        _createOrder(userA, USDC_WETH_05_POOL, 20, USDC, usdcAmount);
        _createOrder(userA, USDC_WETH_05_POOL, 20, USDC, usdcAmount);
        _createOrder(userA, USDC_WETH_05_POOL, 40, USDC, usdcAmount);
        _createOrder(userA, USDC_WETH_05_POOL, 80, USDC, usdcAmount);
        vm.stopPrank();

        vm.startPrank(userB);
        // User B joins User A's order.
        _createOrder(userB, USDC_WETH_05_POOL, 40, USDC, usdcAmount);
        _createOrder(userB, USDC_WETH_05_POOL, -20, WETH, wethAmount);
        _createOrder(userB, USDC_WETH_05_POOL, -40, WETH, wethAmount);
        _createOrder(userB, USDC_WETH_05_POOL, -80, WETH, wethAmount);
        vm.stopPrank();

        // Move price so that orders towards head are fulfillable.
        {
            address[] memory path = new address[](2);
            path[0] = address(WETH);
            path[1] = address(USDC);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 770e18;
            deal(address(WETH), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        (IUniswapV3Pool pool, bool direction) = abi.decode(performData, (IUniswapV3Pool, bool));

        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        assertTrue(direction, "Direction should be true.");

        // Changing performData to illogical direction should revert.
        vm.expectRevert(abi.encodeWithSelector(LimitOrderRegistry.LimitOrderRegistry__NoOrdersToFulfill.selector));
        registry.performUpkeep(abi.encode(pool, false));

        // Using the correct perfomData works.
        registry.performUpkeep(performData);

        expectedHeads[0] = 0;
        expectedHeads[1] = 0;
        expectedHeads[2] = 0;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Move price to make some orders ITM.
        {
            address[] memory path = new address[](2);
            path[0] = address(USDC);
            path[1] = address(WETH);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 2_000_000e6;
            deal(address(USDC), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        (pool, direction) = abi.decode(performData, (IUniswapV3Pool, bool));

        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        assertTrue(!direction, "Direction should be false.");

        // Changing performData to illogical direction should revert.
        vm.expectRevert(abi.encodeWithSelector(LimitOrderRegistry.LimitOrderRegistry__NoOrdersToFulfill.selector));
        registry.performUpkeep(abi.encode(pool, true));

        // Using the correct perfomData works.
        registry.performUpkeep(performData);

        expectedTails[0] = 0;
        expectedTails[1] = 0;
        expectedTails[2] = 0;
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);
    }

    function testUpkeepFulfillingSomeOrders() external {
        // So there are 3 ways a keeper can fulfill orders.
        // Fulfill 1 order
        // Fulfill some of the orders in the list(can be done wither by limiting the fulfills per upkeep, or by only moving price some of the way.)
        // Fulfill all the orders(in the desired direction)

        uint256[10] memory expectedHeads = [id0, id1, id2, id3, id4, id5, 0, 0, 0, 0];
        uint256[10] memory expectedTails = [id6, id7, id8, id9, id10, id11, 0, 0, 0, 0];

        bool upkeepNeeded;
        bytes memory performData;

        uint96 usdcAmount = 1_000e6;
        uint96 wethAmount = 1e18;

        // Fill list with orders.
        _createOrder(address(this), USDC_WETH_05_POOL, 20, USDC, usdcAmount);
        _createOrder(address(this), USDC_WETH_05_POOL, 30, USDC, usdcAmount);
        _createOrder(address(this), USDC_WETH_05_POOL, 40, USDC, usdcAmount);
        _createOrder(address(this), USDC_WETH_05_POOL, 50, USDC, usdcAmount);
        _createOrder(address(this), USDC_WETH_05_POOL, 60, USDC, usdcAmount);
        _createOrder(address(this), USDC_WETH_05_POOL, 70, USDC, usdcAmount);

        _createOrder(address(this), USDC_WETH_05_POOL, -20, WETH, wethAmount);
        _createOrder(address(this), USDC_WETH_05_POOL, -30, WETH, wethAmount);
        _createOrder(address(this), USDC_WETH_05_POOL, -40, WETH, wethAmount);
        _createOrder(address(this), USDC_WETH_05_POOL, -50, WETH, wethAmount);
        _createOrder(address(this), USDC_WETH_05_POOL, -60, WETH, wethAmount);
        _createOrder(address(this), USDC_WETH_05_POOL, -70, WETH, wethAmount);

        // Move price so all head orders can be filled.
        {
            address[] memory path = new address[](2);
            path[0] = address(WETH);
            path[1] = address(USDC);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 770e18;
            deal(address(WETH), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        // Set max fills to 1.
        registry.setMaxFillsPerUpkeep(1);

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        registry.performUpkeep(performData);

        expectedHeads[0] = id1;
        expectedHeads[1] = id2;
        expectedHeads[2] = id3;
        expectedHeads[3] = id4;
        expectedHeads[4] = id5;
        expectedHeads[5] = 0;

        // Only first head should have been filled
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Set max fills to 2.
        registry.setMaxFillsPerUpkeep(2);

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        registry.performUpkeep(performData);

        expectedHeads[0] = id3;
        expectedHeads[1] = id4;
        expectedHeads[2] = id5;
        expectedHeads[3] = 0;
        expectedHeads[4] = 0;
        // Only first 2 heads should have been filled
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Set max fills to 10.
        registry.setMaxFillsPerUpkeep(10);

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        registry.performUpkeep(performData);

        expectedHeads[0] = 0;
        expectedHeads[1] = 0;
        expectedHeads[2] = 0;
        // All remaining head orders should be filled.
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Move price so all tails orders can be filled.
        {
            address[] memory path = new address[](2);
            path[0] = address(USDC);
            path[1] = address(WETH);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 2_000_000e6;
            deal(address(USDC), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        // Set max fills to 1.
        registry.setMaxFillsPerUpkeep(1);

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        registry.performUpkeep(performData);

        expectedTails[0] = id7;
        expectedTails[1] = id8;
        expectedTails[2] = id9;
        expectedTails[3] = id10;
        expectedTails[4] = id11;
        expectedTails[5] = 0;

        // Only first head should have been filled
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Set max fills to 2.
        registry.setMaxFillsPerUpkeep(2);

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        registry.performUpkeep(performData);

        expectedTails[0] = id9;
        expectedTails[1] = id10;
        expectedTails[2] = id11;
        expectedTails[3] = 0;
        expectedTails[4] = 0;
        // Only first 2 heads should have been filled
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);

        // Set max fills to 10.
        registry.setMaxFillsPerUpkeep(10);

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        registry.performUpkeep(performData);

        expectedTails[0] = 0;
        expectedTails[1] = 0;
        expectedTails[2] = 0;
        // All remaining head orders should be filled.
        _checkList(USDC_WETH_05_POOL, expectedHeads, expectedTails);
    }

    // TODO integration test where we reuse orders.

    function _checkList(
        IUniswapV3Pool pool,
        uint256[10] memory expectedHeads,
        uint256[10] memory expectedTails
    ) internal {
        (uint256[10] memory heads, uint256[10] memory tails) = registry.viewList(pool);

        // Check heads.
        for (uint256 i; i < 10; ++i) {
            // console.log(heads[i], expectedHeads[i]);
            assertEq(heads[i], expectedHeads[i], "`head` should equal `expectedHead`.");
        }

        // Check tails.
        for (uint256 i; i < 10; ++i) {
            // console.log(tails[i], expectedTails[i]);
            assertEq(tails[i], expectedTails[i], "`tails` should equal `expectedTail`.");
        }
    }

    function _createOrder(
        address sender,
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

        deal(address(assetIn), sender, amount);
        assetIn.approve(address(registry), amount);
        bool direction = tickDelta > 0;
        registry.newOrder(pool, targetTick, amount, direction, 0);

        return targetTick;
    }

    function _swap(
        address[] memory path,
        uint24[] memory poolFees,
        uint256 amount
    ) public returns (uint256 amountOut) {
        // Approve assets to be swapped through the router.
        ERC20(path[0]).approve(address(router), amount);

        // Encode swap parameters.
        bytes memory encodePackedPath = abi.encodePacked(path[0]);
        for (uint256 i = 1; i < path.length; i++)
            encodePackedPath = abi.encodePacked(encodePackedPath, poolFees[i - 1], path[i]);

        // Execute the swap.
        amountOut = router.exactInput(
            IUniswapV3Router.ExactInputParams({
                path: encodePackedPath,
                recipient: address(this),
                deadline: block.timestamp + 60,
                amountIn: amount,
                amountOutMinimum: 0
            })
        );
    }
}
