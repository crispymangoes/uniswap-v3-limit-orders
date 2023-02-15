// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { AutomationCompatibleInterface } from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import { Owned } from "@solmate/auth/Owned.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import { IKeeperRegistrar, RegistrationParams } from "src/interfaces/chainlink/IKeeperRegistrar.sol";
import { LimitOrderRegistry } from "src/LimitOrderRegistry.sol";
import { UniswapV3Pool } from "src/interfaces/uniswapV3/UniswapV3Pool.sol";

// TODO could add logic into the LOR that checks if the caller is a users TradeManager, and if so that allows the caller to create/edit orders on behalf of the user.
// TODO add some bool that dictates where assets go, like on claim should assets be returned here, or to the owner
// TODO Could allow users to funds their upkeep through this contract, which would interact with pegswap if needed.

contract TradeManager is Initializable, AutomationCompatibleInterface, Owned {
    using SafeTransferLib for ERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    EnumerableSet.UintSet private ownerOrders; // Set containing all pending orders owner has

    uint32 public constant UPKEEP_GAS_LIMIT = 500_000;

    LimitOrderRegistry public limitOrderRegistry;

    constructor() Owned(address(0)) {}

    function initialize(
        address user,
        LimitOrderRegistry _limitOrderRegistry,
        LinkTokenInterface LINK,
        IKeeperRegistrar registrar,
        uint256 initialUpkeepFunds
    ) external initializer {
        owner = user;
        limitOrderRegistry = _limitOrderRegistry;

        // Create new upkeep
        ERC20(address(LINK)).safeTransferFrom(user, address(this), initialUpkeepFunds);
        ERC20(address(LINK)).safeApprove(address(registrar), initialUpkeepFunds);
        RegistrationParams memory params = RegistrationParams({
            name: "Trade Manager",
            encryptedEmail: abi.encode(0),
            upkeepContract: address(this),
            gasLimit: UPKEEP_GAS_LIMIT,
            adminAddress: user,
            checkData: abi.encode(0),
            offchainConfig: abi.encode(0),
            amount: uint96(initialUpkeepFunds)
        });
        registrar.registerUpkeep(params);
    }

    function newOrder(
        UniswapV3Pool pool,
        ERC20 assetIn,
        int24 targetTick,
        uint128 amount,
        bool direction,
        uint256 startingNode
    ) external onlyOwner {
        uint256 managerBalance = assetIn.balanceOf(address(this));
        // If manager lacks funds, transfer delta into manager.
        if (managerBalance < amount) assetIn.safeTransferFrom(msg.sender, address(this), amount - managerBalance);

        assetIn.safeApprove(address(limitOrderRegistry), amount);
        uint128 userDataId = limitOrderRegistry.newOrder(pool, targetTick, amount, direction, startingNode);
        ownerOrders.add(userDataId);
    }

    function cancelOrder(
        UniswapV3Pool pool,
        int24 targetTick,
        bool direction
    ) external onlyOwner {
        (uint128 amount0, uint128 amount1, uint128 userDataId) = limitOrderRegistry.cancelOrder(
            pool,
            targetTick,
            direction
        );
        if (amount0 > 0) ERC20(pool.token0()).safeTransfer(owner, amount0);
        if (amount1 > 0) ERC20(pool.token1()).safeTransfer(owner, amount1);

        ownerOrders.remove(userDataId);
    }

    function claimOrder(uint128 userDataId, address user) external onlyOwner {
        uint256 value = limitOrderRegistry.getFeePerUser(userDataId);
        limitOrderRegistry.claimOrder{ value: value }(userDataId, user);

        ownerOrders.remove(userDataId);
    }

    function withdrawNative(uint256 amount) external onlyOwner {
        payable(owner).transfer(amount);
    }

    function withdrawERC20(ERC20 token, uint256 amount) external onlyOwner {
        token.safeTransfer(owner, amount);
    }

    receive() external payable {}

    uint256 public constant MAX_CLAIMS = 10;

    struct ClaimInfo {
        uint128 batchId;
        uint128 fee;
    }

    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        uint256 nativeBalance = address(this).balance;
        // Iterate through owner orders, and build a claim array
        uint256 count = ownerOrders.length();
        ClaimInfo[MAX_CLAIMS] memory claimInfo;
        uint256 claimCount;
        for (uint256 i; i < count; ++i) {
            uint128 batchId = uint128(ownerOrders.at(i));
            // Current order is not fulfilled.
            if (!limitOrderRegistry.isOrderReadyForClaim(batchId)) continue;
            uint128 fee = limitOrderRegistry.getFeePerUser(batchId);
            if (fee > nativeBalance) break;
            // Subtract fee from balance.
            nativeBalance -= fee;
            claimInfo[claimCount].batchId = batchId;
            claimInfo[claimCount].fee = fee;
            claimCount++;
        }

        if (claimCount > 0) {
            upkeepNeeded = true;
            performData = abi.encode(claimInfo);
        }
        // else nothing to do.
    }

    // Currently this is claiming as if this contract is the user, which is the intended goal to have an OCO order...
    // But initially just for auto claiming users orders, but maybe the owner should be able to toggle this?

    // I guess the owner could always be the user if the limit order registry was setup to supoprt the trade manager.
    // But if we want the two things to be stand alone, then the use of the LOR should be this contract...
    function performUpkeep(bytes calldata performData) external {
        // Accept claim array and claim all orders
        ClaimInfo[MAX_CLAIMS] memory claimInfo = abi.decode(performData, (ClaimInfo[10]));
        for (uint256 i; i < 10; ++i)
            limitOrderRegistry.claimOrder{ value: claimInfo[i].fee }(claimInfo[i].batchId, address(this));
    }
}
