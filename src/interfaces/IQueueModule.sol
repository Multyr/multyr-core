// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EpochQueueStorage } from "../core/modules/EpochedQueueModule.sol";

/// @title IQueueModule
/// @notice Interface for EpochedQueueModule functions accessible via CoreVault fallback routing
/// @dev Use this interface to call queue functions on CoreVault: IQueueModule(address(vault)).requestEpochWithdrawal(...)
///      "Queue module" = EpochedQueueModule, the sole queue-settlement mechanism.
interface IQueueModule {
    /// @notice Submit a standard (non-instant) withdrawal into the current open epoch
    function requestEpochWithdrawal(uint256 shares)
        external
        returns (uint256 epochId, uint256 claimId);

    /// @notice Close the currently open epoch's settlement bucket (sets no price)
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

    /// @notice Advance the oldest-unfunded epoch cursor past any leading FUNDED epochs
    function syncOldestUnfundedEpoch() external;

    /// @notice Emit InsolvencyEntered / InsolvencyExited if the derived state changed
    function syncInsolvencyState() external;

    /// @notice End epoch and crystallize performance fee
    /// @dev Calls performance fee crystallization and updates NAV smoothing
    function endEpochCrystallize() external;

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    function currentEpochId() external view returns (uint256);

    function epochData(uint256 epochId) external view returns (EpochQueueStorage.EpochData memory);

    function epochClaim(uint256 epochId, uint256 claimId)
        external
        view
        returns (EpochQueueStorage.EpochClaim memory);

    function nextClaimIdForEpoch(uint256 epochId) external view returns (uint256);

    /// @notice Σ nominal assetsOwed over all unclaimed claims (native CoreVault view,
    ///         listed here for convenience: see ICoreVault.totalOwed())
    function totalOwed() external view returns (uint256);

    /// @notice Liquidity earmarked for FUNDED-but-unclaimed claims across all epochs
    ///         (NOT subtracted from NAV: see ICoreVault.totalOwed())
    function reservedForClaims() external view returns (uint256);

    /// @notice Total unclaimed claims across all epochs -- dynamic-cap "queue depth" signal
    function outstandingClaimCount() external view returns (uint256);

    /// @notice Oldest epoch that is CLOSED but not yet FUNDED
    function oldestUnfundedEpochId() external view returns (uint256);

    function epochDeficit(uint256 epochId) external view returns (uint256);

    function canCloseCurrentEpoch() external view returns (bool);

    /// @notice Claim count of the currently open epoch
    function currentEpochClaimCount() external view returns (uint256);
}
