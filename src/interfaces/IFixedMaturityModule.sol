// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { VaultMode, VaultState } from "../core/storage/FixedMaturityStorage.sol";

/// @title IFixedMaturityModule — Public interface for FixedMaturity lifecycle module
interface IFixedMaturityModule {

    // ── Governance (ROLE_OWNER) ───────────────────────────────────────────────

    function setVaultModeFixedMaturity() external;

    function configureFixedMaturity(
        uint64  maturityTs_,
        uint256 minFundingAssets_,
        uint256 targetFundingAssets_,
        uint64  fundingDeadlineTs_,
        bool    autoCloseFundingOnTarget_,
        bool    instantEnabledAfterMaturity_,
        uint256 preMaturityForceExitPenaltyBps_,
        address fixedTermStrategy_
    ) external;

    function startFixedMaturityCycle() external;
    function activateFixedMaturityCycle() external;
    function closeFixedMaturityCycle() external;
    function recallFixedTermCapital() external;

    // ── Permissionless time/condition-gated (ROLE_PUBLIC) ────────────────────

    function markMatured() external;
    function markFundingFailed() external;
    function refundClaim(uint256 shares) external;

    // ── Views (ROLE_PUBLIC) ──────────────────────────────────────────────────

    function isDepositOpen() external view returns (bool);
    function isSettlementOpen() external view returns (bool);
    function isInstantExitOpen() external view returns (bool);
    function currentVaultModeAndState() external view returns (VaultMode, VaultState);
    function netFundedAssets() external view returns (uint256);
    function isFundingSuccessful() external view returns (bool);
    function isFundingTargetReached() external view returns (bool);
    function fundingProgressBps() external view returns (uint256);
    function finalPerformanceFeeStatus() external view returns (bool applied, uint256 assets);

    // Config getters (used by upkeep and off-chain tooling)
    function fundingDeadlineTs() external view returns (uint64);
    function maturityTs() external view returns (uint64);
    function minFundingAssets() external view returns (uint256);
    function fixedTermStrategy() external view returns (address);
}
