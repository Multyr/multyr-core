// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title TimelockLib
/// @notice Library for timelock validation - reduces CoreVault bytecode
library TimelockLib {
    error EtaNotReached();
    error EtaExpired();
    error NotPending();

    uint64 internal constant MAX_WINDOW = 7 days;

    /// @notice Validate that a pending change can be accepted
    function validateEta(uint64 eta, bool exists) internal view {
        if (!exists) revert NotPending();
        if (block.timestamp < eta) revert EtaNotReached();
        if (block.timestamp > eta + MAX_WINDOW) revert EtaExpired();
    }

    /// @notice Calculate ETA for a new pending change
    function calculateEta(uint64 delay) internal view returns (uint64) {
        return uint64(block.timestamp) + delay;
    }
}
