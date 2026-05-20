// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ============================================================================
// FixedMaturityStorage — EIP-7201 namespaced storage for FixedMaturity mode
// ============================================================================
// Layout only. No helpers, no logic. All logic lives in FixedMaturityModule
// and FixedMaturityLogicLib to keep existing modules lean.
// ============================================================================

enum VaultMode {
    OpenEnded,
    FixedMaturity
}

enum VaultState {
    Funding,       // accepting deposits, no strategy deployment
    Starting,      // transition: committed assets locked, awaiting activation
    Active,        // capital deployed to fixedTermStrategy
    Matured,       // maturity reached, recall + settlement phase
    Closed,        // terminal: all claims settled, cycle complete
    FundingFailed  // terminal: deadline passed + netFunded < minFundingAssets
}

library FixedMaturityStorage {
    // keccak256(abi.encode(uint256(keccak256("dsf.core.fixedmaturity.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT =
        0xa3a7555930e5242b25f368378dfab11804bc8d89ad6df651515d4b215e809300;

    struct Layout {
        // ── Mode + state ─────────────────────────────────────────────────────
        VaultMode  vaultMode;
        VaultState vaultState;

        // ── Config (one-shot, frozen after configureFixedMaturity) ───────────
        bool     fixedTermConfigured;
        bool     autoCloseFundingOnTarget;
        bool     instantEnabledAfterMaturity;

        uint64   fundingDeadlineTs;
        uint64   maturityTs;
        uint64   startingTs;
        uint64   startTs;

        uint256  minFundingAssets;
        uint256  targetFundingAssets;
        uint256  preMaturityForceExitPenaltyBps;

        // ── Strategy binding (set in configureFixedMaturity) ─────────────────
        address  fixedTermStrategy;

        // ── Lifecycle snapshots ───────────────────────────────────────────────
        uint256  fixedTermCommittedAssets; // net capital locked at Starting
        uint256  retainedHotBuffer;        // hot buffer reserved at Starting

        // ── FundingFailed refund snapshot ─────────────────────────────────────
        // PPS snapshot at markFundingFailed() — used by refundClaim(), never updated after.
        uint256  fundingFailedPPS;

        // ── Final performance fee (applied once at markMatured) ───────────────
        bool     finalPerformanceFeeApplied;
        uint256  finalPerformanceFeeAssets;
        // Snapshot taken at the START of markMatured() BEFORE any fee calculation.
        // Immutable after markMatured() — this is the audit-grade fee basis.
        uint256  finalPerformanceFeeBaseAssets;

        // Principal snapshot taken at Funding -> Starting.
        // Appended in storage to preserve namespaced layout compatibility.
        uint256  fixedTermPrincipalBaseAssets;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}

// ============================================================================
// Gating helpers — minimal free functions, imported by existing modules.
// Each helper has an OpenEnded early-return so existing paths have zero overhead.
// ============================================================================

function _checkDepositsAllowed(FixedMaturityStorage.Layout storage fm) view {
    if (fm.vaultMode == VaultMode.OpenEnded) return;
    if (fm.vaultState == VaultState.Funding) return;
    revert DepositsClosedForVaultState();
}

function _checkStandardExitAllowed(FixedMaturityStorage.Layout storage fm, bool instant) view {
    if (fm.vaultMode == VaultMode.OpenEnded) return;
    if (fm.vaultState == VaultState.Matured) {
        if (instant && !fm.instantEnabledAfterMaturity) revert StandardExitNotAvailablePreMaturity();
        return;
    }
    revert StandardExitNotAvailablePreMaturity();
}

function _checkSettlementAllowed(FixedMaturityStorage.Layout storage fm) view {
    if (fm.vaultMode == VaultMode.OpenEnded) return;
    if (fm.vaultState == VaultState.Matured) return;
    revert SettlementBlockedPreMaturity();
}

function _checkOpenEndedDeployAllowed(FixedMaturityStorage.Layout storage fm) view {
    if (fm.vaultMode == VaultMode.OpenEnded) return;
    revert OpenEndedOnlyPath();
}

function _checkForceExitAllowed(FixedMaturityStorage.Layout storage fm) view {
    if (fm.vaultMode == VaultMode.OpenEnded) return;
    if (fm.vaultState == VaultState.Active) return;
    revert ForceExitNotAvailableInState();
}

// ── FM errors (referenced by gating helpers above) ───────────────────────────
error DepositsClosedForVaultState();
error StandardExitNotAvailablePreMaturity();
error SettlementBlockedPreMaturity();
error ForceExitNotAvailableInState();
error OpenEndedOnlyPath();
