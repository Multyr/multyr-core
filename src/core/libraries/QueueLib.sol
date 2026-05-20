// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title QueueLib
/// @notice Library for queue anti-spam and epoch management
library QueueLib {
    /// @notice Check if cooldown period is still active
    function isCooldownActive(uint64 lastTime, uint256 now_, uint256 cooldown)
        internal
        pure
        returns (bool)
    {
        return lastTime > 0 && cooldown > 0 && now_ < uint256(lastTime) + cooldown;
    }

    /// @notice Check if user has exceeded claims per epoch
    function isClaimCountExceeded(uint8 count, uint8 max) internal pure returns (bool) {
        return max > 0 && count >= max;
    }

    /// @notice Determine if epoch should be advanced
    function shouldAdvanceEpoch(uint256 now_, uint64 epochStart, uint256 duration)
        internal
        pure
        returns (bool shouldAdvance, uint64 newStart)
    {
        if (duration == 0) return (false, epochStart);
        if (epochStart == 0 || now_ >= uint256(epochStart) + duration) return (true, uint64(now_));
        return (false, epochStart);
    }
}
