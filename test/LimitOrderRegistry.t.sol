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

    LinkTokenInterface private LINK = LinkTokenInterface(0xb0897686c545045aFc77CF20eC7A532E3120E0F1);

    KeeperRegistrar private REGISTRAR = KeeperRegistrar(0xDb8e8e2ccb5C033938736aa89Fe4fa1eDfD15a1d);

    ERC20 private USDC = ERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    ERC20 private WETH = ERC20(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
    ERC20 private WMATIC = ERC20(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);

    IUniswapV3Pool private USDC_WETH_05_POOL = IUniswapV3Pool(0x45dDa9cb7c25131DF268515131f647d726f50608);

    function setUp() external {
        registry = new LimitOrderRegistry(address(this), positionManger, WMATIC, LINK, REGISTRAR);
    }

    // ========================================= INITIALIZATION TEST =========================================

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
        deal(address(WMATIC), address(this), 100_000 * 100_000);
        WMATIC.approve(address(registry), 100_000 * 100_000);
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
        deal(address(WMATIC), address(this), 100_000 * 100_000);
        WMATIC.approve(address(registry), 100_000 * 100_000);
        registry.claimOrder(USDC_WETH_05_POOL, 2, address(this));
    }

    function testLinkedListCreation() external {
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);

        registry.setupLimitOrder(USDC_WETH_05_POOL, 0);
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

        // Claim everything.
        deal(address(WMATIC), address(this), 1e18);
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
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);
        registry.setupLimitOrder(USDC_WETH_05_POOL, 0);

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
        uint256 expectedFeePerUser = 10e9 / 2;
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
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);
        registry.setupLimitOrder(USDC_WETH_05_POOL, 0);

        // Create orders to buy WETH.
        uint256 amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 205000, uint96(amount), true, 0);

        // New order should have been set to centerHead.
        (uint256 centerHead, uint256 centerTail, , , , , ) = registry.poolToData(USDC_WETH_05_POOL);
        uint256 expectedHead = 614120;
        assertEq(centerHead, expectedHead, "Center head should have been updated.");
        assertEq(centerTail, 0, "Center tail should be zero.");

        // Create orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        uint256 targetHead = expectedHead;
        registry.newOrder(USDC_WETH_05_POOL, 204800, uint96(amount), false, 0);

        // New order should have been set to centerTail.
        (centerHead, centerTail, , , , , ) = registry.poolToData(USDC_WETH_05_POOL);
        uint256 expectedTail = 614121;
        assertEq(centerHead, expectedHead, "Center head should not have been updated.");
        assertEq(centerTail, expectedTail, "Center tail should have been updated.");

        // Create orders to buy WETH.
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204900, uint96(amount), true, 0);

        // New order should have been set to centerHead.
        (centerHead, centerTail, , , , , ) = registry.poolToData(USDC_WETH_05_POOL);
        expectedHead = 614122;
        assertEq(centerHead, expectedHead, "Center head should have been updated.");
        assertEq(centerTail, expectedTail, "Center tail should not have been updated.");

        // Create orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        targetHead = expectedHead;
        registry.newOrder(USDC_WETH_05_POOL, 204850, uint96(amount), false, 0);

        // New order should have been set to centerTail.
        (centerHead, centerTail, , , , , ) = registry.poolToData(USDC_WETH_05_POOL);
        expectedTail = 614123;
        assertEq(centerHead, expectedHead, "Center head should not have been updated.");
        assertEq(centerTail, expectedTail, "Center tail should have been updated.");

        // Create orders to buy WETH.
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204910, uint96(amount), true, 0);

        // New order should have been set to centerHead.
        (centerHead, centerTail, , , , , ) = registry.poolToData(USDC_WETH_05_POOL);
        assertEq(centerHead, expectedHead, "Center head should not have been updated.");
        assertEq(centerTail, expectedTail, "Center tail should not have been updated.");

        // Create orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        targetHead = expectedHead;
        registry.newOrder(USDC_WETH_05_POOL, 204700, uint96(amount), false, 0);

        // New order should have been set to centerTail.
        (centerHead, centerTail, , , , , ) = registry.poolToData(USDC_WETH_05_POOL);
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
        registry.newOrder(USDC_WETH_05_POOL, 204910, uint96(amount), true, 0);

        // Create orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        registry.newOrder(USDC_WETH_05_POOL, 204860, uint96(amount), false, 0);

        // Skew pool tick before placing order.
        {
            address[] memory path = new address[](2);
            path[0] = address(USDC);
            path[1] = address(WETH);

            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = 500;

            uint256 swapAmount = 1_000_000e6;
            deal(address(USDC), address(this), swapAmount);
            _swap(path, poolFees, swapAmount);
        }

        // Create orders to buy WETH.
        amount = 1_000e6;
        deal(address(USDC), address(this), amount);
        USDC.approve(address(registry), amount);
        vm.expectRevert(abi.encodeWithSelector(LimitOrderRegistry.LimitOrderRegistry__CenterITM.selector));
        registry.newOrder(USDC_WETH_05_POOL, 204900, uint96(amount), true, 0);

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

        // Create orders to sell WETH.
        amount = 1e18;
        deal(address(WETH), address(this), amount);
        WETH.approve(address(registry), amount);
        vm.expectRevert(abi.encodeWithSelector(LimitOrderRegistry.LimitOrderRegistry__CenterITM.selector));
        registry.newOrder(USDC_WETH_05_POOL, 204870, uint96(amount), false, 0);
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
