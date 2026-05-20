// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IQueueModule
/// @notice Interface for QueueModule functions accessible via CoreVault fallback routing
/// @dev Use this interface to call queue functions on CoreVault: IQueueModule(address(vault)).requestClaim(...)
interface IQueueModule {
    /// @notice Request a claim (scheduled or immediate)
    /// @param immediate If true, claim is processed immediately if liquidity available
    /// @param shares Number of shares to claim
    function requestClaim(bool immediate, uint256 shares) external;

    /// @notice Cancel a pending claim and return shares to user
    /// @param claimId The ID of the claim to cancel
    function cancelClaim(uint256 claimId) external;

    /// @notice Process queued redemptions
    /// @param maxClaims Maximum number of claims to process in this batch
    function processQueuedRedemptions(uint256 maxClaims) external;

    /// @notice Settle performance fees and process queue
    /// @param maxClaims Maximum number of claims to process after fee settlement
    function settleFeesAndProcessQueue(uint256 maxClaims) external;

    /// @notice End epoch and crystallize performance fee
    /// @dev Calls performance fee crystallization and updates NAV smoothing
    function endEpochCrystallize() external;

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Get the next claim ID that will be assigned
    function nextClaimId() external view returns (uint256);

    /// @notice Get the queue length
    function queueLength() external view returns (uint256);

    /// @notice Get pending shares in queue
    function pendingShares() external view returns (uint256);
}
