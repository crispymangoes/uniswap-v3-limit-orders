// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { AutomationCompatibleInterface } from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import { Owned } from "@solmate/auth/Owned.sol";
import { UniswapV3Pool } from "src/interfaces/uniswapV3/UniswapV3Pool.sol";
import { NonfungiblePositionManager } from "src/interfaces/uniswapV3/NonfungiblePositionManager.sol";
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import { IKeeperRegistrar } from "src/interfaces/chainlink/IKeeperRegistrar.sol";
import { Context } from "@openzeppelin/contracts/utils/Context.sol";

import { console } from "@forge-std/Test.sol";

// TODO are struct memory variables passed by reference? and if so can they be used to update a structs state using the = sign?
// ^^^^ YES they are passed by reference, and you can use that memory struct to change the state of a storage struct.
// V2 Registry on Polygon 0xE16Df59B887e3Caa439E0b29B42bA2e7976FD8b2
// V2 Registrar 0x9a811502d843E5a03913d5A2cfb646c11463467A
contract LimitOrderRegistry is Owned, AutomationCompatibleInterface, ERC721Holder, Context {
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
        uint24 fee;
        uint128 token0Fees; // Swap fees from input token, withdrawable by admin
        uint128 token1Fees; // Swap fees from input token, withdrawable by admin
    }

    struct Order {
        bool direction; //Determines what direction we are going
        int24 tickUpper;
        int24 tickLower;
        uint128 userDataId; // The id where the user data is currently stored
        uint128 token0Amount; //Can either be the deposit amount or the amount got out of liquidity changing to the other token
        uint128 token1Amount; //uint128 is already a restriction in base uniswap V3 protocol.
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

    // How users claim their tokens, just need to pass in the uint120 userDataId
    mapping(uint128 => Claim) public claim;

    mapping(UniswapV3Pool => PoolData) public poolToData;

    mapping(int24 => mapping(int24 => uint256)) public getPositionFromTicks; // maps lower -> upper -> positionId

    // Simplest approach is to have an owner set value for minimum liquidity
    mapping(ERC20 => uint256) public minimumAssets;
    uint32 public upkeepGasLimit = 300_000;
    uint32 public upkeepGasPrice = 30;
    uint16 public maxFillsPerUpkeep = 10;

    // Zero is reserved
    uint128 public userDataCount = 1;

    mapping(uint256 => UserData[]) private userData;

    // Orders can be reused to save on NFT space
    // PositionId to Order
    mapping(uint256 => Order) public orderLinkedList;
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event NewOrder(address user, uint256 userDataId, address pool, uint96 amount, uint96 userTotal);
    // event UserGroup(address user, uint256 group);
    event OrderFilled(uint256 userDataId, address pool);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error LimitOrderRegistry__OrderITM(int24 currentTick, int24 targetTick, bool direction);
    error LimitOrderRegistry__PoolAlreadySetup(address pool);
    error LimitOrderRegistry__PoolNotSetup(address pool);
    error LimitOrderRegistry__InvalidTargetTick(int24 targetTick, int24 tickSpacing);
    error LimitOrderRegistry__UserNotFound(address user, uint256 userDataId);
    error LimitOrderRegistry__InvalidPositionId();
    error LimitOrderRegistry__NoLiquidityInOrder();
    error LimitOrderRegistry__NoOrdersToFulfill();
    error LimitOrderRegistry__CenterITM();
    error LimitOrderRegistry__OrderNotInList(uint256 tokenId);
    error LimitOrderRegistry__MinimumNotSet(address asset);
    error LimitOrderRegistry__MinimumNotMet(address asset, uint256 minimum, uint256 amount);
    error LimitOrderRegistry__InvalidTickRange(int24 upper, int24 lower);

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

    // 0xE16Df59B887e3Caa439E0b29B42bA2e7976FD8b2

    ERC20 public immutable WRAPPED_NATIVE; // Mainnet 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2

    NonfungiblePositionManager public immutable positionManager; // Mainnet 0xC36442b4a4522E871399CD717aBDD847Ab11FE88

    LinkTokenInterface public immutable LINK; // Mainnet 0x514910771AF9Ca656af840dff83E8264EcF986CA

    IKeeperRegistrar public immutable REGISTRAR; // Mainnet 0xDb8e8e2ccb5C033938736aa89Fe4fa1eDfD15a1d

    constructor(
        address _owner,
        NonfungiblePositionManager _positionManager,
        ERC20 wrappedNative,
        LinkTokenInterface link,
        IKeeperRegistrar registrar
    ) Owned(_owner) {
        positionManager = _positionManager;
        WRAPPED_NATIVE = wrappedNative;
        LINK = link;
        REGISTRAR = registrar;
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER LOGIC
    //////////////////////////////////////////////////////////////*/

    function setMaxFillsPerUpkeep(uint16 newVal) external onlyOwner {
        maxFillsPerUpkeep = newVal;
    }

    function setupLimitOrder(UniswapV3Pool pool, uint256 initialUpkeepFunds) external onlyOwner {
        // Check if Limit Order is already setup for `pool`.
        if (address(poolToData[pool].token0) != address(0)) revert LimitOrderRegistry__PoolAlreadySetup(address(pool));

        // TODO can use registerUpkeep instead
        // Create Upkeep.
        if (initialUpkeepFunds > 0) {
            // Owner wants to automatically create an upkeep for new pool.
            SafeTransferLib.safeTransferFrom(ERC20(address(LINK)), owner, address(this), initialUpkeepFunds);
            string memory name = "Limit Order Registry";
            uint96 amount = uint96(initialUpkeepFunds);
            bytes memory upkeepCreationData = abi.encodeWithSelector(
                IKeeperRegistrar.register.selector,
                name,
                abi.encode(0),
                address(this),
                maxFillsPerUpkeep * upkeepGasLimit,
                owner,
                // abi.encode(pool),
                abi.encode(0),
                amount,
                77,
                address(this)
            );
            // TODO to convert above to work with V2, comment out 77 and uncommment abi.encode(pool)
            LINK.transferAndCall(address(REGISTRAR), initialUpkeepFunds, upkeepCreationData);
        }

        // poolToData
        poolToData[pool] = PoolData({
            centerHead: 0,
            centerTail: 0,
            token0: ERC20(pool.token0()),
            token1: ERC20(pool.token1()),
            fee: pool.fee(),
            token0Fees: 0,
            token1Fees: 0
        });
    }

    function setMinimumAssets(uint256 amount, ERC20 asset) external onlyOwner {
        minimumAssets[asset] = amount;
    }

    /// @dev premium should be factored into this value.
    function setUpkeepGasLimit(uint32 gasLimit) external onlyOwner {
        upkeepGasLimit = gasLimit;
    }

    // In units of gwei.
    function setUpkeepGasPrice(uint32 gasPrice) external onlyOwner {
        upkeepGasPrice = gasPrice;
    }

    function withdrawSwapFees(UniswapV3Pool pool) external onlyOwner {
        PoolData storage data = poolToData[pool];

        if (data.token0Fees > 0) {
            data.token0.safeTransfer(owner, data.token0Fees);
            data.token0Fees = 0;
        }
        if (data.token1Fees > 0) {
            data.token1.safeTransfer(owner, data.token1Fees);
            data.token1Fees = 0;
        }
    }

    function withdrawNative() external onlyOwner {
        WRAPPED_NATIVE.safeTransfer(owner, WRAPPED_NATIVE.balanceOf(address(this)));
        payable(owner).transfer(address(this).balance);
    }

    /*//////////////////////////////////////////////////////////////
                        USER ORDER MANAGEMENT LOGIC
    //////////////////////////////////////////////////////////////*/

    // targetTick is the tick where your limit order would be filled.
    function newOrder(
        UniswapV3Pool pool,
        int24 targetTick,
        uint96 amount,
        bool direction,
        uint256 startingNode
    ) external {
        if (address(poolToData[pool].token0) == address(0)) revert LimitOrderRegistry__PoolNotSetup(address(pool));

        (, int24 tick, , , , , ) = pool.slot0();

        // Determine upper and lower ticks.
        int24 upper;
        int24 lower;
        {
            int24 tickSpacing = pool.tickSpacing();
            // Make sure targetTick is divisible by spacing.
            if (targetTick % tickSpacing != 0) revert LimitOrderRegistry__InvalidTargetTick(targetTick, tickSpacing);
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
            if (status != OrderStatus.OTM) revert LimitOrderRegistry__OrderITM(tick, targetTick, direction);
        }

        // Transfer assets into contract before setting any state.
        {
            ERC20 assetIn;
            if (direction) assetIn = poolToData[pool].token0;
            else assetIn = poolToData[pool].token1;
            _enforceMinimumLiquidity(amount, assetIn);
            assetIn.safeTransferFrom(_msgSender(), address(this), amount);
        }

        // Get the position id.
        uint256 positionId = getPositionFromTicks[lower][upper];
        uint128 amount0;
        uint128 amount1;
        uint96 userTotal;
        if (direction) amount0 = amount;
        else amount1 = amount;
        if (positionId == 0) {
            // Create new LP position(which adds liquidity)
            PoolData memory data = poolToData[pool];
            positionId = _mintPosition(data, upper, lower, amount0, amount1, direction);
            // Add it to the list.
            _addPositionToList(data, startingNode, targetTick, positionId);
            // Set new orders upper and lower tick.
            orderLinkedList[positionId].tickLower = lower;
            orderLinkedList[positionId].tickUpper = upper;
            //  create a new userDataId, direction.
            _setupOrder(direction, positionId);
            // update token0Amount, token1Amount, userData array(checking if user is already in it).
            userTotal = _updateOrder(positionId, _msgSender(), amount);

            _updateCenter(pool, positionId, tick, upper, lower);

            // Update getPositionFromTicks since we have a new LP position.
            getPositionFromTicks[lower][upper] = positionId;
        } else {
            // Check if the position id is already being used in List.
            Order memory order = orderLinkedList[positionId];
            if (order.token0Amount > 0 || order.token1Amount > 0) {
                // Order is already in the linked list, ignore proposed spot.
                // Need to add liquidity,
                PoolData memory data = poolToData[pool];
                _addToPosition(data, positionId, amount0, amount1, direction);
                // update token0Amount, token1Amount, userData array(checking if user is already in it).
                userTotal = _updateOrder(positionId, _msgSender(), amount);
            } else {
                // We already have this order.
                PoolData memory data = poolToData[pool];

                // Add it to the list.
                _addPositionToList(data, startingNode, targetTick, positionId);
                //  create a new userDataId, direction.
                _setupOrder(direction, positionId);

                // Need to add liquidity,
                _addToPosition(data, positionId, amount0, amount1, direction);
                // update token0Amount, token1Amount, userData array(checking if user is already in it).
                userTotal = _updateOrder(positionId, _msgSender(), amount);

                _updateCenter(pool, positionId, tick, upper, lower);
            }
        }
        uint256 userDataId = orderLinkedList[positionId].userDataId;
        emit NewOrder(_msgSender(), userDataId, address(pool), amount, userTotal);
    }

    function claimOrder(
        UniswapV3Pool pool,
        uint128 userDataId,
        address user
    ) external payable returns (uint256) {
        Claim storage userClaim = claim[userDataId];
        uint256 userLength = userData[userDataId].length;

        // Transfer fee in.
        address sender = _msgSender();
        if (msg.value >= userClaim.feePerUser) {
            // refund if necessary.
            uint256 refund = msg.value - userClaim.feePerUser;
            if (refund > 0) payable(sender).transfer(refund);
        } else {
            WRAPPED_NATIVE.safeTransferFrom(sender, address(this), userClaim.feePerUser);
        }
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

        revert LimitOrderRegistry__UserNotFound(user, userDataId);
    }

    /**
     * @notice This logic will send ALL the swap fees from a position to the last person that cancels the order.
     */
    function cancelOrder(
        UniswapV3Pool pool,
        int24 targetTick,
        bool direction
    ) external returns (uint128 amount0, uint128 amount1) {
        uint256 positionId;
        {
            // Make sure order is OTM.
            (, int24 tick, , , , , ) = pool.slot0();

            // Determine upper and lower ticks.
            int24 upper;
            int24 lower;
            {
                int24 tickSpacing = pool.tickSpacing();
                // Make sure targetTick is divisible by spacing.
                if (targetTick % tickSpacing != 0)
                    revert LimitOrderRegistry__InvalidTargetTick(targetTick, tickSpacing);
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
                if (status != OrderStatus.OTM) revert LimitOrderRegistry__OrderITM(tick, targetTick, direction);
            }

            // Get the position id.
            positionId = getPositionFromTicks[lower][upper];

            if (positionId == 0) revert LimitOrderRegistry__InvalidPositionId();
        }

        uint256 liquidityPercentToTake;

        // Get the users deposit amount in the order.
        Order storage order = orderLinkedList[positionId];
        address sender = _msgSender();
        {
            uint256 userDataId = order.userDataId;
            uint256 userLength = userData[userDataId].length;
            for (uint256 i; i < userLength; ++i) {
                if (userData[userDataId][i].user == sender) {
                    // Found our user.
                    uint96 depositAmount = userData[userDataId][i].depositAmount;
                    uint128 orderAmount;
                    if (order.direction) {
                        orderAmount = order.token0Amount;
                        if (orderAmount == depositAmount) {
                            liquidityPercentToTake = 1e18;
                            // Update order tokenAmount.
                            order.token0Amount = 0;
                        } else {
                            liquidityPercentToTake = (1e18 * depositAmount) / orderAmount;
                            // Update order tokenAmount.
                            order.token0Amount = orderAmount - depositAmount;
                        }
                    } else {
                        orderAmount = order.token1Amount;
                        if (orderAmount == depositAmount) {
                            liquidityPercentToTake = 1e18;
                            // Update order tokenAmount.
                            order.token1Amount = 0;
                        } else {
                            liquidityPercentToTake = (1e18 * depositAmount) / orderAmount;
                            // Update order tokenAmount.
                            order.token1Amount = orderAmount - depositAmount;
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
                    revert LimitOrderRegistry__UserNotFound(sender, userDataId);
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
        if (order.direction) {
            if (amount0 > 0) poolToData[pool].token0.safeTransfer(sender, amount0);
            else revert LimitOrderRegistry__NoLiquidityInOrder();
            // Save any swap fees.
            if (amount1 > 0) poolToData[pool].token1Fees += amount1;
        } else {
            if (amount1 > 0) poolToData[pool].token1.safeTransfer(sender, amount1);
            else revert LimitOrderRegistry__NoLiquidityInOrder();
            // Save any swap fees.
            if (amount0 > 0) poolToData[pool].token0Fees += amount0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                     CHAINLINK AUTOMATION LOGIC
    //////////////////////////////////////////////////////////////*/

    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData) {
        UniswapV3Pool pool = abi.decode(checkData, (UniswapV3Pool));
        (, int24 currentTick, , , , , ) = pool.slot0();
        PoolData memory data = poolToData[pool];
        Order memory order;
        OrderStatus status;
        bool walkDirection;

        if (data.centerHead != 0) {
            // centerHead is set, check if it is ITM.
            order = orderLinkedList[data.centerHead];
            status = _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction);
            if (status == OrderStatus.ITM) {
                walkDirection = true; // Walk towards head of list.
                upkeepNeeded = true;
                performData = abi.encode(pool, walkDirection);
                return (upkeepNeeded, performData);
            }
        }
        if (data.centerTail != 0) {
            // If walk direction has not been set, then we know, no head orders are ITM.
            // So check tail orders.
            order = orderLinkedList[data.centerTail];
            status = _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction);
            if (status == OrderStatus.ITM) {
                walkDirection = false; // Walk towards tail of list.
                upkeepNeeded = true;
                performData = abi.encode(pool, walkDirection);
                return (upkeepNeeded, performData);
            }
        }
        return (false, abi.encode(0));
    }

    function performUpkeep(bytes calldata performData) external {
        (UniswapV3Pool pool, bool walkDirection) = abi.decode(performData, (UniswapV3Pool, bool));

        if (address(poolToData[pool].token0) == address(0)) revert LimitOrderRegistry__PoolNotSetup(address(pool));

        PoolData storage data = poolToData[pool];

        // Estimate gas cost.
        uint256 estimatedFee = uint256(upkeepGasLimit * upkeepGasPrice) * 1e9; // Multiply by 1e9 to convert gas price to gwei

        (, int24 currentTick, , , , , ) = pool.slot0();
        bool orderFilled;
        uint128 totalToken0Fees;
        uint128 totalToken1Fees;

        // Fulfill orders.
        uint256 target = walkDirection ? data.centerHead : data.centerTail;
        for (uint256 i; i < maxFillsPerUpkeep; ++i) {
            if (target == 0) break;
            Order storage order = orderLinkedList[target];
            OrderStatus status = _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction);
            if (status == OrderStatus.ITM) {
                (uint128 token0Fees, uint128 token1Fees) = _fulfillOrder(target, pool, order, estimatedFee);
                totalToken0Fees += token0Fees;
                totalToken1Fees += token1Fees;
                target = walkDirection ? order.head : order.tail;
                // Zero out orders head and tail values.
                order.head = 0;
                order.tail = 0;
                orderFilled = true;
                emit OrderFilled(order.userDataId, address(pool));
            } else break;
        }

        if (!orderFilled) revert LimitOrderRegistry__NoOrdersToFulfill();

        // Save fees.
        if (totalToken0Fees > 0) poolToData[pool].token0Fees += totalToken0Fees;
        if (totalToken1Fees > 0) poolToData[pool].token1Fees += totalToken1Fees;

        // Update center.
        if (walkDirection) {
            data.centerHead = target;
            // Need to reconnect list.
            orderLinkedList[data.centerTail].head = target;
            if (target != 0) orderLinkedList[target].tail = data.centerTail;
        } else {
            data.centerTail = target;
            // Need to reconnect list.
            orderLinkedList[data.centerHead].tail = target;
            if (target != 0) orderLinkedList[target].head = data.centerHead;
        }
    }

    /*//////////////////////////////////////////////////////////////
                     INTERNAL ORDER LOGIC
    //////////////////////////////////////////////////////////////*/

    function _findSpot(
        PoolData memory data,
        uint256 startingNode,
        int24 targetTick
    ) internal view returns (uint256 proposedHead, uint256 proposedTail) {
        Order memory node;
        if (startingNode == 0) {
            if (data.centerHead != 0) {
                startingNode = data.centerHead;
                node = orderLinkedList[startingNode];
            } else if (data.centerTail != 0) {
                startingNode = data.centerTail;
                node = orderLinkedList[startingNode];
            } else return (0, 0);
        } else {
            node = orderLinkedList[startingNode];
            _checkThatNodeIsInList(startingNode, node, data);
        }
        uint256 nodeId = startingNode;
        bool direction = targetTick > node.tickUpper ? true : false;
        while (true) {
            if (direction) {
                // Go until we find an order with a tick lower GREATER or equal to targetTick, then set proposedTail equal to the tail, and proposed head to the current node.
                if (node.tickLower >= targetTick) {
                    return (nodeId, node.tail);
                } else if (node.head == 0) {
                    // Made it to head of list.
                    return (0, nodeId);
                } else {
                    nodeId = node.head;
                    node = orderLinkedList[nodeId];
                }
            } else {
                // Go until we find tick upper that is LESS than or equal to targetTick
                if (node.tickUpper <= targetTick) {
                    return (node.head, nodeId);
                } else if (node.tail == 0) {
                    // Made it to the tail of the list.
                    return (nodeId, 0);
                } else {
                    nodeId = node.tail;
                    node = orderLinkedList[nodeId];
                }
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
        UniswapV3Pool pool,
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
        if (status == OrderStatus.ITM) revert LimitOrderRegistry__CenterITM();
    }

    function _checkThatNodeIsInList(
        uint256 node,
        Order memory order,
        PoolData memory data
    ) internal pure {
        if (order.head == 0 && order.tail == 0) {
            // Possible but the order my be centerTail or centerHead.
            if (data.centerHead != node && data.centerTail != node) revert LimitOrderRegistry__OrderNotInList(node);
        }
    }

    function _addPositionToList(
        PoolData memory data,
        uint256 startingNode,
        int24 targetTick,
        uint256 position
    ) internal {
        (uint256 head, uint256 tail) = _findSpot(data, startingNode, targetTick);
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
    ) internal returns (uint96 userTotal) {
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
                    return userData[dataId][i].depositAmount;
                }
                if (i == userCount - 1) {
                    // made it to the end and did not find the user, so add them.
                    userData[dataId].push(UserData(user, uint96(amount)));
                    return amount;
                }
            }
        }
    }

    function _mintPosition(
        PoolData memory data,
        int24 upper,
        int24 lower,
        uint128 amount0,
        uint128 amount1,
        bool direction
    ) internal returns (uint256) {
        if (direction) data.token0.safeApprove(address(positionManager), amount0);
        else data.token1.safeApprove(address(positionManager), amount1);

        // 0.9999e18 accounts for rounding errors in the Uniswap V3 protocol.
        uint128 amount0Min = amount0 == 0 ? 0 : (amount0 * 0.9999e18) / 1e18;
        uint128 amount1Min = amount1 == 0 ? 0 : (amount1 * 0.9999e18) / 1e18;

        // Create mint params.
        NonfungiblePositionManager.MintParams memory params = NonfungiblePositionManager.MintParams({
            token0: address(data.token0),
            token1: address(data.token1),
            fee: data.fee,
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
        if (tokenId == 0) revert LimitOrderRegistry__InvalidPositionId();

        // TODO confirm that full aproval is used, and if not the zero it out.

        return tokenId;
    }

    function _addToPosition(
        PoolData memory data,
        uint256 positionId,
        uint128 amount0,
        uint128 amount1,
        bool direction
    ) internal {
        if (direction) data.token0.safeApprove(address(positionManager), amount0);
        else data.token1.safeApprove(address(positionManager), amount1);

        uint128 amount0Min = amount0 == 0 ? 0 : (amount0 * 0.9999e18) / 1e18;
        uint128 amount1Min = amount1 == 0 ? 0 : (amount1 * 0.9999e18) / 1e18;

        // Create increase liquidity params.
        NonfungiblePositionManager.IncreaseLiquidityParams memory params = NonfungiblePositionManager
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
        // TODO confirm that full aproval is used, and if not the zero it out.
        // TODO so it looks like uni will round down by 10 wei or so sometimes, is that worth refunding the user? Probs not they'd spend more on the extra gas.
    }

    function _enforceMinimumLiquidity(uint256 amount, ERC20 asset) internal view {
        uint256 minimum = minimumAssets[asset];
        if (minimum == 0) revert LimitOrderRegistry__MinimumNotSet(address(asset));
        if (amount < minimum) revert LimitOrderRegistry__MinimumNotMet(address(asset), minimum, amount);
    }

    function _getOrderStatus(
        int24 currentTick,
        int24 lower,
        int24 upper,
        bool direction
    ) internal pure returns (OrderStatus status) {
        if (upper == lower) revert LimitOrderRegistry__InvalidTickRange(upper, lower);
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
        UniswapV3Pool pool,
        Order storage order,
        uint256 estimatedFee
    ) internal returns (uint128 token0Fees, uint128 token1Fees) {
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

            // Record any extra swap fees pool earned.
            token0Fees = amount0;
        } else {
            // Copy the tokenIn amount from the order, this is the total user deposit.
            newClaim.token1Amount = order.token1Amount;
            // Total amount received is the difference in balance.
            newClaim.token0Amount = amount0;

            // Record any extra swap fees pool earned.
            token1Fees = amount1;
        }
        newClaim.direction = order.direction;

        // Zero out order balances.
        order.token0Amount = 0;
        order.token1Amount = 0;
    }

    function _takeFromPosition(
        uint256 target,
        UniswapV3Pool pool,
        uint256 liquidityPercent
    ) internal returns (uint128, uint128) {
        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(target);
        liquidity = uint128(uint256(liquidity * liquidityPercent) / 1e18);

        // Create decrease liquidity params.
        NonfungiblePositionManager.DecreaseLiquidityParams memory params = NonfungiblePositionManager
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
        NonfungiblePositionManager.CollectParams memory collectParams = NonfungiblePositionManager.CollectParams({
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
        UniswapV3Pool pool,
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

    function viewList(UniswapV3Pool pool) public view returns (uint256[10] memory heads, uint256[10] memory tails) {
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
        UniswapV3Pool pool,
        uint256 startingNode,
        int24 targetTick
    ) external view returns (uint256 proposedHead, uint256 proposedTail) {
        PoolData memory data = poolToData[pool];

        int24 tickSpacing = pool.tickSpacing();
        // Make sure targetTick is divisible by spacing.
        if (targetTick % tickSpacing != 0) revert LimitOrderRegistry__InvalidTargetTick(targetTick, tickSpacing);

        (proposedHead, proposedTail) = _findSpot(data, startingNode, targetTick);
    }

    function getFeePerUser(uint128 userDataId) external view returns (uint128) {
        return claim[userDataId].feePerUser;
    }

    // TODO view function that takes a target tick, and tries to find the node closest to it.
    function findNode(UniswapV3Pool pool, int24 targetTick) external view returns (uint256 closestNode) {
        int24 tickSpacing = pool.tickSpacing();
        // Make sure targetTick is divisible by spacing.
        if (targetTick % tickSpacing != 0) revert LimitOrderRegistry__InvalidTargetTick(targetTick, tickSpacing);
    }
}
