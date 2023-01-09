// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { AutomationCompatibleInterface } from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import { Owned } from "@solmate/auth/Owned.sol";
import { UniswapV3Pool as IUniswapV3Pool } from "src/interfaces/uniswapV3/UniswapV3Pool.sol";
import { NonfungiblePositionManager as INonfungiblePositionManager } from "src/interfaces/uniswapV3/NonfungiblePositionManager.sol";

contract LimitOrderRegistry is Owned, AutomationCompatibleInterface {
    using SafeTransferLib for ERC20;

    INonfungiblePositionManager public immutable positionManager;

    constructor(address _owner, INonfungiblePositionManager _positionManager) Owned(_owner) {
        positionManager = _positionManager;
    }

    // Stores the last saved center position of the orderLinkedList based off an input UniV3 pool
    struct PoolData {
        uint256 center;
        ERC20 token0;
        ERC20 token1;
        uint128 token0Fees; // Swap fees from input token, withdrawable by admin
        uint128 token1Fees; // Swap fees from input token, withdrawable by admin
    }
    mapping(IUniswapV3Pool => PoolData) public poolToData;

    struct UserData {
        address user;
        uint96 depositAmount;
    }

    // Zero is reserved
    uint256 public userDataCount = 1;

    mapping(uint256 => UserData[]) private userData;

    uint24 public constant BUFFER = 10; // The number of ticks past the endTick needed for checkUpkeep to trigger an upkeep.
    // The minimum spacing between new order ticks is this mulitplier times the pools min tick spacing, this way users can better

    struct Order {
        bool isValid; // Used as a quick check to see if a given token id was made by this contract.
        bool direction; //Determines what direction we are going
        int24 tickUpper;
        int24 tickLower;
        uint128 token0Amount; //Can either be the deposit amount or the amount got out of liquidity changing to the other token
        uint128 token1Amount; //uint128 is already a restriction in base uniswap V3 protocol.
        uint256 userDataId; // The id where the user data is currently stored
        uint256 head;
        uint256 tail;
    }

    //TODO emit what userDataId a user is in when they add liquiidty
    //TODO emit when a keeper fills an order and emit the userDataId filled

    // Orders can be reused to save on NFT space
    // PositionId to Order
    mapping(uint256 => Order) public orderLinkedList;

    // Using the below struct values and the userData array, we can figure out how much a user is owed.
    struct Claim {
        uint128 token0Amount; //Can either be the deposit amount or the amount got out of liquidity changing to the other token
        uint128 token1Amount;
        uint128 feePerUser; // Fee in terms of network native asset.
        bool direction; //Determines the token out
    }

    // How users claim their tokens, just need to pass in the uint128 userDataId
    mapping(uint256 => Claim) public claim;

    mapping(address => mapping(bytes32 => bool)) public poolToTickBoundHash; // Track whether we have used a tick upper and lower bound for a pool.

    mapping(int24 => mapping(int24 => uint256)) public getPositionFromTicks; // maps lower -> upper -> positionId

    /**
     * Flow
     * setupLimitOrder
     *  -Creates a new upkeep
     *  -Called by owner who funds initial upkeep and is the owner of the upkeep.
     *  -Linked list is initialized with zero center

     * newOrder
     *  -Opens an order with a position not in the List. Can mint a new LP token(internal mint function)
     *  -FE specifies where position should go
     *  -Position must be fully OTM.(internal check, maybe could return a enum, ITM, OTM, BOTH
     *  -Require a minimum liquidity is met(fixed value) internal function that can be changed
     *  -update order info and add users assets as liquidity.
     *  -Create userDataId

     * cancelOrder
     *  -If last liquidity in order, than remove it from the array
     *  -Remove liquidity from position and return it to user.

     * claimOrder
     *  -Pass in the userDataId
     *  -Caller pays their fee share/if they claim more than there address, they pay that fee share too(FOR NOW DO THIS IN LINK WITH NO SWAPS) AND FUND UPKEEP IN SEPEARTE TX.
     *  -Determine output token owed.

     * checkUpkeep
     *  -Save current tick price
     *  -Work through open LP positions, start at center, check if order is ITM
     *  -move to head or tail based off previous result.
     
     * performUpkeep
     *  -takes an array of positions to fulfill
     *  -checks that every position is ITM
     *  -updates position in linked list.
     */
    // TODO
    function setupLimitOrder(IUniswapV3Pool pool, uint256 initialUpkeepFunds) external {
        // Check if Limit Order is already setup for `pool`.

        // Create Upkeep.

        // poolToData
        poolToData[pool] = PoolData({
            center: 0,
            token0: ERC20(pool.token0()),
            token1: ERC20(pool.token1()),
            token0Fees: 0,
            token1Fees: 0
        });
    }

    // Simplest approach is to have an owner set value for minimum liquidity
    mapping(ERC20 => uint256) public minimumAssets;

    function setMinimumAssets(uint256 amount, ERC20 asset) external onlyOwner {
        minimumAssets[asset] = amount;
    }

    function _enforceMinimumLiquidity(uint256 amount, ERC20 asset) internal view {
        uint256 minimum = minimumAssets[asset];
        if (minimum == 0) revert("Minimum not set");
        if (amount < minimum) revert("Minimum not met");
    }

    enum OrderStatus {
        ITM,
        OTM,
        MIXED
    }

    function _getOrderStatus(
        int24 currentTick,
        int24 lower,
        int24 upper,
        bool direction
    ) internal pure returns (OrderStatus status) {
        if (upper == lower) revert("Invalid ticks");
        if (direction) {
            // Indicates we want to go lower -> upper.
            if (currentTick > upper) return OrderStatus.ITM;
            if (currentTick >= lower) return OrderStatus.MIXED;
            else return OrderStatus.OTM;
        } else {
            // Indicates we want to go upper -> lower.
            if (currentTick < lower) return OrderStatus.ITM;
            if (currentTick <= upper) return OrderStatus.MIXED;
            else return OrderStatus.OTM;
        }
    }

    // targetTick is the tick where your limit order would be filled.
    function newOrder(
        IUniswapV3Pool pool,
        int24 targetTick,
        uint96 amount,
        bool direction,
        uint256 proposedHead,
        uint256 proposedTail
    ) external {
        (, int24 tick, , , , , ) = pool.slot0();

        // Determine upper and lower ticks.
        int24 upper;
        int24 lower;
        {
            int24 tickSpacing = pool.tickSpacing();
            // TODO is it safe to assume tickSpacing is always positive?
            // Make sure targetTick is divisible by spacing.
            if (targetTick % tickSpacing != 0) revert("Invalid target tick");
            if (direction) {
                upper = targetTick;
                lower = targetTick - tickSpacing;
            } else {
                upper = targetTick + tickSpacing;
                lower = targetTick;
            }
        }
        // Validate lower, upper,and direction.
        {
            OrderStatus status = _getOrderStatus(tick, lower, upper, direction);
            if (status != OrderStatus.OTM) revert("Invalid Order");
        }

        // Transfer assets into contract before setting any state.
        {
            ERC20 assetIn;
            if (direction) assetIn = poolToData[pool].token1;
            else assetIn = poolToData[pool].token0;
            _enforceMinimumLiquidity(amount, assetIn);
            assetIn.safeTransferFrom(msg.sender, address(this), amount);
        }

        // Get the position id.
        uint256 positionId = getPositionFromTicks[lower][upper];
        uint128 amount0;
        uint128 amount1;
        if (direction) amount1 = amount;
        else amount0 = amount;
        if (positionId == 0) {
            // Create new LP position(which adds liquidity)
            positionId = _mintPosition(pool, upper, lower, amount0, amount1, direction);
            // Order is not in the linked list, validate proposed spot.
            _validateProposedSpotInList(proposedTail, proposedHead, lower, upper);
            // Add it to the list.
            _addPositionToList(proposedTail, proposedHead, positionId);
            // Set new orders upper and lower tick.
            orderLinkedList[positionId].tickLower = lower;
            orderLinkedList[positionId].tickUpper = upper;
            //  create a new userDataId, direction.
            _setupOrder(direction, positionId);
            // update token0Amount, token1Amount, userData array(checking if user is already in it).
            _updateOrder(positionId, msg.sender, amount);

            _updateCenter(pool, positionId, tick, upper, lower);

            // Update getPositionFromTicks since we have a new LP position.
            getPositionFromTicks[lower][upper] = positionId;
        } else {
            // Check if the position id is already being used in List.
            Order memory order = orderLinkedList[positionId];
            if (order.head != 0 || order.tail != 0) {
                // Order is already in the linked list, ignore proposed spot.
                // Need to add liquidity,
                _addToPosition(pool, positionId, amount0, amount1, direction);
                // update token0Amount, token1Amount, userData array(checking if user is already in it).
                _updateOrder(positionId, msg.sender, amount);
            } else {
                // We already have this order.
                // Order is not in the linked list, validate proposed spot.
                _validateProposedSpotInList(proposedTail, proposedHead, lower, upper);
                // Add it to the list.
                _addPositionToList(proposedTail, proposedHead, positionId);
                //  create a new userDataId, direction.
                _setupOrder(direction, positionId);
                // Need to add liquidity,
                _addToPosition(pool, positionId, amount0, amount1, direction);
                // update token0Amount, token1Amount, userData array(checking if user is already in it).
                _updateOrder(positionId, msg.sender, amount);

                _updateCenter(pool, positionId, tick, upper, lower);
            }
        }
    }

    /**
     * @notice We revert if center or center tail orders are ITM to stop attackers from manipulating
     *         pool tick in order to mess up center of linked list.
     *         Doing this does open a DOS attack vector where a griefer could sandwich attack
     *         user `newOrder` TXs and cause them to revert. This is unlikely to happen for a few reasons.
     *         1) There is no monetary gain for the attacker.
     *         2) The attacker pays swap fees every time they manipulate the pool tick.
     *         3) The attacker can not use a flash loan so they must have a large sum of capital.
     *         4) Performing this attack exposes the attacker to arbitrage risk where other bots
     *            will try to arbitrage the attackers pool.
     */
    function _updateCenter(
        IUniswapV3Pool pool,
        uint256 positionId,
        int24 currentTick,
        int24 upper,
        int24 lower
    ) internal {
        // If the center is not set for the pool, then positionId is the new center.
        uint256 center = poolToData[pool].center;
        if (center == 0) poolToData[pool].center = positionId;
        else {
            // Check if center or center tail is ITM, if so revert, see notice.
            Order memory centerOrder = orderLinkedList[center];
            OrderStatus status = _getOrderStatus(
                currentTick,
                centerOrder.tickLower,
                centerOrder.tickUpper,
                centerOrder.direction
            );
            if (status == OrderStatus.ITM) revert("User can not update center while orders are ITM.");
            if (centerOrder.tail != 0) {
                Order memory centerTail = orderLinkedList[centerOrder.tail];
                status = _getOrderStatus(currentTick, centerTail.tickLower, centerTail.tickUpper, centerTail.direction);
                if (status == OrderStatus.ITM) revert("User can not update center while orders are ITM.");
            }

            // We already know provided upper and lower tick values are OTM, so just check if lower tick is greater than
            // the current tick.
            if (lower > currentTick) {
                // Check if upper is less than the lower of the center order, if so make this new order the center.
                if (upper < centerOrder.tickLower) poolToData[pool].center = positionId;
                // else do nothing the center is correct.
            }
            // else center is correct.
        }
    }

    function _validateProposedSpotInList(
        uint256 tail,
        uint256 head,
        int24 lower,
        int24 upper
    ) internal view {
        if (head == 0 && tail == 0) revert("Invalid Proposal");
        if (tail == 0) {
            Order memory headOrder = orderLinkedList[head];
            // head.tail must be zero
            if (headOrder.tail != 0) revert("Invalid Proposal");
            // head lowerTick >= upper
            if (headOrder.tickLower < upper) revert("Invalid Proposal");
        } else if (head == 0) {
            Order memory tailOrder = orderLinkedList[tail];
            // tail.head must be zero
            if (tailOrder.head != 0) revert("Invalid Proposal");
            // tail upperTick <= lower
            if (tailOrder.tickUpper > lower) revert("Invalid Proposal");
        } else {
            Order memory headOrder = orderLinkedList[head];
            // head.tail == tail
            if (headOrder.tail != tail) revert("Invalid Proposal");
            // head lower tick >= upper
            if (headOrder.tickLower < upper) revert("Invalid Proposal");
            Order memory tailOrder = orderLinkedList[tail];
            // tail.head == head
            if (tailOrder.head != head) revert("Invalid Proposal");
            // tail upper tick <= lower
            if (tailOrder.tickUpper > lower) revert("Invalid Proposal");
        }
    }

    function _addPositionToList(
        uint256 tail,
        uint256 head,
        uint256 position
    ) internal {
        if (tail != 0) {
            orderLinkedList[tail].head = position;
            orderLinkedList[position].tail = tail;
        }
        if (head != 0) {
            orderLinkedList[head].tail = position;
            orderLinkedList[position].head = head;
        }
    }

    function _setupOrder(bool direction, uint256 position) internal {
        Order storage order = orderLinkedList[position];
        order.userDataId = userDataCount;
        order.direction = direction;
        userDataCount++;
    }

    function _updateOrder(
        uint256 positionId,
        address user,
        uint96 amount
    ) internal {
        Order storage order = orderLinkedList[positionId];
        if (order.direction) {
            // token1
            order.token1Amount += amount;
        } else {
            // token0
            order.token0Amount += amount;
        }

        // Check if user is already in the order.
        uint256 dataId = order.userDataId;
        uint256 userCount = userData[dataId].length;
        for (uint256 i = 0; i < userCount; ++i) {
            if (userData[dataId][i].user == user) {
                // We found the user, update their existing balance.
                userData[dataId][i].depositAmount += amount;
                break;
            }
            if (i == userCount - 1) {
                // made it to the end and did not find the user, so add them.
                userData[dataId].push(UserData(user, uint96(amount)));
                break;
            }
        }
    }

    function _mintPosition(
        IUniswapV3Pool pool,
        int24 upper,
        int24 lower,
        uint128 amount0,
        uint128 amount1,
        bool direction
    ) internal returns (uint256) {
        address token0 = pool.token0();
        address token1 = pool.token1();
        if (direction) ERC20(token1).safeApprove(address(positionManager), amount1);
        else ERC20(token0).safeApprove(address(positionManager), amount0);

        // Create mint params.
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: pool.fee(),
            tickLower: lower,
            tickUpper: upper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0,
            amount1Min: amount1,
            recipient: address(this),
            deadline: block.timestamp
        });

        // Supply liquidity to pool.
        (uint256 tokenId, , uint256 amount0Act, uint256 amount1Act) = positionManager.mint(params);

        if (tokenId == 0) revert("Zero Token Id not valid");

        if (amount0Act != amount0 || amount1Act != amount1) revert("Did not use full amount");

        return tokenId;
    }

    function _addToPosition(
        IUniswapV3Pool pool,
        uint256 positionId,
        uint128 amount0,
        uint128 amount1,
        bool direction
    ) internal {
        address token0 = pool.token0();
        address token1 = pool.token1();
        if (direction) ERC20(token1).safeApprove(address(positionManager), amount1);
        else ERC20(token0).safeApprove(address(positionManager), amount0);

        // Create increase liquidity params.
        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams({
                tokenId: positionId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: amount0,
                amount1Min: amount1,
                deadline: block.timestamp
            });

        // Increase liquidity in pool.
        (, uint256 amount0Act, uint256 amount1Act) = positionManager.increaseLiquidity(params);
        if (amount0Act != amount0 || amount1Act != amount1) revert("Did not use full amount");
    }

    uint256 private constant MAX_FILLS_PER_UPKEEP = 10;

    // TODO should we add an ITM tick buffer? So that orders must be ITM by atleast buffer ticks.
    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData) {
        uint256[MAX_FILLS_PER_UPKEEP] memory ordersToFulfill;
        uint256 fillCount;
        bool walkDirection;
        // Check if pool center is ITM.
        IUniswapV3Pool pool = abi.decode(checkData, (IUniswapV3Pool));
        uint256 target = poolToData[pool].center;
        (, int24 currentTick, , , , , ) = pool.slot0();
        Order memory order = orderLinkedList[poolToData[pool].center];
        OrderStatus status = _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction);
        if (status == OrderStatus.ITM) {
            ordersToFulfill[0] = target;
            fillCount++;
            walkDirection = true; // Walk towards head of list.
        } else {
            walkDirection = false; // Walk towards tail of list.
        }
        target = walkDirection ? order.head : order.tail;
        while (target != 0 && fillCount < MAX_FILLS_PER_UPKEEP) {
            order = orderLinkedList[target];
            // Check if target is ITM.
            status = _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction);
            if (status == OrderStatus.ITM) {
                ordersToFulfill[fillCount] = target;
                fillCount++;
                target = walkDirection ? order.head : order.tail;
            } else {
                // No more orders need to be filled.
                break;
            }
        }

        // Check if there are any orders to fill.
        if (fillCount > 0) {
            upkeepNeeded = true;
            performData = abi.encode(pool, ordersToFulfill);
        }
    }

    uint256 public upkeepGasLimit = 100_000;

    /// @dev premium should be factored into this value.
    function setUpkeepGasLimit(uint256 gasLimit) external onlyOwner {
        upkeepGasLimit = gasLimit;
    }

    uint256 public upkeepGasPrice = 100_000;

    function setUpkeepGasPrice(uint256 gasPrice) external onlyOwner {
        upkeepGasPrice = gasPrice;
    }

    function performUpkeep(bytes calldata performData) external {
        (IUniswapV3Pool pool, uint256[MAX_FILLS_PER_UPKEEP] memory ordersToFulfill) = abi.decode(
            performData,
            (IUniswapV3Pool, uint256[10])
        );

        // Estimate gas cost.
        uint256 estimatedFee = upkeepGasLimit * upkeepGasPrice;

        // Fulfill orders.
        (, int24 currentTick, , , , , ) = pool.slot0();
        bool orderFilled;
        for (uint256 i; i < MAX_FILLS_PER_UPKEEP; ++i) {
            uint256 target = ordersToFulfill[i];
            if (target == 0) break;
            Order storage order = orderLinkedList[target];
            OrderStatus status = _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction);
            if (status == OrderStatus.ITM) {
                _fulfillOrder(target, pool, order, estimatedFee);
                orderFilled = true;
            }
        }

        if (!orderFilled) revert("No orders filled!");
    }

    function _fulfillOrder(
        uint256 target,
        IUniswapV3Pool pool,
        Order storage order,
        uint256 estimatedFee
    ) internal {
        // Save fee per user in Claim Struct.
        uint256 totalUsers = userData[order.userDataId].length;
        Claim storage newClaim = claim[order.userDataId];
        newClaim.feePerUser = uint128(estimatedFee / totalUsers);

        // Take all liquidity from the order.
        (uint128 amount0, uint128 amount1) = _takeFromPosition(target, pool, 1e18);
        if (order.direction) {
            // Copy the tokenIn amount from the order, this is the total user deposit.
            newClaim.token0Amount = order.token0Amount;
            // Total amount received is the difference in balance.
            newClaim.token1Amount = amount1;

            // Save any extra swap fees pool earned.
            // TODO this could be updated one time at the end of the call for gas efficiency.
            poolToData[pool].token0Fees += amount0;
        } else {
            // Copy the tokenIn amount from the order, this is the total user deposit.
            newClaim.token1Amount = order.token1Amount;
            // Total amount received is the difference in balance.
            newClaim.token0Amount = amount0;

            // Save any extra swap fees pool earned.
            // TODO this could be updated one time at the end of the call for gas efficiency.
            poolToData[pool].token1Fees += amount1;
        }
        newClaim.direction = order.direction;

        // Remove order from linked list.
        _removeOrderFromList(target, pool, order);
    }

    function _takeFromPosition(
        uint256 target,
        IUniswapV3Pool pool,
        uint256 liquidityPercent
    ) internal returns (uint128, uint128) {
        // Should probs just accept a percent 1e18 being 100, then when users cancel we pass in the percent of the liquidity they own for the order.
        // Also collects any swap fees, if percent is 100?
        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(target);
        liquidity = uint128(uint256(liquidity * liquidityPercent) / 1e18);

        // Create decrease liquidity params.
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
                tokenId: target,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });

        // Decrease liquidity in pool.
        uint128 amount0;
        uint128 amount1;
        {
            (uint256 a0, uint256 a1) = positionManager.decreaseLiquidity(params);
            amount0 = uint128(a0);
            amount1 = uint128(a1);
        }

        // If completely closing position, then collect fees as well.
        if (liquidityPercent == 1e18) {
            // Create fee collection params.
            INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
                tokenId: target,
                recipient: address(this),
                amount0Max: amount0,
                amount1Max: amount1
            });

            // Save token balances.
            ERC20 token0 = poolToData[pool].token0;
            ERC20 token1 = poolToData[pool].token1;
            uint256 token0Balance = token0.balanceOf(address(this));
            uint256 token1Balance = token1.balanceOf(address(this));

            // Collect fees.
            positionManager.collect(collectParams);

            amount0 = uint128(token0.balanceOf(address(this)) - token0Balance);
            amount1 = uint128(token1.balanceOf(address(this)) - token1Balance);
        }

        return (amount0, amount1);
    }

    function _removeOrderFromList(
        uint256 target,
        IUniswapV3Pool pool,
        Order storage order
    ) internal {
        // Checks if order is the center, if so then it will set it to the the center orders head(which is okay if it is zero).
        uint256 center = poolToData[pool].center;
        if (target == center) {
            uint256 centerHead = orderLinkedList[center].head;
            poolToData[pool].center = centerHead;
        }

        // Remove order from linked list.
        orderLinkedList[order.tail].head = order.head;
        orderLinkedList[order.head].tail = order.tail;
        order.head = 0;
        order.tail = 0;
        // Used in fulfill order and cancel order.
    }

    ERC20 public WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function claimOrder(
        IUniswapV3Pool pool,
        uint256 userDataId,
        address user
    ) external returns (uint256) {
        Claim storage userClaim = claim[userDataId];
        uint256 userLength = userData[userDataId].length;

        // Transfer fee in.
        WETH.safeTransferFrom(msg.sender, address(this), userClaim.feePerUser);

        for (uint256 i; i < userLength; ++i) {
            if (userData[userDataId][i].user == user) {
                // Found our user we are claiming for.
                // Calculate owed amount.
                uint256 totalTokenDeposited;
                uint256 totalTokenOut;
                ERC20 tokenOut;
                if (userClaim.direction) {
                    totalTokenDeposited = userClaim.token0Amount;
                    totalTokenOut = userClaim.token1Amount;
                    tokenOut = poolToData[pool].token1;
                } else {
                    totalTokenDeposited = userClaim.token1Amount;
                    totalTokenOut = userClaim.token0Amount;
                    tokenOut = poolToData[pool].token0;
                }

                uint256 owed = (totalTokenOut * userData[userDataId][i].depositAmount) / totalTokenDeposited;

                // Remove user that claimed from array.
                userData[userDataId][i] = UserData({
                    user: userData[userDataId][userLength - 1].user,
                    depositAmount: userData[userDataId][userLength - 1].depositAmount
                });
                delete userData[userDataId][userLength - 1];

                // Transfer tokens owed to user.
                tokenOut.safeTransfer(user, owed);
                return owed;
            }
        }

        revert("User not found");
    }

    function cancelOrder(
        IUniswapV3Pool pool,
        int24 targetTick,
        bool direction
    ) external returns (uint128 amount0, uint128 amount1) {
        // Make sure order is OTM.
        (, int24 tick, , , , , ) = pool.slot0();

        // Determine upper and lower ticks.
        int24 upper;
        int24 lower;
        {
            int24 tickSpacing = pool.tickSpacing();
            // TODO is it safe to assume tickSpacing is always positive?
            // Make sure targetTick is divisible by spacing.
            if (targetTick % tickSpacing != 0) revert("Invalid target tick");
            if (direction) {
                upper = targetTick;
                lower = targetTick - tickSpacing;
            } else {
                upper = targetTick + tickSpacing;
                lower = targetTick;
            }
        }
        // Validate lower, upper,and direction.
        {
            OrderStatus status = _getOrderStatus(tick, lower, upper, direction);
            if (status != OrderStatus.OTM) revert("Invalid Order");
        }

        // Get the position id.
        uint256 positionId = getPositionFromTicks[lower][upper];

        if (positionId == 0) revert("Invalid position");

        uint256 liquidityPercentToTake;

        // Get the users deposit amount in the order.
        {
            Order storage order = orderLinkedList[positionId];
            uint256 userDataId = order.userDataId;
            uint256 userLength = userData[userDataId].length;
            for (uint256 i; i < userLength; ++i) {
                if (userData[userDataId][i].user == msg.sender) {
                    // Found our user.
                    uint96 depositAmount = userData[userDataId][i].depositAmount;
                    if (order.direction) {
                        if (order.token1Amount == depositAmount) liquidityPercentToTake = 1e18;
                        else {
                            liquidityPercentToTake = (1e18 * depositAmount) / order.token1Amount;
                        }
                    } else {
                        if (order.token0Amount == depositAmount) liquidityPercentToTake = 1e18;
                        else {
                            liquidityPercentToTake = (1e18 * depositAmount) / order.token0Amount;
                        }
                    }
                } else if (i == userLength - 1) {
                    revert("User not found");
                }
            }

            (amount0, amount1) = _takeFromPosition(positionId, pool, liquidityPercentToTake);
            if (liquidityPercentToTake == 1e18) _removeOrderFromList(positionId, pool, order);
        }

        if (amount0 > 0) poolToData[pool].token0.safeTransfer(msg.sender, amount0);
        else if (amount1 > 0) poolToData[pool].token1.safeTransfer(msg.sender, amount1);
        else revert("No liquidity in order");
        // else Determine users share of liquidity and withdraw
    }
}
