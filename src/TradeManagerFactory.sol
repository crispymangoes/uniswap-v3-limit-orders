// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import { IKeeperRegistrar } from "src/interfaces/chainlink/IKeeperRegistrar.sol";
import { LimitOrderRegistry } from "src/LimitOrderRegistry.sol";
import { TradeManager } from "src/TradeManager.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

contract TradeManagerFactory {
    using SafeTransferLib for ERC20;
    using Clones for address;

    address public immutable implementation;

    constructor(address _implementation) {
        implementation = _implementation;
    }

    event ManagerCreated(address manager);

    function createTradeManager(
        LimitOrderRegistry _limitOrderRegistry,
        LinkTokenInterface LINK,
        IKeeperRegistrar registrar,
        uint256 initialUpkeepFunds
    ) external returns (TradeManager manager) {
        address payable clone = payable(implementation.clone());
        ERC20(address(LINK)).safeTransferFrom(msg.sender, address(this), initialUpkeepFunds);
        ERC20(address(LINK)).safeApprove(clone, initialUpkeepFunds);
        manager = TradeManager(clone);
        manager.initialize(msg.sender, _limitOrderRegistry, LINK, registrar, initialUpkeepFunds);
        emit ManagerCreated(address(manager));
    }
}
