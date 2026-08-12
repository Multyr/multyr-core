// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EpochQueueStorage } from "../core/modules/EpochedQueueModule.sol";

/// @title IQueueModule
/// @notice Interface for queue-settlement functions accessible via CoreVault fallback routing.
/// @dev Production routes queue selectors exclusively to EpochedQueueModule (see
///      SelectorLib.getQueueModuleSelectors()/getQueueModuleViewSelectors()). The legacy
///      QueueModule members below are kept here only because the test harness
///      (test/helpers/CoreHarness.sol, test/helpers/TestDeployer.sol) still wires QueueModule
///      alongside EpochedQueueModule for the existing test suite -- calling a legacy member
///      against a vault that only has EpochedQueueModule wired (e.g. one deployed via
///      DeployLib/CoreDeployHelper) will revert with ModuleNotSet.
interface IQueueModule {
    // ═══════════════════════════════════════════════════════════════════════════════
    // EPOCH MODEL (EpochedQueueModule) -- production
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Submit a standard (non-instant) withdrawal into the current open epoch
    function requestEpochWithdrawal(uint256 shares)
        external
        returns (uint256 epochId, uint256 claimId);

    /// @notice Cancel a pending claim in an OPEN epoch and return shares to the caller
    function cancelEpochWithdrawal(uint256 epochId, uint256 claimId) external;

    /// @notice Close the currently open epoch, locking PPS for all claims submitted to it
    function closeCurrentEpoch() external;

    /// @notice Pull liquidity for a CLOSED epoch, transitioning it to FUNDED once fully covered
    function fundEpoch(uint256 epochId) external;

    /// @notice Self-serve claim of assets for a FUNDED epoch
    function claimEpochAssets(uint256 epochId, uint256 claimId) external returns (uint256 assets);

    /// @notice Batch self-serve claim across multiple claim IDs in the same FUNDED epoch
    function batchClaimEpochAssets(uint256 epochId, uint256[] calldata claimIds)
        external
        returns (uint256 totalAssets);

    /// @notice Immediate settlement for cap-eligible exits; falls back to the epoch queue otherwise
    function requestInstantWithdrawal(uint256 shares)
        external
        returns (bool settledImmediately, uint256 epochId, uint256 claimId);

    function currentEpochId() external view returns (uint256);

    function epochData(uint256 epochId) external view returns (EpochQueueStorage.EpochData memory);

    function epochClaim(uint256 epochId, uint256 claimId)
        external
        view
        returns (EpochQueueStorage.EpochClaim memory);

    function nextClaimIdForEpoch(uint256 epochId) external view returns (uint256);

    function totalEscrowedShares() external view returns (uint256);

    /// @notice Total unclaimed claims across all epochs -- dynamic-cap "queue depth" signal
    function outstandingClaimCount() external view returns (uint256);

    /// @notice Oldest epoch that is CLOSED but not yet FUNDED
    function oldestUnfundedEpochId() external view returns (uint256);

    function epochDeficit(uint256 epochId) external view returns (uint256);

    function canCloseCurrentEpoch() external view returns (bool);

    /// @notice Claim count of the currently open epoch
    function currentEpochClaimCount() external view returns (uint256);

    // ═══════════════════════════════════════════════════════════════════════════════
    // LEGACY (QueueModule) -- test harness only, not wired in production deploys
    // ═══════════════════════════════════════════════════════════════════════════════

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

    /// @notice Get the next claim ID that will be assigned
    function nextClaimId() external view returns (uint256);

    /// @notice Get the queue length
    function queueLength() external view returns (uint256);

    /// @notice Get pending shares in queue
    function pendingShares() external view returns (uint256);
}
