// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CoreStorage } from "../storage/CoreStorage.sol";
import { QueueStorage } from "../storage/QueueStorage.sol";
import { FeeStorage } from "../storage/FeeStorage.sol";
import { ExitFeeLib } from "./ExitFeeLib.sol";
import { WithdrawalCapLib } from "./WithdrawalCapLib.sol";
import { Percentage } from "../../libs/Percentage.sol";
import { IParamsProvider } from "../../interfaces/IParamsProvider.sol";

/// @title ExitEngineLib — Single source of truth for exit orchestration + policy
/// @notice Pure library: epoch rollover, cap enforcement, fee computation, exit simulation.
/// @dev CRITICAL INVARIANTS:
///   1. withdraw()/redeem() ALWAYS revert AsyncWithdrawalRequired
///   2. epochWithdrawn <= cap (INSTANT mode only)
///   3. totalSupply NEVER increases on exit (no _mint in any exit path)
///   4. feeShares always from owner/escrow (transfer, not mint)
///   5. simulateExit == runtime execution (identical formulas, rounding, order)
///   6. forceWithdraw does NOT consume epoch cap
///
///   ExitFeeLib is a SEPARATE library — this engine calls it, does NOT absorb it.
library ExitEngineLib {
    // ═══════════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════════

    enum ExitMode {
        STANDARD, // queued exit (requestClaim(false)) — witBps only
        INSTANT, // immediate exit (requestClaim(true)) — witBps + immediateExitPenaltyBps
        FORCE // force exit (forceWithdraw) — witBps + forceExitPenaltyBps
    }

    struct ExitResult {
        uint256 grossAssets; // total assets before fee (rounded DOWN)
        uint256 netAssets; // EXACT for INSTANT/FORCE, INDICATIVE for STANDARD (see note)
        uint256 feeShares; // shares to feeCollector (rounded UP) — exact for all modes
        uint256 userShares; // shares burned for user (shares - feeShares) — exact for all modes
        uint256 withdrawFeeAssets; // base withdrawal fee in assets
        uint256 penaltyAssets; // penalty fee in assets (immediate or force)
        bool willQueue; // true if exit cannot settle immediately
        uint256 epochCapRemaining; // cap remaining after this exit
        // NOTE on netAssets:
        //   INSTANT/FORCE: netAssets is EXACT — settlement happens in the same tx.
        //   STANDARD: netAssets is INDICATIVE — settlement is deferred to a future tx,
        //     and totalAssets/totalSupply may change between queue and settle.
        //     The actual net at settlement depends on the PPS at settlement time.
        //     Use feeShares and userShares (which are exact) for accounting.
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Thrown by withdraw()/redeem() — protocol requires queue-based exits
    error AsyncWithdrawalRequired();

    /// @notice Epoch duration not initialized (deploy-time guarantee)
    error EpochDurationNotSet();

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    uint64 internal constant MIN_EPOCH_DURATION = 1 days;
    uint64 internal constant MAX_EPOCH_DURATION = 30 days;

    // ═══════════════════════════════════════════════════════════════════════════════
    // EPOCH MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Roll epoch if current epoch has expired. Parametric duration.
    /// @dev MUST be called before any cap check or epoch consumption.
    ///      epochDuration MUST be initialized at deploy time (no zero fallback).
    /// @param core CoreStorage layout
    /// @return rolled True if epoch was rolled
    function rollEpochIfNeeded(CoreStorage.Layout storage core) internal returns (bool rolled) {
        uint64 dur = core.epochDuration;
        if (dur == 0) revert EpochDurationNotSet();

        uint64 es = core.epochStart;
        uint64 next = es + dur;

        if (block.timestamp >= next) {
            // Align epoch start to duration boundary relative to original start
            core.epochStart =
                uint64(block.timestamp - ((block.timestamp - es) % dur));
            core.epochWithdrawn = 0;
            return true;
        }
        return false;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CAP CALCULATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Calculate remaining immediate withdrawal capacity for current epoch
    /// @dev Uses LIVE totalAssets (no snapshot) per CTO directive.
    ///      Incorporates dynamic cap from WithdrawalCapLib if enabled.
    /// @param core CoreStorage layout
    /// @param q QueueStorage layout
    /// @param totalAssets Current live totalAssets()
    /// @param vault Address of the vault (for ParamsProvider calls)
    /// @return remaining Remaining capacity in asset units
    function calculateCapRemaining(
        CoreStorage.Layout storage core,
        QueueStorage.Layout storage q,
        uint256 totalAssets,
        address vault
    ) internal view returns (uint256 remaining) {
        IParamsProvider.WithdrawalParams memory wp =
            core.params.getWithdrawalParams(vault);
        IParamsProvider.DynamicCapParams memory dcp =
            core.params.getDynamicCapParams(vault);

        uint16 cap;
        if (dcp.enabled) {
            if (dcp.minBps == 0 || dcp.maxBps == 0) {
                cap = wp.capPerEpochBps;
            } else {
                uint256 queueLen =
                    q.queue.length > q.head ? q.queue.length - q.head : 0;
                cap = WithdrawalCapLib.calculateDynamicCapBps(
                    dcp.minBps, dcp.maxBps, dcp.queueStressThreshold, queueLen
                );
            }
        } else {
            cap = wp.capPerEpochBps == 0 ? type(uint16).max : wp.capPerEpochBps;
        }

        if (cap == type(uint16).max) return type(uint256).max;

        return WithdrawalCapLib.calculateCapRemaining(
            totalAssets, cap, core.epochWithdrawn
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FEE COMPUTATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Compute fee shares (rounded UP) and user shares for a given exit
    /// @dev feeShares = mulBpsUp(shares, totalFeeBps) — directive #5
    ///      userShares = shares - feeShares (exact arithmetic)
    /// @param shares Total shares being exited
    /// @param mode Exit mode (determines fee tiers)
    /// @param fee Fee parameters from FeeStorage
    /// @return feeShares Shares transferred to feeCollector (rounded UP)
    /// @return userShares Shares burned for user
    function computeFeeShares(
        uint256 shares,
        ExitMode mode,
        FeeStorage.InternalFeeParams memory fee
    ) internal view returns (uint256 feeShares, uint256 userShares) {
        bool isImmediate = mode == ExitMode.INSTANT;
        bool isForce = mode == ExitMode.FORCE;

        uint16 totalFeeBps = ExitFeeLib.exitFeeBps(isImmediate, isForce, fee);

        if (totalFeeBps == 0) {
            return (0, shares);
        }

        // Rounded UP per directive #5
        feeShares = Percentage.mulBpsUp(shares, totalFeeBps);

        // Safety: feeShares cannot exceed shares
        if (feeShares > shares) {
            feeShares = shares;
        }

        userShares = shares - feeShares;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // EXIT SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Simulate an exit for preview/max functions
    /// @dev SEMANTICS:
    ///      - INSTANT/FORCE: netAssets is EXACT — identical to runtime (same tx).
    ///        Same formulas, same rounding, same operation order.
    ///      - STANDARD (queued): netAssets is INDICATIVE — the queued path cannot
    ///        promise today the exact net of a future settlement. The PPS at
    ///        settlement time may differ. feeShares and userShares ARE exact
    ///        (computed at queue time), but the asset conversion is indicative.
    ///
    ///      Callers MUST provide inputs computed AFTER soft NAV refresh:
    ///        grossAssets = convertToAssets(shares)
    ///        totalAssets = totalAssets()
    ///        totalSupply = totalSupply()
    ///
    /// @param shares Shares being exited
    /// @param mode Exit mode
    /// @param grossAssets convertToAssets(shares) — caller provides, same function as runtime
    /// @param totalAssets Live totalAssets()
    /// @param totalSupply Current totalSupply()
    /// @param capRemaining Epoch cap remaining (from calculateCapRemaining)
    /// @param fee Fee parameters
    /// @return r ExitResult with all computed values
    function simulateExit(
        uint256 shares,
        ExitMode mode,
        uint256 grossAssets,
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 capRemaining,
        FeeStorage.InternalFeeParams memory fee
    ) internal view returns (ExitResult memory r) {
        r.grossAssets = grossAssets;

        // Step 1: Fee in assets (for reporting)
        bool isImmediate = mode == ExitMode.INSTANT;
        bool isForce = mode == ExitMode.FORCE;

        (, uint256 withdrawFee, uint256 penaltyFee) =
            ExitFeeLib.computeExitFee(grossAssets, isImmediate, isForce, fee);

        r.withdrawFeeAssets = withdrawFee;
        r.penaltyAssets = penaltyFee;

        // Step 2: Fee in shares (rounded UP — directive #5)
        (r.feeShares, r.userShares) = computeFeeShares(shares, mode, fee);

        // Step 3: Net assets (rounded DOWN — same formula as OZ convertToAssets)
        if (totalSupply == 0) {
            r.netAssets = 0;
        } else {
            r.netAssets = (totalAssets * r.userShares) / totalSupply;
        }

        // Step 4: Queue/settlement decision
        if (mode == ExitMode.STANDARD) {
            // STANDARD: always queues
            r.willQueue = true;
            r.epochCapRemaining = capRemaining;
        } else if (mode == ExitMode.INSTANT) {
            // INSTANT: queues if cap insufficient
            r.willQueue = grossAssets > capRemaining;
            r.epochCapRemaining =
                r.willQueue ? capRemaining : capRemaining - grossAssets;
        } else {
            // FORCE: never queues, no cap consumption
            r.willQueue = false;
            r.epochCapRemaining = capRemaining;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // EPOCH CONSUMPTION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Record epoch consumption after an INSTANT settlement
    /// @dev ONLY called for INSTANT mode. FORCE does NOT consume cap.
    /// @param core CoreStorage layout
    /// @param grossAssets Gross assets consumed
    function consumeEpochCap(
        CoreStorage.Layout storage core,
        uint256 grossAssets
    ) internal {
        core.epochWithdrawn += grossAssets;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Validate epoch duration is within bounds
    /// @param duration Proposed epoch duration
    /// @return valid True if within [MIN_EPOCH_DURATION, MAX_EPOCH_DURATION]
    function validateEpochDuration(uint64 duration)
        internal
        pure
        returns (bool valid)
    {
        return duration >= MIN_EPOCH_DURATION && duration <= MAX_EPOCH_DURATION;
    }
}
