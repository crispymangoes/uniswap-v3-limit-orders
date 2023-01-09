// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import { LimitOrderRegistry } from "src/LimitOrderRegistry.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { NonfungiblePositionManager as INonfungiblePositionManager } from "src/interfaces/uniswapV3/NonfungiblePositionManager.sol";
import { UniswapV3Pool as IUniswapV3Pool } from "src/interfaces/uniswapV3/UniswapV3Pool.sol";
import { IUniswapV3Router } from "src/interfaces/uniswapV3/IUniswapV3Router.sol";

import { Test, console } from "@forge-std/Test.sol";

contract LimitOrderRegistryTest is Test {
    LimitOrderRegistry public registry;

    INonfungiblePositionManager private positionManger =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    IUniswapV3Router private router = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    ERC20 private USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    ERC20 private WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    IUniswapV3Pool private USDC_WETH_05_POOL = IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);

    function setUp() external {
        registry = new LimitOrderRegistry(address(this), positionManger);
    }

    // ========================================= INITIALIZATION TEST =========================================

    function testInitialization() external {}

    // ============================================= HAPPY PATH TEST =============================================

    function testHappyPath() external {
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);

        registry.setupLimitOrder(USDC_WETH_05_POOL, 0);

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

    // ============================================= ADDRESS TEST =============================================

    // function testSetAddress() external {
    //     address newAddress = vm.addr(4);

    //     registry.setAddress(0, newAddress);

    //     assertEq(registry.getAddress(0), newAddress, "Should set to new address");
    // }

    // function testSetAddressOfInvalidId() external {
    //     address newAddress = vm.addr(4);

    //     vm.expectRevert(abi.encodeWithSelector(Registry.Registry__ContractNotRegistered.selector, 999));
    //     registry.setAddress(999, newAddress);
    // }

    // function testSetApprovedForDepositOnBehalf() external {
    //     address router = vm.addr(333);
    //     assertTrue(!registry.approvedForDepositOnBehalf(router), "Router should not be set up as a depositor.");
    //     // Give approval.
    //     registry.setApprovedForDepositOnBehalf(router, true);
    //     assertTrue(registry.approvedForDepositOnBehalf(router), "Router should be set up as a depositor.");

    //     // Revoke approval.
    //     registry.setApprovedForDepositOnBehalf(router, false);
    //     assertTrue(!registry.approvedForDepositOnBehalf(router), "Router should not be set up as a depositor.");
    // }

    // function testSetFeeDistributor() external {
    //     bytes32 validCosmosAddress = hex"000000000000000000000000ffffffffffffffffffffffffffffffffffffffff";
    //     // Try setting an invalid fee distributor.
    //     vm.expectRevert(bytes(abi.encodeWithSelector(Registry.Registry__InvalidCosmosAddress.selector)));
    //     registry.setFeesDistributor(hex"0000000000000000000000010000000000000000000000000000000000000000");

    //     registry.setFeesDistributor(validCosmosAddress);
    //     assertEq(registry.feesDistributor(), validCosmosAddress, "Fee distributor should equal `validCosmosAddress`.");
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
