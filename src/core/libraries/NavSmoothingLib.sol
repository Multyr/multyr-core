// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title NavSmoothingLib
/// @notice Library for NAV smoothing calculations using EMA
library NavSmoothingLib {
    /// @notice Calculate EMA: new = (alpha * current + (10000 - alpha) * previous) / 10000
    function calculateEMA(uint16 alphaBps, uint256 current, uint256 previous)
        internal
        pure
        returns (uint256)
    {
        return (uint256(alphaBps) * current + uint256(10000 - alphaBps) * previous) / 10000;
    }

    /// @notice Check if smoothing update interval has passed
    function canUpdate(uint64 lastUpdate, uint256 now_, uint256 minInterval)
        internal
        pure
        returns (bool)
    {
        return lastUpdate == 0 || minInterval == 0 || now_ >= uint256(lastUpdate) + minInterval;
    }

    /// @notice Get effective NAV (smoothed if enabled and initialized, else raw)
    function getEffectiveNav(uint256 raw, uint256 smoothed, bool enabled, bool initialized)
        internal
        pure
        returns (uint256)
    {
        return (enabled && initialized) ? smoothed : raw;
    }
}
