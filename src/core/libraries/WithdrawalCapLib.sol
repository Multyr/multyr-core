// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Percentage } from "../../libs/Percentage.sol";

/// @title WithdrawalCapLib
/// @notice Library for withdrawal cap calculations
library WithdrawalCapLib {
    /// @notice Calculate dynamic cap BPS based on queue depth (linear interpolation)
    function calculateDynamicCapBps(
        uint16 minBps,
        uint16 maxBps,
        uint256 queueThreshold,
        uint256 queueDepth
    ) internal pure returns (uint16) {
        if (queueThreshold == 0 || queueDepth == 0) return maxBps;
        if (queueDepth >= queueThreshold) return minBps;
        return uint16(maxBps - ((uint256(maxBps - minBps) * queueDepth) / queueThreshold));
    }

    /// @notice Calculate remaining immediate withdrawal capacity for current epoch
    function calculateCapRemaining(
        uint256 totalAssets,
        uint16 effectiveCapBps,
        uint256 epochWithdrawn
    ) internal pure returns (uint256) {
        uint256 maxForEpoch = Percentage.mulBpsDown(totalAssets, effectiveCapBps);
        return epochWithdrawn >= maxForEpoch ? 0 : maxForEpoch - epochWithdrawn;
    }

    /// @notice Calculate TVL drop in basis points (0 if no drop)
    function calculateTVLDropBps(uint256 oldTVL, uint256 newTVL) internal pure returns (uint256) {
        if (oldTVL == 0 || newTVL >= oldTVL) return 0;
        return ((oldTVL - newTVL) * 10000) / oldTVL;
    }

    /// @notice Validate withdrawal against per-tx and per-block limits
    function validateLimits(
        uint256 amount,
        uint256 maxPerTx,
        uint256 maxPerBlock,
        uint256 blockWithdrawn
    ) internal pure returns (bool valid, bool exceededTx, bool exceededBlock) {
        exceededTx = maxPerTx > 0 && amount > maxPerTx;
        exceededBlock = maxPerBlock > 0 && (blockWithdrawn + amount) > maxPerBlock;
        valid = !exceededTx && !exceededBlock;
    }
}
