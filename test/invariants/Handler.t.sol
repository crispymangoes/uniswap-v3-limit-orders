// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import { LimitOrderRegistry } from "src/LimitOrderRegistry.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { UniswapV3Pool as IUniswapV3Pool } from "src/interfaces/uniswapV3/UniswapV3Pool.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Helpers } from "./Helpers.t.sol";
import "forge-std/Test.sol";

contract Handler is Helpers {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    /// @dev Mimics Event from LimitOrderRegistry
    error LimitOrderRegistry__OrderITM(int24 currentTick, int24 targetTick, bool direction);

    /// @dev Immutable vars
    LimitOrderRegistry internal immutable i_registry;
    ERC20 internal immutable i_usdc;
    ERC20 internal immutable i_weth;
    IUniswapV3Pool internal immutable i_pool;

    /// Ghost vars ///
    /// New orders
    uint256 internal s_newOrderAttempts;
    uint256 internal s_newOrderSuccesses;
    uint256 internal s_newOrderFailLO;
    uint256 internal s_newOrderFailPriceSlippageCheck;
    uint256 internal s_newOrderFailOther;

    struct OrderDetails {
        int24 targetTick;
        bool direction;
    }
    // LP address => batchId => OrderDetails

    mapping(address => mapping(uint128 => OrderDetails)) internal s_lpOrders;
    // BatchIds => Addresses
    mapping(uint128 => EnumerableSet.AddressSet) internal s_batchIdAddresses;
    EnumerableSet.UintSet internal s_batchIds;
    // BatchIds filled by upkeeps
    EnumerableSet.UintSet internal s_filledBatchIds;

    /// Tracking Success and Fails ///
    uint256 internal s_cancelOrderAttempts;
    uint256 internal s_cancelOrderSuccesses;
    uint256 internal s_cancelOrderFail;

    uint256 internal s_swapAttempts;
    uint256 internal s_swapSuccess;
    uint256 internal s_swapFail;

    uint256 internal s_upkeepAttempts;
    uint256 internal s_upkeepSuccesses;
    uint256 internal s_upkeepSkips;

    uint256 internal s_claimAttempts;
    uint256 internal s_claimSuccesses;
    uint256 internal s_claimFail;

    uint256 internal s_pokes;

    constructor(LimitOrderRegistry registry, ERC20 usdc, ERC20 weth, IUniswapV3Pool pool) {
        i_registry = registry;
        i_usdc = usdc;
        i_weth = weth;
        i_pool = pool;
    }

    /// @dev Place order
    function placeNewOrder(uint24 tickDiff, uint256 amount, bool direction, uint256) public {
        s_newOrderAttempts++;
        amount = bound(amount, 1e4, type(uint104).max);
        (address msgSender, ) = _randomSigner();
        changePrank(msgSender);
        tickDiff = uint24(bound(uint256(tickDiff), 20, 100));
        ERC20 token = direction ? i_usdc : i_weth;
        (, int24 currentTick, , , , , ) = i_pool.slot0();
        int24 tickSpacing = i_pool.tickSpacing();
        int24 targetTick = currentTick + (direction ? int24(tickDiff) : -int24(tickDiff));
        if (direction) {
            while (targetTick % tickSpacing != 0) {
                targetTick += int24(1);
            }
        } else {
            while (targetTick % tickSpacing != 0) {
                targetTick -= int24(1);
            }
        }
        deal(address(token), msgSender, amount);
        token.approve(address(i_registry), amount);
        try i_registry.newOrder(i_pool, targetTick, uint96(amount), direction, 0, type(uint256).max) returns (
            uint128 batchId
        ) {
            OrderDetails memory details = OrderDetails(targetTick, direction);
            // add address and details
            s_lpOrders[msgSender][batchId] = details;
            s_batchIdAddresses[batchId].add(msgSender);
            // add batchId
            s_batchIds.add(batchId);
            s_newOrderSuccesses++;
        } catch (bytes memory reason) {
            if (keccak256(bytes(_getRevertMsg(reason))) == keccak256(bytes("LO"))) {
                s_newOrderFailLO++;
            } else if (keccak256(bytes(_getRevertMsg(reason))) == keccak256(bytes("Price slippage check"))) {
                s_newOrderFailPriceSlippageCheck++;
            } else {
                s_newOrderFailOther++;
            }
        }
    }

    /// @dev cancelOrder
    function cancelOrder(uint256 index) public {
        if (s_batchIds.length() == 0) {
            console.log("No orders to cancel");
            return;
        }
        s_cancelOrderAttempts++;

        index = bound(index, 0, s_batchIds.length() - 1);
        uint128 batchId = uint128(s_batchIds.at(index));
        // TODO: Change so that it gets a batchId that is not filled
        if (s_filledBatchIds.contains(batchId)) {
            console.log("Batch ID %s already filled", batchId);
            return;
        }
        address msgSender = s_batchIdAddresses[batchId].at(0);

        OrderDetails memory details = s_lpOrders[msgSender][batchId];

        changePrank(msgSender);
        try i_registry.cancelOrder(i_pool, details.targetTick, details.direction, type(uint256).max) returns (
            uint128,
            uint128,
            uint128 returnedBatchId
        ) {
            assertEq(batchId, returnedBatchId);
            s_cancelOrderSuccesses++;
            // remove address from orders
            s_lpOrders[msgSender][batchId] = OrderDetails(0, false);

            // remove address from batchIds
            s_batchIdAddresses[batchId].remove(msgSender);
            if (s_batchIdAddresses[batchId].length() == 0) {
                s_batchIds.remove(batchId);
            }
        } catch (bytes memory) {
            s_cancelOrderFail++;
        }
    }

    /// @dev Swap
    function swap(bool zeroForOne, uint64 amountSpecified) public {
        s_swapAttempts++;
        if (amountSpecified == 0) {
            amountSpecified = 1;
        }
        if (zeroForOne) {
            deal(address(i_usdc), address(this), amountSpecified);
        } else {
            deal(address(i_weth), address(this), amountSpecified);
        }
        changePrank(address(this));
        try
            i_pool.swap(
                address(this),
                zeroForOne,
                int64(amountSpecified),
                (zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341),
                ""
            )
        returns (int256, int256) {
            s_swapSuccess++;
        } catch (bytes memory reason) {
            if (keccak256(bytes(_getRevertMsg(reason))) == keccak256(bytes("SPL"))) {
                s_swapFail++;
            } else {
                revert();
            }
        }
    }

    /// @dev Check and perform Upkeep
    function performUpkeep() public {
        s_upkeepAttempts++;
        (bool upkeepNeeded, bytes memory performData) = i_registry.checkUpkeep(abi.encode(i_pool));
        if (upkeepNeeded) {
            vm.recordLogs();
            i_registry.performUpkeep(performData);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].topics[0] == keccak256("OrderFilled(uint256,address)")) {
                    (uint256 batchId, ) = abi.decode(logs[i].data, (uint256, address));
                    s_filledBatchIds.add(batchId);
                }
            }
            s_upkeepSuccesses++;
        } else {
            s_upkeepSkips++;
        }
    }

    /// @dev Claim orders - Claims all orders in a certain batch ID
    function claimOrders(uint256 index) public {
        if (s_filledBatchIds.length() == 0) {
            console.log("No orders to claim");
            return;
        }
        s_claimAttempts++;
        index = bound(index, 0, s_filledBatchIds.length() - 1);
        uint128 batchId = uint128(s_filledBatchIds.at(index));
        for (uint256 i = 0; i < s_batchIdAddresses[batchId].length(); i++) {
            address msgSender = s_batchIdAddresses[batchId].at(i);
            changePrank(msgSender);
            uint128 fee = i_registry.getFeePerUser(batchId);
            deal(msgSender, fee + 1 ether);
            (, uint256 amountOwed) = i_registry.claimOrder{ value: fee }(batchId, msgSender);
            assertGt(amountOwed, 0);
            // zero s_lpOrders
            s_lpOrders[msgSender][batchId] = OrderDetails(0, false);
            s_claimSuccesses++;
        }
        // remove batchId from s_batchIds
        s_batchIds.remove(batchId);
        // remove batchId from s_filledBatchIds
        s_filledBatchIds.remove(batchId);
        // remove all addresses from s_batchIdAddresses
        uint256 j = 0;
        while (j < s_batchIdAddresses[batchId].length()) {
            s_batchIdAddresses[batchId].remove(s_batchIdAddresses[batchId].at(0));
            j++;
        }
    }

    /// TODO Provide liquidity directly to pool

    /// @dev Push blockchain one block and 12 seconds in the future
    function pokeBlockchain() public {
        s_pokes++;
        skip(12);
        vm.roll(block.number + 1);
    }

    ///////// HELPERS /////////

    /// @dev Prints ghost vars
    function printGhosts() public view {
        console.log(
            "Total Attempts: %s",
            (s_newOrderAttempts + s_cancelOrderAttempts + s_swapAttempts + s_upkeepAttempts + s_claimAttempts)
        );
        console.log(
            "Total Success: %s",
            (s_newOrderSuccesses + s_cancelOrderSuccesses + s_swapSuccess + s_upkeepSuccesses + s_claimSuccesses)
        );
        console.log(
            "Total Fail: %s",
            (s_newOrderFailLO +
                s_newOrderFailPriceSlippageCheck +
                s_newOrderFailOther +
                s_cancelOrderFail +
                s_swapFail +
                s_claimFail +
                s_upkeepSkips)
        );
        console.log("s_newOrderAttempts: %s", s_newOrderAttempts);
        console.log("s_newOrderSuccesses: %s", s_newOrderSuccesses);
        console.log("s_newOrderFailLO: %s", s_newOrderFailLO);
        console.log("s_newOrderFailPriceSlippageCheck: %s", s_newOrderFailPriceSlippageCheck);
        console.log("s_newOrderFailOther: %s", s_newOrderFailOther);
        console.log("s_cancelOrderAttempts: %s", s_cancelOrderAttempts);
        console.log("s_cancelOrderSuccesses: %s", s_cancelOrderSuccesses);
        console.log("s_cancelOrderFail: %s", s_cancelOrderFail);
        console.log("s_swapAttempts: %s", s_swapAttempts);
        console.log("s_swapSuccess: %s", s_swapSuccess);
        console.log("s_swapFail: %s", s_swapFail);
        console.log("s_upkeepAttempts: %s", s_upkeepAttempts);
        console.log("s_upkeepSuccesses: %s", s_upkeepSuccesses);
        console.log("s_upkeepSkips: %s", s_upkeepSkips);
        console.log("s_claimAttempts: %s", s_claimAttempts);
        console.log("s_claimSuccesses: %s", s_claimSuccesses);
        console.log("s_claimFail: %s", s_claimFail);
        console.log("s_pokes: %s", s_pokes);
    }

    function getBatchIds() public view returns (uint256[] memory) {
        return s_batchIds.values();
    }

    /// @dev Required for Uniswap swaps
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) {
            deal(address(i_usdc), address(this), uint256(amount0Delta));
            i_usdc.transfer(msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            deal(address(i_weth), address(this), uint256(amount1Delta));
            i_weth.transfer(msg.sender, uint256(amount1Delta));
        }
    }
}
