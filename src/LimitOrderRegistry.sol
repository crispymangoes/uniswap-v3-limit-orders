// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { AutomationCompatibleInterface } from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import { Owned } from "@solmate/auth/Owned.sol";
import { UniswapV3Pool as IUniswapV3Pool } from "src/interfaces/uniswapV3/UniswapV3Pool.sol";
import { NonfungiblePositionManager as INonfungiblePositionManager } from "src/interfaces/uniswapV3/NonfungiblePositionManager.sol";
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import { IKeeperRegistrar as KeeperRegistrar } from "src/interfaces/chainlink/IKeeperRegistrar.sol";

import { console } from "@forge-std/Test.sol";

// TODO are struct memory variables passed by reference? and if so can they be used to update a structs state using the = sign?
// ^^^^ YES they are passed by reference, and you can use that memory struct to change the state of a storage struct.
contract LimitOrderRegistry is Owned, AutomationCompatibleInterface, ERC721Holder {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                             STRUCTS
    //////////////////////////////////////////////////////////////*/

    // Stores the last saved center position of the orderLinkedList based off an input UniV3 pool
    struct PoolData {
        uint256 centerHead;
        uint256 centerTail;
        ERC20 token0;
        ERC20 token1;
        uint128 token0Fees; // Swap fees from input token, withdrawable by admin
        uint128 token1Fees; // Swap fees from input token, withdrawable by admin
    }

    struct Order {
        bool direction; //Determines what direction we are going
        int24 tickUpper;
        int24 tickLower;
        uint128 token0Amount; //Can either be the deposit amount or the amount got out of liquidity changing to the other token
        uint128 token1Amount; //uint128 is already a restriction in base uniswap V3 protocol.
        uint256 userDataId; // The id where the user data is currently stored
        uint256 head;
        uint256 tail;
    }

    struct UserData {
        address user;
        uint96 depositAmount;
    }

    // Using the below struct values and the userData array, we can figure out how much a user is owed.
    struct Claim {
        uint128 token0Amount; //Can either be the deposit amount or the amount got out of liquidity changing to the other token
        uint128 token1Amount;
        uint128 feePerUser; // Fee in terms of network native asset.
        bool direction; //Determines the token out
    }

    /*//////////////////////////////////////////////////////////////
                             GLOBAL STATE
    //////////////////////////////////////////////////////////////*/

    // How users claim their tokens, just need to pass in the uint128 userDataId
    mapping(uint256 => Claim) public claim;

    mapping(IUniswapV3Pool => PoolData) public poolToData;

    mapping(int24 => mapping(int24 => uint256)) public getPositionFromTicks; // maps lower -> upper -> positionId

    // Simplest approach is to have an owner set value for minimum liquidity
    mapping(ERC20 => uint256) public minimumAssets;
    uint256 public upkeepGasLimit = 100_000;
    uint256 public upkeepGasPrice = 100_000;

    // Zero is reserved
    uint256 public userDataCount = 1;

    mapping(uint256 => UserData[]) private userData;

    uint24 public constant BUFFER = 10; // The number of ticks past the endTick needed for checkUpkeep to trigger an upkeep.
    // The minimum spacing between new order ticks is this mulitplier times the pools min tick spacing, this way users can better

    // Orders can be reused to save on NFT space
    // PositionId to Order
    mapping(uint256 => Order) public orderLinkedList;
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event UserGroup(address user, uint256 group);
    event OrderFilled(uint256 userDataId);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                                 ENUMS
    //////////////////////////////////////////////////////////////*/

    enum OrderStatus {
        ITM,
        OTM,
        MIXED
    }

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    ERC20 public immutable WRAPPED_NATIVE; // Mainnet 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2

    INonfungiblePositionManager public immutable positionManager; // Mainnet 0xC36442b4a4522E871399CD717aBDD847Ab11FE88

    LinkTokenInterface public immutable LINK; // Mainnet 0x514910771AF9Ca656af840dff83E8264EcF986CA

    KeeperRegistrar public immutable REGISTRAR; // Mainnet 0xDb8e8e2ccb5C033938736aa89Fe4fa1eDfD15a1d

    constructor(
        address _owner,
        INonfungiblePositionManager _positionManager,
        ERC20 wrappedNative,
        LinkTokenInterface link,
        KeeperRegistrar registrar
    ) Owned(_owner) {
        positionManager = _positionManager;
        WRAPPED_NATIVE = wrappedNative;
        LINK = link;
        REGISTRAR = registrar;
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER LOGIC
    //////////////////////////////////////////////////////////////*/

    uint32 private constant MAX_FILLS_PER_UPKEEP = 10;
    uint32 public constant UPKEEP_GAS_LIMIT = MAX_FILLS_PER_UPKEEP * 300_000;

    function setupLimitOrder(IUniswapV3Pool pool, uint256 initialUpkeepFunds) external onlyOwner {
        // Check if Limit Order is already setup for `pool`.
        if (address(poolToData[pool].token0) != address(0)) revert("Pool already set up");

        // Create Upkeep.
        if (initialUpkeepFunds > 0) {
            // Owner wants to automatically create an upkeep for new pool.
            SafeTransferLib.safeTransferFrom(ERC20(address(LINK)), msg.sender, address(this), initialUpkeepFunds);

            string memory name = "Limit Order Registry";
            uint96 amount = uint96(initialUpkeepFunds);
            bytes memory upkeepCreationData = abi.encodeWithSelector(
                KeeperRegistrar.register.selector,
                name,
                abi.encode(0),
                address(this),
                UPKEEP_GAS_LIMIT,
                msg.sender,
                abi.encode(pool),
                amount,
                77,
                address(this)
            );
            // TODO needs a abi.encode(0) for offchain config value located after abi.encode(pool)
            // remove source
            LINK.transferAndCall(address(REGISTRAR), initialUpkeepFunds, upkeepCreationData);
        }

        // poolToData
        poolToData[pool] = PoolData({
            centerHead: 0,
            centerTail: 0,
            token0: ERC20(pool.token0()),
            token1: ERC20(pool.token1()),
            token0Fees: 0,
            token1Fees: 0
        });
    }

    function setMinimumAssets(uint256 amount, ERC20 asset) external onlyOwner {
        minimumAssets[asset] = amount;
    }

    /// @dev premium should be factored into this value.
    function setUpkeepGasLimit(uint256 gasLimit) external onlyOwner {
        upkeepGasLimit = gasLimit;
    }

    function setUpkeepGasPrice(uint256 gasPrice) external onlyOwner {
        upkeepGasPrice = gasPrice;
    }

    function withdrawSwapFees(IUniswapV3Pool pool) external onlyOwner {
        PoolData storage data = poolToData[pool];

        if (data.token0Fees > 0) {
            data.token0.safeTransfer(msg.sender, data.token0Fees);
            data.token0Fees = 0;
        }
        if (data.token1Fees > 0) {
            data.token1.safeTransfer(msg.sender, data.token1Fees);
            data.token1Fees = 0;
        }
    }

    function withdrawNative() external onlyOwner {
        WRAPPED_NATIVE.safeTransfer(msg.sender, WRAPPED_NATIVE.balanceOf(address(this)));
    }

    /*//////////////////////////////////////////////////////////////
                        USER ORDER MANAGEMENT LOGIC
    //////////////////////////////////////////////////////////////*/

    // targetTick is the tick where your limit order would be filled.
    function newOrder(
        IUniswapV3Pool pool,
        int24 targetTick,
        uint96 amount,
        bool direction,
        uint256 proposedHead,
        uint256 proposedTail
    ) external {
        if (address(poolToData[pool].token0) == address(0)) revert("Pool not set up");

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
            if (direction) assetIn = poolToData[pool].token0;
            else assetIn = poolToData[pool].token1;
            _enforceMinimumLiquidity(amount, assetIn);
            assetIn.safeTransferFrom(msg.sender, address(this), amount);
        }

        // Get the position id.
        uint256 positionId = getPositionFromTicks[lower][upper];
        uint128 amount0;
        uint128 amount1;
        if (direction) amount0 = amount;
        else amount1 = amount;
        if (positionId == 0) {
            // Create new LP position(which adds liquidity)
            positionId = _mintPosition(pool, upper, lower, amount0, amount1, direction);
            // Order is not in the linked list, validate proposed spot.
            _validateProposedSpotInList(pool, proposedTail, proposedHead, lower, upper);
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
            if (order.token0Amount > 0 || order.token1Amount > 0) {
                // Order is already in the linked list, ignore proposed spot.
                // Need to add liquidity,
                _addToPosition(pool, positionId, amount0, amount1, direction);
                // update token0Amount, token1Amount, userData array(checking if user is already in it).
                _updateOrder(positionId, msg.sender, amount);
            } else {
                // We already have this order.
                // Order is not in the linked list, validate proposed spot.
                _validateProposedSpotInList(pool, proposedTail, proposedHead, lower, upper);
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
        emit UserGroup(msg.sender, orderLinkedList[positionId].userDataId);
    }

    // TODO this could be made payable, to reduce gas cost for users.
    function claimOrder(
        IUniswapV3Pool pool,
        uint256 userDataId,
        address user
    ) external returns (uint256) {
        Claim storage userClaim = claim[userDataId];
        uint256 userLength = userData[userDataId].length;

        // Transfer fee in.
        WRAPPED_NATIVE.safeTransferFrom(msg.sender, address(this), userClaim.feePerUser);

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

    /**
     * @notice This logic will send ALL the swap fees from a position to the last person that cancels the order.
     */
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
                        if (order.token0Amount == depositAmount) liquidityPercentToTake = 1e18;
                        else {
                            liquidityPercentToTake = (1e18 * depositAmount) / order.token0Amount;
                        }
                    } else {
                        if (order.token1Amount == depositAmount) liquidityPercentToTake = 1e18;
                        else {
                            liquidityPercentToTake = (1e18 * depositAmount) / order.token1Amount;
                        }
                    }

                    // Remove user from array.
                    userData[userDataId][i] = UserData({
                        user: userData[userDataId][userLength - 1].user,
                        depositAmount: userData[userDataId][userLength - 1].depositAmount
                    });
                    userData[userDataId].pop();
                    break;
                } else if (i == userLength - 1) {
                    revert("User not found");
                }
            }

            (amount0, amount1) = _takeFromPosition(positionId, pool, liquidityPercentToTake);
            if (liquidityPercentToTake == 1e18) {
                _removeOrderFromList(positionId, pool, order);
                // Zero out balances for cancelled order.
                order.token0Amount = 0;
                order.token1Amount = 0;
            }
        }

        if (amount0 > 0) poolToData[pool].token0.safeTransfer(msg.sender, amount0);
        else if (amount1 > 0) poolToData[pool].token1.safeTransfer(msg.sender, amount1);
        else revert("No liquidity in order");
        // else Determine users share of liquidity and withdraw
    }

    /*//////////////////////////////////////////////////////////////
                     CHAINLINK AUTOMATION LOGIC
    //////////////////////////////////////////////////////////////*/

    // TODO should we add an ITM tick buffer? So that orders must be ITM by atleast buffer ticks.
    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData) {
        uint256[MAX_FILLS_PER_UPKEEP] memory ordersToFulfill;
        uint256 fillCount;
        bool walkDirection;
        // Check if pool center is ITM.
        IUniswapV3Pool pool = abi.decode(checkData, (IUniswapV3Pool));
        (, int24 currentTick, , , , , ) = pool.slot0();

        // Check if the center head is set and ITM.
        uint256 target = poolToData[pool].centerHead;
        Order memory order = orderLinkedList[poolToData[pool].centerHead];
        OrderStatus status;
        if (
            target != 0 &&
            _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction) == OrderStatus.ITM
        ) {
            ordersToFulfill[0] = target;
            fillCount++;
            walkDirection = true; // Walk towards head of list.
            target = order.head;
        } else {
            // Check if the center tail is ITM.
            target = poolToData[pool].centerTail;
            if (target == 0) return (false, abi.encode(0));
            order = orderLinkedList[target];
            status = _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction);
            if (status == OrderStatus.ITM) {
                ordersToFulfill[0] = target;
                fillCount++;
                walkDirection = false; // Walk towards tail of list.
                target = order.tail;
            } else {
                // No orders are ITM.
                return (false, abi.encode(0));
            }
        }

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
                emit OrderFilled(order.userDataId);
                orderFilled = true;
            }
        }

        if (!orderFilled) revert("No orders filled!");
    }

    /*//////////////////////////////////////////////////////////////
                     INTERNAL ORDER LOGIC
    //////////////////////////////////////////////////////////////*/

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
        PoolData memory data = poolToData[pool];
        if (currentTick > upper) {
            // Check if centerTail needs to be updated.
            if (data.centerTail == 0) {
                // Currently no centerTail, so this order must become it.
                // Make sure the centerHead is not ITM, if it has been set.
                if (data.centerHead != 0) {
                    Order memory centerHead = orderLinkedList[data.centerHead];
                    _revertIfOrderITM(currentTick, centerHead);
                }
                poolToData[pool].centerTail = positionId;
            } else {
                Order memory centerTail = orderLinkedList[data.centerTail];
                if (upper > centerTail.tickUpper) {
                    // New position is closer to the current pool tick, so it becomes new centerTail.
                    // Make sure current centerTail is OTM.
                    _revertIfOrderITM(currentTick, centerTail);
                    // Make sure the centerHead is not ITM, if it has been set.
                    if (data.centerHead != 0) {
                        Order memory centerHead = orderLinkedList[data.centerHead];
                        _revertIfOrderITM(currentTick, centerHead);
                    }
                    poolToData[pool].centerTail = positionId;
                }
                // else nothing to do.
            }
        } else if (currentTick < lower) {
            // Check if centerHead needs to be updated.
            if (data.centerHead == 0) {
                // Currently no centerHead, so this order must become it.
                // Make sure the centerTail is not ITM, if it has been set.
                if (data.centerTail != 0) {
                    Order memory centerTail = orderLinkedList[data.centerTail];
                    _revertIfOrderITM(currentTick, centerTail);
                }
                poolToData[pool].centerHead = positionId;
            } else {
                Order memory centerHead = orderLinkedList[data.centerHead];
                if (lower < centerHead.tickLower) {
                    // New position is closer to the current pool tick, so it becomes new centerHead.
                    // Make sure current centerHead is OTM.
                    _revertIfOrderITM(currentTick, centerHead);
                    // Make sure the centerTail is not ITM, if it has been set.
                    if (data.centerTail != 0) {
                        Order memory centerTail = orderLinkedList[data.centerTail];
                        _revertIfOrderITM(currentTick, centerTail);
                    }
                    poolToData[pool].centerHead = positionId;
                }
                // else nothing to do.
            }
        }
    }

    function _revertIfOrderITM(int24 currentTick, Order memory order) internal pure {
        OrderStatus status = _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction);
        if (status == OrderStatus.ITM) revert("User can not update center while orders are ITM.");
    }

    function _checkThatNodeIsInList(
        uint256 node,
        Order memory order,
        PoolData memory data
    ) internal pure {
        if (order.head == 0 && order.tail == 0) {
            // Possible but the order my be centerTail or centerHead.
            if (data.centerHead != node && data.centerTail != node) revert("Order not in list");
        }
    }

    function _validateProposedSpotInList(
        IUniswapV3Pool pool,
        uint256 proposedTail,
        uint256 proposedHead,
        int24 lower,
        int24 upper
    ) internal view {
        PoolData memory data = poolToData[pool];
        if (proposedTail != 0) {
            Order memory tailOrder = orderLinkedList[proposedTail];
            _checkThatNodeIsInList(proposedTail, tailOrder, data);
            if (tailOrder.tickUpper > lower) revert("Bad tail");
            if (tailOrder.head != proposedHead) revert("Skipping nodes.");
        }
        if (proposedHead != 0) {
            Order memory headOrder = orderLinkedList[proposedHead];
            _checkThatNodeIsInList(proposedHead, headOrder, data);
            if (headOrder.tickLower < upper) revert("Bad head");
            if (headOrder.tail != proposedTail) revert("Skipping nodes.");
        }
        if (proposedHead == 0 && proposedTail == 0) {
            // Make sure the list is empty.
            if (data.centerHead != 0 || data.centerTail != 0) revert("List not empty");
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
            order.token0Amount += amount;
        } else {
            // token0
            order.token1Amount += amount;
        }

        // Check if user is already in the order.
        uint256 dataId = order.userDataId;
        uint256 userCount = userData[dataId].length;
        if (userCount == 0) {
            userData[dataId].push(UserData(user, uint96(amount)));
        } else {
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
    }

    function _mintPosition(
        IUniswapV3Pool pool,
        int24 upper,
        int24 lower,
        uint128 amount0,
        uint128 amount1,
        bool direction
    ) internal returns (uint256) {
        // Read these values from state in the contract bs grabbing them from the pool.
        address token0 = pool.token0();
        address token1 = pool.token1();
        if (direction) ERC20(token0).safeApprove(address(positionManager), amount0);
        else ERC20(token1).safeApprove(address(positionManager), amount1);

        // 0.9999e18 accounts for rounding errors in the Uniswap V3 protocol.
        uint128 amount0Min = amount0 == 0 ? 0 : (amount0 * 0.9999e18) / 1e18;
        uint128 amount1Min = amount1 == 0 ? 0 : (amount1 * 0.9999e18) / 1e18;

        // Create mint params.
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: pool.fee(),
            tickLower: lower,
            tickUpper: upper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            recipient: address(this),
            deadline: block.timestamp
        });

        // Supply liquidity to pool.
        (uint256 tokenId, , , ) = positionManager.mint(params);

        // Revert if tokenId received is 0 id.
        // Zero token id is reserved for NULL values in linked list.
        if (tokenId == 0) revert("Zero Token Id not valid");

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
        if (direction) ERC20(token0).safeApprove(address(positionManager), amount0);
        else ERC20(token1).safeApprove(address(positionManager), amount1);

        uint128 amount0Min = amount0 == 0 ? 0 : (amount0 * 0.9999e18) / 1e18;
        uint128 amount1Min = amount1 == 0 ? 0 : (amount1 * 0.9999e18) / 1e18;

        // Create increase liquidity params.
        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams({
                tokenId: positionId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            });

        // Increase liquidity in pool.
        positionManager.increaseLiquidity(params);
        // TODO so it looks like uni will round down by 10 wei or so sometimes, is that worth refunding the user? Probs not they'd spend more on the extra gas.
    }

    function _enforceMinimumLiquidity(uint256 amount, ERC20 asset) internal view {
        uint256 minimum = minimumAssets[asset];
        if (minimum == 0) revert("Minimum not set");
        if (amount < minimum) revert("Minimum not met");
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

        // Zero out order balances.
        order.token0Amount = 0;
        order.token1Amount = 0;

        // Remove order from linked list.
        _removeOrderFromList(target, pool, order);
    }

    function _takeFromPosition(
        uint256 target,
        IUniswapV3Pool pool,
        uint256 liquidityPercent
    ) internal returns (uint128, uint128) {
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
        uint128 amount0Max;
        uint128 amount1Max;
        if (liquidityPercent == 1e18) {
            amount0Max = type(uint128).max;
            amount1Max = type(uint128).max;
        } else {
            // Otherwise only collect principal.
            amount0Max = amount0;
            amount1Max = amount1;
        }
        // Create fee collection params.
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: target,
            recipient: address(this),
            amount0Max: amount0Max,
            amount1Max: amount1Max
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

        return (amount0, amount1);
    }

    function _removeOrderFromList(
        uint256 target,
        IUniswapV3Pool pool,
        Order storage order
    ) internal {
        // Checks if order is the center, if so then it will set it to the the center orders head(which is okay if it is zero).
        uint256 centerHead = poolToData[pool].centerHead;
        uint256 centerTail = poolToData[pool].centerTail;

        if (target == centerHead) {
            uint256 newHead = orderLinkedList[centerHead].head;
            poolToData[pool].centerHead = newHead;
        } else if (target == centerTail) {
            uint256 newTail = orderLinkedList[centerTail].tail;
            poolToData[pool].centerTail = newTail;
        }

        // Remove order from linked list.
        orderLinkedList[order.tail].head = order.head;
        orderLinkedList[order.head].tail = order.tail;
        order.head = 0;
        order.tail = 0;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW LOGIC
    //////////////////////////////////////////////////////////////*/

    function viewList(IUniswapV3Pool pool) public view returns (uint256[10] memory heads, uint256[10] memory tails) {
        uint256 next = poolToData[pool].centerHead;
        for (uint256 i; i < 10; ++i) {
            if (next == 0) break;
            Order memory target = orderLinkedList[next];
            heads[i] = next;
            next = target.head;
        }

        next = poolToData[pool].centerTail;
        for (uint256 i; i < 10; ++i) {
            if (next == 0) break;
            Order memory target = orderLinkedList[next];
            tails[i] = next;
            next = target.tail;
        }
    }

    function findSpot(
        IUniswapV3Pool pool,
        uint256 startingNode,
        int24 targetTick
    ) external view returns (uint256 proposedHead, uint256 proposedTail) {
        if (startingNode == 0) {
            PoolData memory data = poolToData[pool];
            if (data.centerHead != 0) startingNode = data.centerHead;
            else if (data.centerTail != 0) startingNode = data.centerTail;
            else return (0, 0);
        }
        Order memory node = orderLinkedList[startingNode];
        uint256 nodeId = startingNode;
        bool direction = targetTick > node.tickUpper ? true : false;
        while (true) {
            if (direction) {
                // Go until we find an order with a tick lower GREATER or equal to targetTick, then set proposedTail equal to the tail, and proposed head to the current node.
                if (node.tickLower >= targetTick) {
                    return (nodeId, node.tail);
                } else {
                    nodeId = node.head;
                    node = orderLinkedList[nodeId];
                }
            } else {
                // Go until we find tick upper that is LESS than or equal to targetTick
                if (node.tickUpper <= targetTick) {
                    return (node.head, nodeId);
                } else {
                    nodeId = node.tail;
                    node = orderLinkedList[nodeId];
                }
            }
        }
    }
}
