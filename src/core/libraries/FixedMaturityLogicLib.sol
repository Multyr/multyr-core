// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FixedMaturityStorage, VaultMode, VaultState } from "../storage/FixedMaturityStorage.sol";

/// @title FixedMaturityLogicLib — Pure/view helpers for FixedMaturity lifecycle
/// @notice Imported ONLY by FixedMaturityModule to keep existing modules lean.
/// @dev All functions are internal pure or internal view — no side effects.
library FixedMaturityLogicLib {

    // ─── Funding predicates ──────────────────────────────────────────────────

    function isFundingSuccessful(FixedMaturityStorage.Layout storage fm, uint256 netAssets)
        internal view returns (bool)
    {
        return netAssets >= fm.minFundingAssets;
    }

    function isFundingTargetReached(FixedMaturityStorage.Layout storage fm, uint256 netAssets)
        internal view returns (bool)
    {
        return netAssets >= fm.targetFundingAssets;
    }

    /// @notice Returns true when FundingFailed transition should be triggered.
    ///         Strict: net < min (no dust tolerance — V1 intentional).
    function shouldFundingFail(FixedMaturityStorage.Layout storage fm, uint256 netAssets)
        internal view returns (bool)
    {
        return fm.vaultMode == VaultMode.FixedMaturity
            && fm.vaultState == VaultState.Funding
            && block.timestamp >= fm.fundingDeadlineTs
            && netAssets < fm.minFundingAssets;
    }

    // ─── Hot buffer ───────────────────────────────────────────────────────────

    /// @notice Compute the retained hot buffer from totalAssets and minHotBps.
    function computeRetainedHotBuffer(uint256 totalAssets, uint16 minHotBps)
        internal pure returns (uint256)
    {
        return (totalAssets * minHotBps) / 10_000;
    }

    // ─── Performance fee base ─────────────────────────────────────────────────

    /// @notice Gross profit = snapshot - committed (clamped to 0 on loss).
    function computeGrossProfit(uint256 snapshotAssets, uint256 committedAssets)
        internal pure returns (uint256)
    {
        return snapshotAssets > committedAssets ? snapshotAssets - committedAssets : 0;
    }

    // ─── Funding progress ─────────────────────────────────────────────────────

    /// @notice Safe: returns 0 if targetFundingAssets == 0.
    function fundingProgressBps(FixedMaturityStorage.Layout storage fm, uint256 netAssets)
        internal view returns (uint256)
    {
        if (fm.targetFundingAssets == 0) return 0;
        return (netAssets * 10_000) / fm.targetFundingAssets;
    }
}
