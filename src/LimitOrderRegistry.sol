// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { AutomationCompatibleInterface } from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";

contract LimitOrderRegistry is AutomationCompatibleInterface {
    using SafeTransferLib for ERC20;

    // Stores the last saved center position of the orderLinkedList based off an input UniV3 pool
    mapping(address => uint256) public poolToOrderCenter;

    struct UserData {
        address user;
        uint96 depositAmount;
    }

    uint128 userDataCount = 1;

    mapping(uint128 => UserData[]) private userData;

    uint24 public constant BUFFER = 10; // The number of ticks past the endTick needed for checkUpkeep to trigger an upkeep.
    // The minimum spacing between new order ticks is this mulitplier times the pools min tick spacing, this way users can better
    uint24 public constant NEW_ORDER_MULTIPLIER;
    //^^ also acts as the tick precision, so if a user is trying to make a new order between two ticks, then it rounds up or down to the neaest tick that is a multiple of the pool tick spacing and this multiplier

    //TODO I think for new orders we need to enforce that one of the tokens in the pool has a data feed so we can fund upkeeps overtime and use TWAPS for conversion.

    struct Order {
        address token0;
        address token1;
        bool token0OrToken1; //Determines what direction we are going
        uint128 token0Amount; //Can either be the deposit amount or the amount got out of liquidity changing to the other token
        uint128 token1Amount;
        int24 tickUpper;
        int24 tickLower;
        uint128 userDataId; // The id where the user data is currently stored
        uint256 head;
        uint256 tail;
    }

    //TODO emit what userDataId a user is in when they add liquiidty
    //TODO emit when a keeper fills an order and emit the userDataId filled

    // Orders can be reused to save on NFT space
    mapping(uint256 => Order) public orderLinkedList;

    // Using the below struct values and the userData array, we can figure out how much a user is owed.
    struct Claim {
        bool token0OrToken1; //Determines the token out
        uint128 token0Amount; //Can either be the deposit amount or the amount got out of liquidity changing to the other token
        uint128 token1Amount;
    }

    // How users claim their tokens, just need to pass in the uint128 userDataId
    mapping(uint128 => Claim) public claim;

    //TODO maybe orders need a min liquidity amount to prevernt people from spamming low liquidity orders?
}
