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
import { IKeeperRegistrar, RegistrationParams } from "src/interfaces/chainlink/IKeeperRegistrar.sol";
import { Context } from "@openzeppelin/contracts/utils/Context.sol";

import { console } from "@forge-std/Test.sol";

contract LimitOrderRegistry is Owned, AutomationCompatibleInterface, ERC721Holder, Context {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                             STRUCTS
    //////////////////////////////////////////////////////////////*/

    // Stores the last saved center position of the orderBook based off an input UniV3 pool
    struct PoolData {
        uint256 centerHead;
        uint256 centerTail;
        ERC20 token0;
        ERC20 token1;
        uint24 fee;
    }

    struct BatchOrder {
        bool direction; //Determines what direction we are going, set when minting a new position or adding an exiting position to the order book
        int24 tickUpper; // Set when the LP position is minted for the first time
        int24 tickLower; // Set when the LP position is minted for the first time
        uint64 userCount; // Reset on fulfillments, decremented on cancel, incremented on new user entering order
        uint128 batchId; // The id where the user data is currently stored
        uint128 token0Amount; // Updated in _updateOrder, cancelOrder, zeroed out on order fulfillment
        uint128 token1Amount; // Updated in _updateOrder, cancelOrder, zeroed out on order fulfillment
        uint256 head; // updated on order fulfillment, and in _removeOrderFromList, and during _addPositionToList
        uint256 tail; // updated on order fulfillment, and in _removeOrderFromList, and during _addPositionToList
    }

    struct BatchOrderViewData {
        uint256 id;
        BatchOrder batchOrder;
    }

    struct UserData {
        address user;
        uint96 depositAmount;
    }

    // Using the below struct values and the userData array, we can figure out how much a user is owed.
    struct Claim {
        UniswapV3Pool pool;
        uint128 token0Amount; //Can either be the deposit amount or the amount got out of liquidity changing to the other token
        uint128 token1Amount;
        uint128 feePerUser; // Fee in terms of network native asset.
        bool direction; //Determines the token out
        bool isReadyForClaim;
    }

    /*//////////////////////////////////////////////////////////////
                             GLOBAL STATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Stores swap fees earned from limit order where the input token earns swap fees.
     */
    mapping(address => uint256) public tokenToSwapFees;

    // How users claim their tokens, just need to pass in the uint128 batchId
    mapping(uint128 => Claim) public claim;

    mapping(UniswapV3Pool => PoolData) public poolToData;

    mapping(int24 => mapping(int24 => uint256)) public getPositionFromTicks; // maps lower -> upper -> positionId

    // Simplest approach is to have an owner set value for minimum liquidity
    mapping(ERC20 => uint256) public minimumAssets;
    uint32 public upkeepGasLimit = 300_000;
    uint32 public upkeepGasPrice = 30;
    uint16 public maxFillsPerUpkeep = 10;

    // Zero is reserved
    uint128 public batchCount = 1;

    mapping(uint128 => mapping(address => uint128)) private batchIdToUserDepositAmount;

    // Orders can be reused to save on NFT space
    // PositionId to Order
    mapping(uint256 => BatchOrder) public orderBook;

    IKeeperRegistrar public registrar; // Mainnet 0xDb8e8e2ccb5C033938736aa89Fe4fa1eDfD15a1d
    /**
     * @notice Whether or not the contract is shutdown in case of an emergency.
     */
    bool public isShutdown;

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Prevent a function from being called during a shutdown.
     */
    modifier whenNotShutdown() {
        if (isShutdown) revert LimitOrderRegistry__ContractShutdown();

        _;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event NewOrder(address user, address pool, uint128 amount, uint128 userTotal, BatchOrder effectedOrder);
    event ClaimOrder(address user, uint128 batchId, uint256 amount);
    event CancelOrder(address user, uint128 amount0, uint128 amount1, BatchOrder effectedOrder);
    event OrderFilled(uint256 batchId, address pool);
    event ShutdownChanged(bool isShutdown);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error LimitOrderRegistry__OrderITM(int24 currentTick, int24 targetTick, bool direction);
    error LimitOrderRegistry__PoolAlreadySetup(address pool);
    error LimitOrderRegistry__PoolNotSetup(address pool);
    error LimitOrderRegistry__InvalidTargetTick(int24 targetTick, int24 tickSpacing);
    error LimitOrderRegistry__UserNotFound(address user, uint256 batchId);
    error LimitOrderRegistry__InvalidPositionId();
    error LimitOrderRegistry__NoLiquidityInOrder();
    error LimitOrderRegistry__NoOrdersToFulfill();
    error LimitOrderRegistry__CenterITM();
    error LimitOrderRegistry__OrderNotInList(uint256 tokenId);
    error LimitOrderRegistry__MinimumNotSet(address asset);
    error LimitOrderRegistry__MinimumNotMet(address asset, uint256 minimum, uint256 amount);
    error LimitOrderRegistry__InvalidTickRange(int24 upper, int24 lower);
    error LimitOrderRegistry__ZeroFeesToWithdraw(address token);
    error LimitOrderRegistry__ZeroNativeBalance();
    error LimitOrderRegistry__InvalidBatchId();
    error LimitOrderRegistry__OrderNotReadyToClaim(uint128 batchId);
    error LimitOrderRegistry__ContractShutdown();
    error LimitOrderRegistry__ContractNotShutdown();

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

    NonfungiblePositionManager public immutable POSITION_MANAGER; // Mainnet 0xC36442b4a4522E871399CD717aBDD847Ab11FE88

    LinkTokenInterface public immutable LINK; // Mainnet 0x514910771AF9Ca656af840dff83E8264EcF986CA

    constructor(
        address _owner,
        NonfungiblePositionManager _positionManager,
        ERC20 wrappedNative,
        LinkTokenInterface link,
        IKeeperRegistrar _registrar
    ) Owned(_owner) {
        POSITION_MANAGER = _positionManager;
        WRAPPED_NATIVE = wrappedNative;
        LINK = link;
        registrar = _registrar;
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER LOGIC
    //////////////////////////////////////////////////////////////*/

    function setRegistrar(IKeeperRegistrar _registrar) external onlyOwner {
        registrar = _registrar;
    }

    function setMaxFillsPerUpkeep(uint16 newVal) external onlyOwner {
        maxFillsPerUpkeep = newVal;
    }

    function setupLimitOrder(UniswapV3Pool pool, uint256 initialUpkeepFunds) external onlyOwner {
        // Check if Limit Order is already setup for `pool`.
        if (address(poolToData[pool].token0) != address(0)) revert LimitOrderRegistry__PoolAlreadySetup(address(pool));

        // Create Upkeep.
        if (initialUpkeepFunds > 0) {
            // Owner wants to automatically create an upkeep for new pool.
            // SafeTransferLib.safeTransferFrom(ERC20(address(LINK)), owner, address(this), initialUpkeepFunds);
            ERC20(address(LINK)).safeTransferFrom(owner, address(this), initialUpkeepFunds);
            ERC20(address(LINK)).safeApprove(address(registrar), initialUpkeepFunds);
            RegistrationParams memory params = RegistrationParams({
                name: "Limit Order Registry",
                encryptedEmail: abi.encode(0),
                upkeepContract: address(this),
                gasLimit: uint32(maxFillsPerUpkeep * upkeepGasLimit),
                adminAddress: owner,
                checkData: abi.encode(pool),
                offchainConfig: abi.encode(0),
                amount: uint96(initialUpkeepFunds)
            });
            registrar.registerUpkeep(params);
        }

        // poolToData
        poolToData[pool] = PoolData({
            centerHead: 0,
            centerTail: 0,
            token0: ERC20(pool.token0()),
            token1: ERC20(pool.token1()),
            fee: pool.fee()
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

    function withdrawSwapFees(address tokenFeeIsIn) external onlyOwner {
        uint256 fee = tokenToSwapFees[tokenFeeIsIn];

        // Make sure there are actually fees to withdraw.
        if (fee == 0) revert LimitOrderRegistry__ZeroFeesToWithdraw(tokenFeeIsIn);

        tokenToSwapFees[tokenFeeIsIn] = 0;
        ERC20(tokenFeeIsIn).safeTransfer(owner, fee);
    }

    function withdrawNative() external onlyOwner {
        uint256 wrappedNativeBalance = WRAPPED_NATIVE.balanceOf(address(this));
        uint256 nativeBalance = address(this).balance;
        // Make sure there is something to withdraw.
        if (wrappedNativeBalance == 0 && nativeBalance == 0) revert LimitOrderRegistry__ZeroNativeBalance();
        WRAPPED_NATIVE.safeTransfer(owner, WRAPPED_NATIVE.balanceOf(address(this)));
        payable(owner).transfer(address(this).balance);
    }

    /**
     * @notice Shutdown the cellar. Used in an emergency or if the cellar has been deprecated.
     * @dev In the case where
     */
    function initiateShutdown() external whenNotShutdown onlyOwner {
        isShutdown = true;

        emit ShutdownChanged(true);
    }

    /**
     * @notice Restart the cellar.
     */
    function liftShutdown() external onlyOwner {
        if (!isShutdown) revert LimitOrderRegistry__ContractNotShutdown();
        isShutdown = false;

        emit ShutdownChanged(false);
    }

    /*//////////////////////////////////////////////////////////////
                        USER ORDER MANAGEMENT LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Struct used to store variables needed during order creation.
     */
    struct OrderDetails {
        int24 tick;
        int24 upper;
        int24 lower;
        uint128 userTotal;
        uint256 positionId;
        uint128 amount0;
        uint128 amount1;
    }

    /**
     * @notice Creates a new limit order for a specific pool.
     * @dev Limit orders can be created to buy either token0, or token1 of the pool.
     * @param pool the Uniswap V3 pool to create a limit order on.
     * @param targetTick the tick, that when `pool`'s tick passes, the order will be completely fulfilled
     * @param amount the amount of the input token to sell for the desired token out
     * @param direction bool indicating what the desired token out is
     *                  - true  token in = token0 ; token out = token1
     *                  - false token in = token1 ; token out = token0
     * @param startingNode an NFT position id indicating where this contract should start searching for a spot in the list
     *                     - can be zero which defaults to starting the search at center of list
     * @dev reverts if
     *      - pool is not setup
     *      - targetTick is not divisible by the pools tick spacing
     *      - the new order would be ITM
     *      - the new order does not meet minimum liquidity requirements
     *      - transferFrom fails

     * @dev Emits a `NewOrder` event which contains meta data about the order including the orders `batchId`(which is used for claiming/cancelling).
     */
    function newOrder(
        UniswapV3Pool pool,
        int24 targetTick,
        uint128 amount,
        bool direction,
        uint256 startingNode
    ) external whenNotShutdown returns (uint128) {
        if (address(poolToData[pool].token0) == address(0)) revert LimitOrderRegistry__PoolNotSetup(address(pool));

        OrderDetails memory details;
        address sender = _msgSender();

        (, details.tick, , , , , ) = pool.slot0();

        // Determine upper and lower ticks.
        {
            int24 tickSpacing = pool.tickSpacing();
            // Make sure targetTick is divisible by spacing.
            if (targetTick % tickSpacing != 0) revert LimitOrderRegistry__InvalidTargetTick(targetTick, tickSpacing);
            if (direction) {
                details.upper = targetTick;
                details.lower = targetTick - tickSpacing;
            } else {
                details.upper = targetTick + tickSpacing;
                details.lower = targetTick;
            }
        }
        // Validate lower, upper,and direction.
        {
            OrderStatus status = _getOrderStatus(details.tick, details.lower, details.upper, direction);
            if (status != OrderStatus.OTM) revert LimitOrderRegistry__OrderITM(details.tick, targetTick, direction);
        }

        // Transfer assets into contract before setting any state.
        {
            ERC20 assetIn;
            if (direction) assetIn = poolToData[pool].token0;
            else assetIn = poolToData[pool].token1;
            _enforceMinimumLiquidity(amount, assetIn);
            assetIn.safeTransferFrom(sender, address(this), amount);
        }

        // Get the position id.
        details.positionId = getPositionFromTicks[details.lower][details.upper];

        if (direction) details.amount0 = amount;
        else details.amount1 = amount;
        if (details.positionId == 0) {
            // Create new LP position(which adds liquidity)
            PoolData memory data = poolToData[pool];
            details.positionId = _mintPosition(
                data,
                details.upper,
                details.lower,
                details.amount0,
                details.amount1,
                direction
            );
            // Add it to the list.
            _addPositionToList(data, startingNode, targetTick, details.positionId);
            // Set new orders upper and lower tick.
            orderBook[details.positionId].tickLower = details.lower;
            orderBook[details.positionId].tickUpper = details.upper;
            //  create a new batchId, direction.
            _setupOrder(direction, details.positionId);
            // update token0Amount, token1Amount, batchIdToUserDepositAmount mapping.
            details.userTotal = _updateOrder(details.positionId, sender, amount);

            _updateCenter(pool, details.positionId, details.tick, details.upper, details.lower);

            // Update getPositionFromTicks since we have a new LP position.
            getPositionFromTicks[details.lower][details.upper] = details.positionId;
        } else {
            // Check if the position id is already being used in List.
            BatchOrder memory order = orderBook[details.positionId];
            if (order.token0Amount > 0 || order.token1Amount > 0) {
                // Order is already in the linked list, ignore proposed spot.
                // Need to add liquidity,
                PoolData memory data = poolToData[pool];
                _addToPosition(data, details.positionId, details.amount0, details.amount1, direction);
                // update token0Amount, token1Amount, batchIdToUserDepositAmount mapping.
                details.userTotal = _updateOrder(details.positionId, sender, amount);
            } else {
                // We already have this order.
                PoolData memory data = poolToData[pool];

                // Add it to the list.
                _addPositionToList(data, startingNode, targetTick, details.positionId);
                //  create a new batchId, direction.
                _setupOrder(direction, details.positionId);

                // Need to add liquidity,
                _addToPosition(data, details.positionId, details.amount0, details.amount1, direction);
                // update token0Amount, token1Amount, batchIdToUserDepositAmount mapping.
                details.userTotal = _updateOrder(details.positionId, sender, amount);

                _updateCenter(pool, details.positionId, details.tick, details.upper, details.lower);
            }
        }
        uint128 batchId = orderBook[details.positionId].batchId;
        emit NewOrder(sender, address(pool), amount, details.userTotal, orderBook[details.positionId]);
        return batchId;
    }

    /**
     * @notice Users can claim fulfilled orders by passing in the `batchId` corresponding to the order they want to claim.
     * @param batchId the batchId corresponding to a fulfilled order to claim
     * @param user the address of the user in the order to claim for
     * @dev Caller must either approve this contract to spend their Wrapped Native token, and have at least `getFeePerUser` tokens in their wallet.
     *      Or caller must send `getFeePerUser` value with this call.
     */
    function claimOrder(uint128 batchId, address user) external payable returns (uint256) {
        Claim storage userClaim = claim[batchId];
        if (!userClaim.isReadyForClaim) revert LimitOrderRegistry__OrderNotReadyToClaim(batchId);
        uint256 depositAmount = batchIdToUserDepositAmount[batchId][user];
        if (depositAmount == 0) revert LimitOrderRegistry__UserNotFound(user, batchId);

        // Zero out user balance.
        delete batchIdToUserDepositAmount[batchId][user];

        // Calculate owed amount.
        uint256 totalTokenDeposited;
        uint256 totalTokenOut;
        ERC20 tokenOut;
        if (userClaim.direction) {
            totalTokenDeposited = userClaim.token0Amount;
            totalTokenOut = userClaim.token1Amount;
            tokenOut = poolToData[userClaim.pool].token1;
        } else {
            totalTokenDeposited = userClaim.token1Amount;
            totalTokenOut = userClaim.token0Amount;
            tokenOut = poolToData[userClaim.pool].token0;
        }

        uint256 owed = (totalTokenOut * depositAmount) / totalTokenDeposited;

        // Transfer tokens owed to user.
        tokenOut.safeTransfer(user, owed);

        // Transfer fee in.
        address sender = _msgSender();
        if (msg.value >= userClaim.feePerUser) {
            // refund if necessary.
            uint256 refund = msg.value - userClaim.feePerUser;
            if (refund > 0) payable(sender).transfer(refund);
        } else {
            WRAPPED_NATIVE.safeTransferFrom(sender, address(this), userClaim.feePerUser);
        }
        emit ClaimOrder(user, batchId, owed);
        return owed;
    }

    /**
     * @notice Allows users to cancel orders as long as they are completely OTM.
     * @param pool the Uniswap V3 pool that contains the limit order to cancel
     * @param targetTick the targetTick of the order you want to cancel
     * @param direction bool indication the direction of the order
     * @dev This logic will send ALL the swap fees from a position to the last person that cancels the order.
     */
    function cancelOrder(
        UniswapV3Pool pool,
        int24 targetTick,
        bool direction
    )
        external
        returns (
            uint128 amount0,
            uint128 amount1,
            uint128 batchId
        )
    {
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
        BatchOrder storage order = orderBook[positionId];
        if (order.batchId == 0) revert LimitOrderRegistry__InvalidBatchId();
        address sender = _msgSender();
        {
            batchId = order.batchId;
            uint128 depositAmount = batchIdToUserDepositAmount[batchId][sender];
            if (depositAmount == 0) revert LimitOrderRegistry__UserNotFound(sender, batchId);

            // Remove one from the userCount.
            order.userCount--;

            // Zero out user balance.
            delete batchIdToUserDepositAmount[batchId][sender];

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

            (amount0, amount1) = _takeFromPosition(positionId, pool, liquidityPercentToTake);
            if (liquidityPercentToTake == 1e18) {
                _removeOrderFromList(positionId, pool, order);
                // Zero out balances for cancelled order.
                order.token0Amount = 0;
                order.token1Amount = 0;
                // TODO added below like I did for perform upkeep.
                order.batchId = 0;
            }
        }
        if (order.direction) {
            if (amount0 > 0) poolToData[pool].token0.safeTransfer(sender, amount0);
            else revert LimitOrderRegistry__NoLiquidityInOrder();
            // Save any swap fees.
            if (amount1 > 0) tokenToSwapFees[address(poolToData[pool].token1)] += amount1;
        } else {
            if (amount1 > 0) poolToData[pool].token1.safeTransfer(sender, amount1);
            else revert LimitOrderRegistry__NoLiquidityInOrder();
            // Save any swap fees.
            if (amount0 > 0) tokenToSwapFees[address(poolToData[pool].token0)] += amount0;
        }
        emit CancelOrder(sender, amount0, amount1, order);
    }

    /*//////////////////////////////////////////////////////////////
                     CHAINLINK AUTOMATION LOGIC
    //////////////////////////////////////////////////////////////*/

    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData) {
        UniswapV3Pool pool = abi.decode(checkData, (UniswapV3Pool));
        (, int24 currentTick, , , , , ) = pool.slot0();
        PoolData memory data = poolToData[pool];
        BatchOrder memory order;
        OrderStatus status;
        bool walkDirection;

        if (data.centerHead != 0) {
            // centerHead is set, check if it is ITM.
            order = orderBook[data.centerHead];
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
            order = orderBook[data.centerTail];
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

    /**
     * @dev Does not use _removeOrderFromList, so that the center head/tail
     *      value is not updated every single time and order is fulfilled, instead we just update it once at the end.
     */
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
            BatchOrder storage order = orderBook[target];
            OrderStatus status = _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction);
            if (status == OrderStatus.ITM) {
                (uint128 token0Fees, uint128 token1Fees) = _fulfillOrder(target, pool, order, estimatedFee);
                totalToken0Fees += token0Fees;
                totalToken1Fees += token1Fees;
                target = walkDirection ? order.head : order.tail;
                // Zero out orders head and tail values removing order from the list.
                order.head = 0;
                order.tail = 0;
                // Update bool to indicate batch order is ready to handle claims.
                claim[order.batchId].isReadyForClaim = true;
                // Zero out orders batch id.
                order.batchId = 0;
                // Reset user count.
                order.userCount = 0;
                // TODO above was just added to help revert when trying to cancel a fulfilled order, that is now OTM.
                orderFilled = true;
                emit OrderFilled(order.batchId, address(pool));
            } else break;
        }

        if (!orderFilled) revert LimitOrderRegistry__NoOrdersToFulfill();

        // Save fees.
        if (totalToken0Fees > 0) tokenToSwapFees[address(poolToData[pool].token0)] += totalToken0Fees;
        if (totalToken1Fees > 0) tokenToSwapFees[address(poolToData[pool].token1)] += totalToken1Fees;

        // Update center.
        if (walkDirection) {
            data.centerHead = target;
            // Need to reconnect list.
            orderBook[data.centerTail].head = target;
            if (target != 0) orderBook[target].tail = data.centerTail;
        } else {
            data.centerTail = target;
            // Need to reconnect list.
            orderBook[data.centerHead].tail = target;
            if (target != 0) orderBook[target].head = data.centerHead;
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
        BatchOrder memory node;
        if (startingNode == 0) {
            if (data.centerHead != 0) {
                startingNode = data.centerHead;
                node = orderBook[startingNode];
            } else if (data.centerTail != 0) {
                startingNode = data.centerTail;
                node = orderBook[startingNode];
            } else return (0, 0);
        } else {
            node = orderBook[startingNode];
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
                    node = orderBook[nodeId];
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
                    node = orderBook[nodeId];
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
                poolToData[pool].centerTail = positionId;
            } else {
                BatchOrder memory centerTail = orderBook[data.centerTail];
                if (upper > centerTail.tickUpper) {
                    // New position is closer to the current pool tick, so it becomes new centerTail.
                    poolToData[pool].centerTail = positionId;
                }
                // else nothing to do.
            }
        } else if (currentTick < lower) {
            // Check if centerHead needs to be updated.
            if (data.centerHead == 0) {
                // Currently no centerHead, so this order must become it.
                poolToData[pool].centerHead = positionId;
            } else {
                BatchOrder memory centerHead = orderBook[data.centerHead];
                if (lower < centerHead.tickLower) {
                    // New position is closer to the current pool tick, so it becomes new centerHead.
                    poolToData[pool].centerHead = positionId;
                }
                // else nothing to do.
            }
        }
    }

    function _revertIfOrderITM(int24 currentTick, BatchOrder memory order) internal pure {
        OrderStatus status = _getOrderStatus(currentTick, order.tickLower, order.tickUpper, order.direction);
        if (status == OrderStatus.ITM) revert LimitOrderRegistry__CenterITM();
    }

    function _checkThatNodeIsInList(
        uint256 node,
        BatchOrder memory order,
        PoolData memory data
    ) internal pure {
        if (order.head == 0 && order.tail == 0) {
            // Possible but the order may be centerTail or centerHead.
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
            orderBook[tail].head = position;
            orderBook[position].tail = tail;
        }
        if (head != 0) {
            orderBook[head].tail = position;
            orderBook[position].head = head;
        }
    }

    function _setupOrder(bool direction, uint256 position) internal {
        BatchOrder storage order = orderBook[position];
        order.batchId = batchCount;
        order.direction = direction;
        batchCount++;
    }

    function _updateOrder(
        uint256 positionId,
        address user,
        uint128 amount
    ) internal returns (uint128 userTotal) {
        BatchOrder storage order = orderBook[positionId];
        if (order.direction) {
            // token1
            order.token0Amount += amount;
        } else {
            // token0
            order.token1Amount += amount;
        }

        // Check if user is already in the order.
        uint128 batchId = order.batchId;
        uint128 originalDepositAmount = batchIdToUserDepositAmount[batchId][user];
        // If this is a new user in the order, add 1 to userCount.
        if (originalDepositAmount == 0) order.userCount++;
        batchIdToUserDepositAmount[batchId][user] = originalDepositAmount + amount;
        return (originalDepositAmount + amount);
    }

    function _mintPosition(
        PoolData memory data,
        int24 upper,
        int24 lower,
        uint128 amount0,
        uint128 amount1,
        bool direction
    ) internal returns (uint256) {
        if (direction) data.token0.safeApprove(address(POSITION_MANAGER), amount0);
        else data.token1.safeApprove(address(POSITION_MANAGER), amount1);

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
        (uint256 tokenId, , , ) = POSITION_MANAGER.mint(params);

        // Revert if tokenId received is 0 id.
        // Zero token id is reserved for NULL values in linked list.
        if (tokenId == 0) revert LimitOrderRegistry__InvalidPositionId();

        // If position manager still has allowance, zero it out.
        if (direction && data.token0.allowance(address(this), address(POSITION_MANAGER)) > 0)
            data.token0.safeApprove(address(POSITION_MANAGER), 0);
        if (!direction && data.token1.allowance(address(this), address(POSITION_MANAGER)) > 0)
            data.token1.safeApprove(address(POSITION_MANAGER), 0);

        return tokenId;
    }

    function _addToPosition(
        PoolData memory data,
        uint256 positionId,
        uint128 amount0,
        uint128 amount1,
        bool direction
    ) internal {
        if (direction) data.token0.safeApprove(address(POSITION_MANAGER), amount0);
        else data.token1.safeApprove(address(POSITION_MANAGER), amount1);

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
        POSITION_MANAGER.increaseLiquidity(params);

        // If position manager still has allowance, zero it out.
        if (direction && data.token0.allowance(address(this), address(POSITION_MANAGER)) > 0)
            data.token0.safeApprove(address(POSITION_MANAGER), 0);
        if (!direction && data.token1.allowance(address(this), address(POSITION_MANAGER)) > 0)
            data.token1.safeApprove(address(POSITION_MANAGER), 0);
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
        BatchOrder storage order,
        uint256 estimatedFee
    ) internal returns (uint128 token0Fees, uint128 token1Fees) {
        // Save fee per user in Claim Struct.
        uint256 totalUsers = order.userCount;
        Claim storage newClaim = claim[order.batchId];
        newClaim.feePerUser = uint128(estimatedFee / totalUsers);
        newClaim.pool = pool;

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
        (, , , , , , , uint128 liquidity, , , , ) = POSITION_MANAGER.positions(target);
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
            (uint256 a0, uint256 a1) = POSITION_MANAGER.decreaseLiquidity(params);
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
        POSITION_MANAGER.collect(collectParams);

        amount0 = uint128(token0.balanceOf(address(this)) - token0Balance);
        amount1 = uint128(token1.balanceOf(address(this)) - token1Balance);

        return (amount0, amount1);
    }

    function _removeOrderFromList(
        uint256 target,
        UniswapV3Pool pool,
        BatchOrder storage order
    ) internal {
        // Checks if order is the center, if so then it will set it to the the center orders head(which is okay if it is zero).
        uint256 centerHead = poolToData[pool].centerHead;
        uint256 centerTail = poolToData[pool].centerTail;

        if (target == centerHead) {
            uint256 newHead = orderBook[centerHead].head;
            poolToData[pool].centerHead = newHead;
        } else if (target == centerTail) {
            uint256 newTail = orderBook[centerTail].tail;
            poolToData[pool].centerTail = newTail;
        }

        // Remove order from linked list.
        orderBook[order.tail].head = order.head;
        orderBook[order.head].tail = order.tail;
        order.head = 0;
        order.tail = 0;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Helper function to view the top 20 entries in the linked list.
     */
    //  TODO make this more verbose so FE can use it to show exact state.
    function viewList(UniswapV3Pool pool) public view returns (uint256[10] memory heads, uint256[10] memory tails) {
        uint256 next = poolToData[pool].centerHead;
        for (uint256 i; i < 10; ++i) {
            if (next == 0) break;
            BatchOrder memory target = orderBook[next];
            heads[i] = next;
            next = target.head;
        }

        next = poolToData[pool].centerTail;
        for (uint256 i; i < 10; ++i) {
            if (next == 0) break;
            BatchOrder memory target = orderBook[next];
            tails[i] = next;
            next = target.tail;
        }
    }

    function walkOrders(
        UniswapV3Pool pool,
        uint256 startingNode,
        uint256 returnCount,
        bool direction
    ) external view returns (BatchOrderViewData[] memory orders) {
        orders = new BatchOrderViewData[](returnCount);
        PoolData memory data = poolToData[pool];
        if (direction) {
            // Walk toward head.
            uint256 targetId = startingNode == 0 ? data.centerHead : startingNode;
            BatchOrder memory target = orderBook[targetId];
            for (uint256 i; i < returnCount; ++i) {
                orders[i] = BatchOrderViewData({ id: targetId, batchOrder: target });
                targetId = target.head;
                if (targetId != 0) target = orderBook[targetId];
                else break;
            }
        } else {
            // Walk toward tail.
            uint256 targetId = startingNode == 0 ? data.centerTail : startingNode;
            BatchOrder memory target = orderBook[targetId];
            for (uint256 i; i < returnCount; ++i) {
                orders[i] = BatchOrderViewData({ id: targetId, batchOrder: target });
                targetId = target.tail;
                if (targetId != 0) target = orderBook[targetId];
                else break;
            }
        }
    }

    /**
     * @notice Helper function that finds the appropriate spot in the linked list for a new order.
     * @param pool the Uniswap V3 pool you want to create an order in
     * @param startingNode the UniV3 position Id to start looking
     * @param targetTick the targetTick of the order you want to place
     * @return proposedHead , proposedTail pr the correct head and tail for the new order
     * @dev if both head and tail are zero, just pass in zero for the `startingNode`
     *      otherwise pass in either the nonzero head or nonzero tail for the `startingNode`
     */
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

    /**
     * @notice Helper function to get the fee per user for a specific order.
     */
    function getFeePerUser(uint128 batchId) external view returns (uint128) {
        return claim[batchId].feePerUser;
    }

    function isOrderReadyForClaim(uint128 batchId) external view returns (bool) {
        return claim[batchId].isReadyForClaim;
    }

    /**
     * @notice Given a pool and target tick, find the closest node in the list
     */
    function findNode(UniswapV3Pool pool, int24 targetTick) external view returns (uint256 closestNode) {
        int24 tickSpacing = pool.tickSpacing();
        // Make sure targetTick is divisible by spacing.
        if (targetTick % tickSpacing != 0) revert LimitOrderRegistry__InvalidTargetTick(targetTick, tickSpacing);

        int24 delta;

        PoolData memory data = poolToData[pool];

        // List is empty.
        if (data.centerHead == 0 && data.centerTail == 0) return 0;

        while (true) {
            uint256 upperNode = getPositionFromTicks[targetTick + delta][targetTick + delta + tickSpacing];
            uint256 lowerNode = getPositionFromTicks[targetTick - delta - tickSpacing][targetTick - delta];

            // Check if the upper node is in the list.
            if (upperNode != 0) {
                BatchOrder memory order = orderBook[upperNode];
                if (
                    order.head != 0 || order.tail != 0 || data.centerHead != upperNode || data.centerTail != upperNode
                ) {
                    // Node is in the list
                    return upperNode;
                }
            }

            if (lowerNode != 0) {
                BatchOrder memory order = orderBook[lowerNode];
                if (
                    order.head != 0 || order.tail != 0 || data.centerHead != lowerNode || data.centerTail != lowerNode
                ) {
                    // Node is in the list
                    return lowerNode;
                }
            }

            delta += tickSpacing;
        }
    }
}
