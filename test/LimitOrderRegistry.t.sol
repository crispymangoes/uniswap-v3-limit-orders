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

contract LimitOrderRegistryTest is Test {
    LimitOrderRegistry public registry;

    INonfungiblePositionManager private positionManger =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    IUniswapV3Router private router = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    LinkTokenInterface private LINK = LinkTokenInterface(0x514910771AF9Ca656af840dff83E8264EcF986CA);

    KeeperRegistrar private REGISTRAR = KeeperRegistrar(0xDb8e8e2ccb5C033938736aa89Fe4fa1eDfD15a1d);

    ERC20 private USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    ERC20 private WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    IUniswapV3Pool private USDC_WETH_05_POOL = IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);

    function setUp() external {
        registry = new LimitOrderRegistry(address(this), positionManger, WETH, LINK, REGISTRAR);
    }

    // ========================================= INITIALIZATION TEST =========================================

    function testInitialization() external {}

    // ============================================= HAPPY PATH TEST =============================================

    function testHappyPath() external {
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);

        deal(address(LINK), address(this), 10e18);
        LINK.approve(address(registry), 10e18);
        registry.setupLimitOrder(USDC_WETH_05_POOL, 10e18);

        uint256 amount = 1_000e6;
        deal(address(USDC), address(this), amount);

        // Current tick 204332
        // Current block 16371089
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204350, uint96(amount), true, 0, 0);

        (, int24 tick, , , , , ) = USDC_WETH_05_POOL.slot0();
        console.log(uint24(tick));

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
        (IUniswapV3Pool pool, uint256[10] memory ordersToFulFill) = abi.decode(
            performData,
            (IUniswapV3Pool, uint256[10])
        );

        (, tick, , , , , ) = USDC_WETH_05_POOL.slot0();
        console.log(uint24(tick));

        registry.performUpkeep(performData);

        deal(address(USDC), address(this), 0);
        deal(address(WETH), address(this), 100_000 * 100_000);
        WETH.approve(address(registry), 100_000 * 100_000);
        registry.claimOrder(USDC_WETH_05_POOL, 1, address(this));

        // Now create an order to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);

        // Current tick 204360
        // Current block 16371089
        WETH.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204340, uint96(amount), false, 0, 0);

        // Make a large swap to move the pool tick.
        path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);

        poolFees = new uint24[](1);
        poolFees[0] = 500;

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));
        console.log("Upkeep Needed", upkeepNeeded);

        swapAmount = 2_000_000e6;
        deal(address(USDC), address(this), swapAmount);
        _swap(path, poolFees, swapAmount);

        (, tick, , , , , ) = USDC_WETH_05_POOL.slot0();
        console.log(uint24(tick));

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));
        console.log("Upkeep Needed", upkeepNeeded);

        registry.performUpkeep(performData);

        deal(address(USDC), address(this), 0);
        deal(address(WETH), address(this), 100_000 * 100_000);
        WETH.approve(address(registry), 100_000 * 100_000);
        registry.claimOrder(USDC_WETH_05_POOL, 2, address(this));

        console.log("USDC Received", USDC.balanceOf(address(this)));
    }

    function testLinkedListCreation() external {
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);

        registry.setupLimitOrder(USDC_WETH_05_POOL, 0);
        // Current tick 204332
        // Current block 16371089

        // Create orders to buy WETH.
        uint256 amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204350, uint96(amount), true, 0, 0);

        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        uint256 targetTail = registry.getPositionFromTicks(204340, 204350);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204450, uint96(amount), true, 0, targetTail);

        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        targetTail = registry.getPositionFromTicks(204440, 204450);
        registry.newOrder(USDC_WETH_05_POOL, 204550, uint96(amount), true, 0, targetTail);

        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        targetTail = registry.getPositionFromTicks(204340, 204350);
        uint256 targetHead = registry.getPositionFromTicks(204440, 204450);
        registry.newOrder(USDC_WETH_05_POOL, 204370, uint96(amount), true, targetHead, targetTail);

        // Now create an orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        targetHead = registry.getPositionFromTicks(204340, 204350);
        registry.newOrder(USDC_WETH_05_POOL, 204320, uint96(amount), false, targetHead, 0);

        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        targetHead = registry.getPositionFromTicks(204320, 204330);
        registry.newOrder(USDC_WETH_05_POOL, 204240, uint96(amount), false, targetHead, 0);

        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        targetHead = registry.getPositionFromTicks(204240, 204250);
        registry.newOrder(USDC_WETH_05_POOL, 204140, uint96(amount), false, targetHead, 0);

        (uint256[10] memory heads, uint256[10] memory tails) = registry.viewList(USDC_WETH_05_POOL);
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

            uint256 swapAmount = 10_000e18;
            deal(address(WETH), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }
        {
            address[] memory path = new address[](2);
            path[0] = address(USDC);
            path[1] = address(WETH);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 13_000_000e6;
            deal(address(USDC), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }
        {
            address[] memory path = new address[](2);
            path[0] = address(WETH);
            path[1] = address(USDC);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 10_000e18;
            deal(address(WETH), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));
        (IUniswapV3Pool pool, uint256[10] memory ordersToFulFill) = abi.decode(
            performData,
            (IUniswapV3Pool, uint256[10])
        );

        (, int24 tick, , , , , ) = USDC_WETH_05_POOL.slot0();
        // console.log(uint24(tick));

        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        // for (uint256 i; i < 10; ++i) {
        //     console.log("Order", i, ordersToFulFill[i]);
        // }

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

            uint256 swapAmount = 30_000_000e6;
            deal(address(USDC), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        (, tick, , , , , ) = USDC_WETH_05_POOL.slot0();
        // console.log(uint24(tick));

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        assertTrue(upkeepNeeded, "Upkeep should not be needed.");

        registry.performUpkeep(performData);

        // Claim everything.
        WETH.approve(address(registry), type(uint256).max);
        registry.claimOrder(USDC_WETH_05_POOL, 1, address(this));
        registry.claimOrder(USDC_WETH_05_POOL, 2, address(this));
        registry.claimOrder(USDC_WETH_05_POOL, 3, address(this));
        registry.claimOrder(USDC_WETH_05_POOL, 4, address(this));
        registry.claimOrder(USDC_WETH_05_POOL, 5, address(this));
        registry.claimOrder(USDC_WETH_05_POOL, 6, address(this));
        registry.claimOrder(USDC_WETH_05_POOL, 7, address(this));
    }

    // TODO test multiple users in 1 order
    function testMulitipleUsersInOneOrder() external {
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);
        registry.setupLimitOrder(USDC_WETH_05_POOL, 0);

        address userA = vm.addr(10);
        address userB = vm.addr(100);
        // Current tick 204332
        // Current block 16371089
        vm.startPrank(userA);
        uint256 amount = 1_000e6;
        deal(address(USDC), userA, amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204350, uint96(amount), true, 0, 0);
        vm.stopPrank();

        vm.startPrank(userB);
        deal(address(USDC), userB, amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204350, uint96(amount), true, 0, 0);
        vm.stopPrank();

        // Swap to move pool tick.
        {
            address[] memory path = new address[](2);
            path[0] = address(WETH);
            path[1] = address(USDC);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 1_000e18;
            deal(address(WETH), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        registry.performUpkeep(performData);

        // Have both users claim their orders.
        uint256 expectedFeePerUser = 10e9 / 2;
        vm.startPrank(userA);
        deal(address(WETH), userA, expectedFeePerUser);
        WETH.approve(address(registry), expectedFeePerUser);
        registry.claimOrder(USDC_WETH_05_POOL, 1, userA);
        vm.stopPrank();

        vm.startPrank(userB);
        deal(address(WETH), userB, expectedFeePerUser);
        WETH.approve(address(registry), expectedFeePerUser);
        registry.claimOrder(USDC_WETH_05_POOL, 1, userB);
        vm.stopPrank();

        uint256 userAWETH = WETH.balanceOf(userA);
        uint256 userBWETH = WETH.balanceOf(userB);

        assertEq(userAWETH, userBWETH, "Both users should have got the same amount of WETH.");
    }

    function testCancellingAnOrder() external {
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);
        registry.setupLimitOrder(USDC_WETH_05_POOL, 0);

        address userA = vm.addr(10);
        address userB = vm.addr(100);
        // Current tick 204332
        // Current block 16371089
        vm.startPrank(userA);
        uint256 amount = 1_000e6;
        deal(address(USDC), userA, amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204350, uint96(amount), true, 0, 0);
        vm.stopPrank();

        vm.startPrank(userB);
        deal(address(USDC), userB, amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204350, uint96(amount), true, 0, 0);
        vm.stopPrank();

        vm.prank(userA);
        registry.cancelOrder(USDC_WETH_05_POOL, 204350, true);

        vm.prank(userB);
        registry.cancelOrder(USDC_WETH_05_POOL, 204350, true);
    }

    // TODO add tests where proposed spot uses position Ids not owned by registry, and also where proposed spot is wrong, going into each of the if else loops.
    function testPositionValidationReverts() external {
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);
        registry.setupLimitOrder(USDC_WETH_05_POOL, 0);

        // Fill list with multiple orders.
        // Create orders to buy WETH.
        uint256 amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204350, uint96(amount), true, 0, 0);

        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        uint256 targetTail = registry.getPositionFromTicks(204340, 204350);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204450, uint96(amount), true, 0, targetTail);

        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        targetTail = registry.getPositionFromTicks(204440, 204450);
        registry.newOrder(USDC_WETH_05_POOL, 204550, uint96(amount), true, 0, targetTail);

        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        targetTail = registry.getPositionFromTicks(204340, 204350);
        uint256 targetHead = registry.getPositionFromTicks(204440, 204450);
        registry.newOrder(USDC_WETH_05_POOL, 204370, uint96(amount), true, targetHead, targetTail);

        // Now create an orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        targetHead = registry.getPositionFromTicks(204340, 204350);
        registry.newOrder(USDC_WETH_05_POOL, 204320, uint96(amount), false, targetHead, 0);

        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        targetHead = registry.getPositionFromTicks(204320, 204330);
        registry.newOrder(USDC_WETH_05_POOL, 204240, uint96(amount), false, targetHead, 0);

        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        targetHead = registry.getPositionFromTicks(204240, 204250);
        registry.newOrder(USDC_WETH_05_POOL, 204140, uint96(amount), false, targetHead, 0);

        // ---------------------------- Proposing heads/tails not in list ----------------------------
        // Try proposing a head that is not in list.
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        // Target head does not exist in the list.
        targetHead = 11111;
        USDC.approve(address(registry), amount);
        vm.expectRevert(bytes("Order not in list"));
        registry.newOrder(USDC_WETH_05_POOL, 207450, uint96(amount), true, targetHead, 0);

        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        vm.expectRevert(bytes("Order not in list"));
        registry.newOrder(USDC_WETH_05_POOL, 200140, uint96(amount), false, targetHead, 0);

        // Try proposing a tail that is not in list.
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        // Target tail does not exist in the list.
        targetTail = 11111;
        USDC.approve(address(registry), amount);
        vm.expectRevert(bytes("Order not in list"));
        registry.newOrder(USDC_WETH_05_POOL, 207450, uint96(amount), true, 0, targetTail);

        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        vm.expectRevert(bytes("Order not in list"));
        registry.newOrder(USDC_WETH_05_POOL, 200140, uint96(amount), false, 0, targetTail);

        // ---------------------------- Proposing Wrong spots ----------------------------
        //                                                               Current Tick: 204332
        //                                                                       v
        // NULL <-> (204140 - 204150) <-> (204240 - 204250) <-> (204320 - 204330) <-> (204340 - 204350) <-> (204360 - 204370) <-> (204440 - 204450) <-> (204540 - 204550) <-> NULL
        //                             ^                     ^
        //                  Incorrect proposed spot    Correct spot
        // Tail check passes, but head check fails since the proposed head has lower tick values.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        vm.expectRevert(bytes("Bad head"));
        registry.newOrder(USDC_WETH_05_POOL, 204300, uint96(amount), false, 408425, 408426);
        (uint256 head, uint256 tail) = registry.findSpot(USDC_WETH_05_POOL, 0, 204300);
        assertEq(head, 408424, "Wrong Head.");
        assertEq(tail, 408425, "Wrong Tail.");

        //                                                               Current Tick: 204332
        //                                                                       v
        // NULL <-> (204140 - 204150) <-> (204240 - 204250) <-> (204320 - 204330) <-> (204340 - 204350) <-> (204360 - 204370) <-> (204440 - 204450) <-> (204540 - 204550) <-> NULL
        //                             ^                     ^
        //                        Correct spot     Incorrect proposed spot
        // Head check passes, but tail check fails since the proposed tail has higher tick values.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        vm.expectRevert(bytes("Bad tail"));
        registry.newOrder(USDC_WETH_05_POOL, 204200, uint96(amount), false, 408424, 408425);
        (head, tail) = registry.findSpot(USDC_WETH_05_POOL, 0, 204200);
        assertEq(head, 408425, "Wrong Head.");
        assertEq(tail, 408426, "Wrong Tail.");

        //                                                               Current Tick: 204332
        //                                                                       v
        // NULL <-> (204140 - 204150) <-> (204240 - 204250) <-> (204320 - 204330) <-> (204340 - 204350) <-> (204360 - 204370) <-> (204440 - 204450) <-> (204540 - 204550) <-> NULL
        //                                                                                               ^                     ^
        //                                                                                    Incorrect proposed spot    Correct spot
        // Tail check passes, but head check fails since the proposed head has lower tick values.
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        vm.expectRevert(bytes("Bad head"));
        registry.newOrder(USDC_WETH_05_POOL, 204400, uint96(amount), true, 408423, 408420);
        (head, tail) = registry.findSpot(USDC_WETH_05_POOL, 0, 204400);
        assertEq(head, 408421, "Wrong Head.");
        assertEq(tail, 408423, "Wrong Tail.");

        //                                                               Current Tick: 204332
        //                                                                       v
        // NULL <-> (204140 - 204150) <-> (204240 - 204250) <-> (204320 - 204330) <-> (204340 - 204350) <-> (204360 - 204370) <-> (204440 - 204450) <-> (204540 - 204550) <-> NULL
        //                                                                                                                     ^                     ^
        //                                                                                                                Correct spot     Incorrect proposed spot
        // Head check passes, but tail check fails since the proposed tail has higher tick values.
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        vm.expectRevert(bytes("Bad tail"));
        registry.newOrder(USDC_WETH_05_POOL, 204400, uint96(amount), true, 408422, 408421);
        (head, tail) = registry.findSpot(USDC_WETH_05_POOL, 0, 204400);
        assertEq(head, 408421, "Wrong Head.");
        assertEq(tail, 408423, "Wrong Tail.");

        // ---------------------------- Trying to "orphan" nodes in the list ----------------------------
        //                                                               Current Tick: 204332
        //                                                                       v
        // NULL <-> (204140 - 204150) <-> (204240 - 204250) <-> (204320 - 204330) <-> (204340 - 204350) <-> (204360 - 204370) <-> (204440 - 204450) <-> (204540 - 204550) <-> NULL
        //                  ^                     ^                     ^
        //           proposed tail       node trying to orphan                proposed head
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        vm.expectRevert(bytes("Skipping nodes."));
        registry.newOrder(USDC_WETH_05_POOL, 204300, uint96(amount), false, 408424, 408426);

        //                                                                        Current Tick: 204332
        //                                                                                v
        //          NULL <-> (204140 - 204150) <-> (204240 - 204250) <-> (204320 - 204330) <-> (204340 - 204350) <-> (204360 - 204370) <-> (204440 - 204450) <-> (204540 - 204550) <-> NULL
        //            ^              ^                     ^
        //      proposed tail   node trying to orphan   proposed head
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        vm.expectRevert(bytes("Skipping nodes."));
        registry.newOrder(USDC_WETH_05_POOL, 204200, uint96(amount), false, 408425, 0);

        //                                                               Current Tick: 204332
        //                                                                       v
        // NULL <-> (204140 - 204150) <-> (204240 - 204250) <-> (204320 - 204330) <-> (204340 - 204350) <-> (204360 - 204370) <-> (204440 - 204450) <-> (204540 - 204550) <-> NULL
        //                                                                                    ^                     ^                     ^
        //                                                                             proposed tail       node trying to orphan      proposed head
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        vm.expectRevert(bytes("Skipping nodes."));
        registry.newOrder(USDC_WETH_05_POOL, 204400, uint96(amount), true, 408421, 408420);

        //                                                               Current Tick: 204332
        //                                                                       v
        // NULL <-> (204140 - 204150) <-> (204240 - 204250) <-> (204320 - 204330) <-> (204340 - 204350) <-> (204360 - 204370) <-> (204440 - 204450) <-> (204540 - 204550) <-> NULL
        //                                                                                                                                ^                     ^              ^
        //                                                                                                                  proposed tail       node trying to orphan      proposed head
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        vm.expectRevert(bytes("Skipping nodes."));
        registry.newOrder(USDC_WETH_05_POOL, 204500, uint96(amount), true, 0, 408421);

        // ---------------------------- Trying to propose 0,0 with non empty list ----------------------------
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        vm.expectRevert(bytes("List not empty"));
        registry.newOrder(USDC_WETH_05_POOL, 204290, uint96(amount), false, 0, 0);
    }

    function testNewOrderCenterUpdating() external {
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);
        registry.setupLimitOrder(USDC_WETH_05_POOL, 0);

        // Create orders to buy WETH.
        uint256 amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204550, uint96(amount), true, 0, 0);

        // New order should have been set to centerHead.
        (uint256 centerHead, uint256 centerTail, , , , ) = registry.poolToData(USDC_WETH_05_POOL);
        uint256 expectedHead = 408420;
        assertEq(centerHead, expectedHead, "Center head should have been updated.");
        assertEq(centerTail, 0, "Center tail should be zero.");

        // Create orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        uint256 targetHead = expectedHead;
        registry.newOrder(USDC_WETH_05_POOL, 204120, uint96(amount), false, targetHead, 0);

        // New order should have been set to centerTail.
        (centerHead, centerTail, , , , ) = registry.poolToData(USDC_WETH_05_POOL);
        uint256 expectedTail = 408421;
        assertEq(centerHead, expectedHead, "Center head should not have been updated.");
        assertEq(centerTail, expectedTail, "Center tail should have been updated.");

        // Create orders to buy WETH.
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204450, uint96(amount), true, centerHead, centerTail);

        // New order should have been set to centerHead.
        (centerHead, centerTail, , , , ) = registry.poolToData(USDC_WETH_05_POOL);
        expectedHead = 408422;
        assertEq(centerHead, expectedHead, "Center head should have been updated.");
        assertEq(centerTail, expectedTail, "Center tail should not have been updated.");

        // Create orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        targetHead = expectedHead;
        registry.newOrder(USDC_WETH_05_POOL, 204220, uint96(amount), false, centerHead, centerTail);

        // New order should have been set to centerTail.
        (centerHead, centerTail, , , , ) = registry.poolToData(USDC_WETH_05_POOL);
        expectedTail = 408423;
        assertEq(centerHead, expectedHead, "Center head should not have been updated.");
        assertEq(centerTail, expectedTail, "Center tail should have been updated.");

        // Create orders to buy WETH.
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204650, uint96(amount), true, 0, 408420);

        // New order should have been set to centerHead.
        (centerHead, centerTail, , , , ) = registry.poolToData(USDC_WETH_05_POOL);
        assertEq(centerHead, expectedHead, "Center head should not have been updated.");
        assertEq(centerTail, expectedTail, "Center tail should not have been updated.");

        // Create orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        targetHead = expectedHead;
        registry.newOrder(USDC_WETH_05_POOL, 204020, uint96(amount), false, 408421, 0);

        // New order should have been set to centerTail.
        (centerHead, centerTail, , , , ) = registry.poolToData(USDC_WETH_05_POOL);
        assertEq(centerHead, expectedHead, "Center head should not have been updated.");
        assertEq(centerTail, expectedTail, "Center tail should not have been updated.");
    }

    // TODO try updating center with new order while skewing the pool
    function testUpdatingCenterWhilePoolTickManipulated() external {
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);
        registry.setupLimitOrder(USDC_WETH_05_POOL, 0);

        // Create orders to buy WETH.
        uint256 amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204550, uint96(amount), true, 0, 0);

        // Create orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        uint256 targetHead = 408420;
        registry.newOrder(USDC_WETH_05_POOL, 204120, uint96(amount), false, targetHead, 0);

        // Skew pool tick before placing order.
        {
            address[] memory path = new address[](2);
            path[0] = address(USDC);
            path[1] = address(WETH);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 50_000_000e6;
            deal(address(USDC), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        // Create orders to buy WETH.
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        vm.expectRevert(bytes("User can not update center while orders are ITM."));
        registry.newOrder(USDC_WETH_05_POOL, 204350, uint96(amount), true, targetHead, 408421);

        // Skew pool tick before placing order.
        {
            address[] memory path = new address[](2);
            path[0] = address(WETH);
            path[1] = address(USDC);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 100_000e18;
            deal(address(WETH), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        // Create orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        vm.expectRevert(bytes("User can not update center while orders are ITM."));
        registry.newOrder(USDC_WETH_05_POOL, 204220, uint96(amount), false, 408420, 408421);
    }

    // TODO test that cancelling orders properly updates centers.

    // TODO test where upkeep only fulfills some of the orders like if orders 1,2,3,4,5 are ready, if it only fills 2,4, are 1,3,5 still in the proper linked list order
    // TODO cancel an order you are not in.
    // TODO try to enter an order that is ITM.

    // TODO test with negative tick values. This was done on testnet and seemed to work fine.
    // Create order with wrong direction

    //     vm.expectRevert(abi.encodeWithSelector(Registry.Registry__ContractNotRegistered.selector, 999));
    //     registry.setAddress(999, newAddress);
    // }

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
