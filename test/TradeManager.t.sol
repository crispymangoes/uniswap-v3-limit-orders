// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import { LimitOrderRegistry } from "src/LimitOrderRegistry.sol";
import { TradeManagerFactory } from "src/TradeManagerFactory.sol";
import { TradeManager } from "src/TradeManager.sol";

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { NonFungiblePositionManager as INonFungiblePositionManager } from "src/interfaces/uniswapV3/NonFungiblePositionManager.sol";
import { UniswapV3Pool as IUniswapV3Pool } from "src/interfaces/uniswapV3/UniswapV3Pool.sol";
import { IUniswapV3Router } from "src/interfaces/uniswapV3/IUniswapV3Router.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import { IKeeperRegistrar as KeeperRegistrar } from "src/interfaces/chainlink/IKeeperRegistrar.sol";

import { Test, console } from "@forge-std/Test.sol";

contract TradeManagerTest is Test {
    LimitOrderRegistry public registry;

    INonFungiblePositionManager private positionManger =
        INonFungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    IUniswapV3Router private router = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    LinkTokenInterface private LINK = LinkTokenInterface(0xb0897686c545045aFc77CF20eC7A532E3120E0F1);

    KeeperRegistrar private REGISTRAR = KeeperRegistrar(0x9a811502d843E5a03913d5A2cfb646c11463467A);

    ERC20 private USDC = ERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    ERC20 private WETH = ERC20(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
    ERC20 private WMATIC = ERC20(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);

    IUniswapV3Pool private USDC_WETH_05_POOL = IUniswapV3Pool(0x45dDa9cb7c25131DF268515131f647d726f50608);

    TradeManager private implementation;
    TradeManagerFactory private factory;

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
        registry = new LimitOrderRegistry(address(this), positionManger, WMATIC, LINK, REGISTRAR, address(0));
        registry.setMinimumAssets(1, USDC);
        registry.setMinimumAssets(1, WETH);

        deal(address(LINK), address(this), 10e18);
        LINK.approve(address(registry), 10e18);
        registry.setupLimitOrder(USDC_WETH_05_POOL, 10e18);

        implementation = new TradeManager();
        factory = new TradeManagerFactory(address(implementation));
    }

    // ============================================= HAPPY PATH TEST =============================================

    function testHappyPath() external {
        uint96 usdcAmount = 1_000e6;

        // Create a trade manager.
        deal(address(LINK), address(this), 10e18);
        LINK.approve(address(factory), 10e18);
        TradeManager manager = factory.createTradeManager(registry, LINK, REGISTRAR, 10e18);
        deal(address(manager), 1 ether);

        // Create a limit order through manager.
        _createOrder(manager, address(this), USDC_WETH_05_POOL, 300, USDC, usdcAmount);
        _createOrder(manager, address(this), USDC_WETH_05_POOL, 500, USDC, usdcAmount);

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

        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        registry.performUpkeep(performData);

        (upkeepNeeded, performData) = manager.checkUpkeep(abi.encode(0));

        manager.performUpkeep(performData);
        uint256 wethInManager = WETH.balanceOf(address(manager));
        assertGt(wethInManager, 0, "Manager should have WETH in it.");

        manager.withdrawERC20(WETH, wethInManager);

        assertEq(WETH.balanceOf(address(manager)), 0, "Manager should have no WETH in it.");

        (upkeepNeeded, performData) = manager.checkUpkeep(abi.encode(0));
        assertEq(upkeepNeeded, false, "Upkeep should not be needed.");

        // Create a new order, then cancel it.
        _createOrder(manager, address(this), USDC_WETH_05_POOL, 300, USDC, usdcAmount);
        manager.cancelOrder(USDC_WETH_05_POOL, 205240 + 300, true);

        // Swap again so that second order is ITM.
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

        (upkeepNeeded, performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        registry.performUpkeep(performData);

        manager.claimOrder(2);

        assertGt(WETH.balanceOf(address(manager)), wethInManager, "Manager should have received more WETH from claim.");

        // Withdraw Native from manager.
        uint256 nativeBalance = address(manager).balance;
        uint256 balBefore = address(this).balance;
        manager.withdrawNative(nativeBalance);

        assertEq(address(manager).balance, 0, "Manager balance should be zero.");
        assertEq(address(this).balance - balBefore, nativeBalance, "Manager should have sent balance to user.");
    }

    function testClaimOrderAndTransferToOwner() external {
        uint96 usdcAmount = 1_000e6;

        // Create a trade manager.
        deal(address(LINK), address(this), 10e18);
        LINK.approve(address(factory), 10e18);
        TradeManager manager = factory.createTradeManager(registry, LINK, REGISTRAR, 10e18);
        deal(address(manager), 1 ether);

        manager.setClaimToOwner(true);

        // Create a limit order through manager.
        _createOrder(manager, address(this), USDC_WETH_05_POOL, 300, USDC, usdcAmount);
        _createOrder(manager, address(this), USDC_WETH_05_POOL, 500, USDC, usdcAmount);

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

        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        registry.performUpkeep(performData);

        (upkeepNeeded, performData) = manager.checkUpkeep(abi.encode(0));

        manager.performUpkeep(performData);
        uint256 wethInManager = WETH.balanceOf(address(manager));
        assertEq(wethInManager, 0, "Manager should have no WETH in it.");
        assertGt(WETH.balanceOf(address(this)), 0, "User should have WETH in it.");
    }

    function testPerformUpkeepUsingWrongClaimInfo() external {
        uint96 usdcAmount = 1_000e6;

        // Create a trade manager.
        deal(address(LINK), address(this), 10e18);
        LINK.approve(address(factory), 10e18);
        TradeManager manager = factory.createTradeManager(registry, LINK, REGISTRAR, 10e18);
        deal(address(manager), 1 ether);

        manager.setClaimToOwner(true);

        // Create a limit order through manager.
        _createOrder(manager, address(this), USDC_WETH_05_POOL, 300, USDC, usdcAmount);

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

        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        registry.performUpkeep(performData);

        (upkeepNeeded, performData) = manager.checkUpkeep(abi.encode(0));
        TradeManager.ClaimInfo[10] memory badInfo = abi.decode(performData, (TradeManager.ClaimInfo[10]));
        uint128 actualFee = registry.getFeePerUser(badInfo[0].batchId);
        // Specifying a fee that is too big should revert.
        badInfo[0].fee = 10 ether;
        performData = abi.encode(badInfo);
        vm.expectRevert();
        manager.performUpkeep(performData);

        // Specifying a fee that is too small should revert bc TM does not approve LOR to spend Wrapped Native.
        badInfo[0].fee = actualFee / 2;
        performData = abi.encode(badInfo);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        manager.performUpkeep(performData);

        // Specifying a fee that is too big, but small enough the trade manager can cover it results in excess being sent back to TM.
        badInfo[0].fee = actualFee * 10;
        performData = abi.encode(badInfo);
        manager.performUpkeep(performData);
        assertEq(address(manager).balance, 1 ether - actualFee, "Manger should have been returned excess fee.");

        // Changing batchId to an invalid one should do nothing.
        badInfo[0].fee = actualFee;
        badInfo[0].batchId = type(uint128).max;
        performData = abi.encode(badInfo);
        manager.performUpkeep(performData);
        assertEq(address(manager).balance, 1 ether - actualFee, "Manger should be the same as before.");
    }

    function testMaxingOutClaimArray() external {
        uint96 usdcAmount = 1_000e6;

        // Create a trade manager.
        deal(address(LINK), address(this), 10e18);
        LINK.approve(address(factory), 10e18);
        TradeManager manager = factory.createTradeManager(registry, LINK, REGISTRAR, 10e18);
        deal(address(manager), 1 ether);

        manager.setClaimToOwner(true);

        // Create a multiple limit orders through manager.
        int24 tickDelta = 20;
        for (int24 i; i < 25; ++i) {
            int24 delta = tickDelta + (i * 10);
            _createOrder(manager, address(this), USDC_WETH_05_POOL, delta, USDC, usdcAmount);
        }

        // Owner orders should be of length 25.
        uint256[] memory ids = manager.getOwnerBatchIds();
        assertEq(ids.length, 25, "ids should be of length 25.");

        // Price moves so all 25 orders are ITM.
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

        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(abi.encode(USDC_WETH_05_POOL));

        // Call perform upkeep 3 times.
        // Fill 10 orders.
        registry.performUpkeep(performData);
        // Fill 10 orders.
        registry.performUpkeep(performData);
        // Fill 5 orders.
        registry.performUpkeep(performData);

        (upkeepNeeded, performData) = manager.checkUpkeep(abi.encode(0));
        manager.performUpkeep(performData);
        // Owner orders should be of length 15.
        ids = manager.getOwnerBatchIds();
        assertEq(ids.length, 15, "ids should be of length 15.");

        (upkeepNeeded, performData) = manager.checkUpkeep(abi.encode(0));
        manager.performUpkeep(performData);
        // Owner orders should be of length 5.
        ids = manager.getOwnerBatchIds();
        assertEq(ids.length, 5, "ids should be of length 5.");

        (upkeepNeeded, performData) = manager.checkUpkeep(abi.encode(0));
        manager.performUpkeep(performData);
        // Owner orders should be of length 0.
        ids = manager.getOwnerBatchIds();
        assertEq(ids.length, 0, "ids should be of length 0.");
    }

    function _createOrder(
        TradeManager manager,
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
        assetIn.approve(address(manager), amount);
        bool direction = tickDelta > 0;
        manager.newOrder(pool, assetIn, targetTick, amount, direction, 0);

        return targetTick;
    }

    function _swap(address[] memory path, uint24[] memory poolFees, uint256 amount) public returns (uint256 amountOut) {
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

    receive() external payable {
        // nothing to do
    }
}
