// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

contract LimitOrderRegistry {
    struct LimitOrderMetaData {
        address assetIn;
        address assetOut;
        bytes32[] batchIds;
        bytes32 limitBatchHead;
    }

    LimitOrderMetaData[] private limitOrderMetaData;

    struct LimitBatch {
        uint256 totalAssetsIn;
        uint256 totalAssetsOut;
        uint256 triggerPrice;
        bytes32 tail;
    }

    /**
     * @notice Maps a bytes32 id to a LimitBatch
     */
    mapping(bytes32 => LimitBatch) public getLimitBatch;

    /**
     * Record how much assets a user deposited into a LimitBatch.
     */
    mapping(bytes32 => mapping(address => uint256)) public limitBatchIdToUserAmount;

    /**
     * @notice `limitBatchTarget` should either be the actual limitBatch to add the order to, or if the price does not exist, then
     * it should be the limit batch that comes before
     * @param limitOrderMetaDataId is the index in
     */
    function openLimitOrder(
        uint256 limitOrderMetaDataId,
        uint256 price,
        uint256 amount,
        bytes32 limitBatchTarget
    ) external {
        LimitOrderMetaData memory metaData = limitOrderMetaData[limitOrderMetaDataId];
        //tranafer asset in.
    }
}
