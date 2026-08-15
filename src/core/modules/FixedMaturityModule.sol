// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { FixedMaturityStorage, VaultMode, VaultState } from "../storage/FixedMaturityStorage.sol";
import { CoreStorage } from "../storage/CoreStorage.sol";
import { FeeStorage } from "../storage/FeeStorage.sol";
import { FixedMaturityLogicLib } from "../libraries/FixedMaturityLogicLib.sol";
import { Events } from "../libraries/Events.sol";
import { IBufferManager } from "../../interfaces/IBufferManager.sol";
import { IStrategyRouter } from "../../interfaces/IStrategyRouter.sol";
import { ICoreVault } from "../../interfaces/ICoreVault.sol";
import { FixedPoint } from "../../libs/FixedPoint.sol";
import { EpochQueueStorage } from "./EpochedQueueModule.sol";

// Errors from FixedMaturityStorage.sol (imported via transitive import):
// DepositsClosedForVaultState, StandardExitNotAvailablePreMaturity,
// SettlementBlockedPreMaturity, ForceExitNotAvailableInState, OpenEndedOnlyPath

// Errors from Errors.sol:
import {
    InvalidVaultMode,
    InvalidVaultState,
    AlreadyConfigured,
    FixedMaturityNotConfigured,
    FixedMaturityAlreadyStarted,
    MaturityNotReached,
    FundingBelowMinimumThreshold,
    FundingAlreadyFailed,
    NotFundingFailed,
    ZeroCommittedAssets,
    FinalPerformanceFeeAlreadyApplied,
    CloseNotAllowedWithPendingShares,
    ZeroAmount
} from "../libraries/Errors.sol";

/// @title FixedMaturityModule — All FixedMaturity lifecycle logic
/// @notice Handles: governance lifecycle, permissionless time-gated transitions,
///         refund (FundingFailed), final performance fee, recall, views.
///         OpenEnded vaults see none of this code — gating helpers short-circuit first.
/// @dev Deployed as an external module, called via delegatecall from CoreVault.
///      All storage writes go through FixedMaturityStorage.layout() (EIP-7201).
contract FixedMaturityModule {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────────
    // GOVERNANCE — ROLE_OWNER
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Irreversibly switch vault to FixedMaturity mode.
    ///         Must be called before system seal (FLAG_ROUTING_FROZEN).
    function setVaultModeFixedMaturity() external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (fm.vaultMode != VaultMode.OpenEnded) revert InvalidVaultMode();
        if (core.packedFlags & CoreStorage.FLAG_ROUTING_FROZEN != 0) revert InvalidVaultMode();
        // The FixedMaturity lifecycle moves capital out of the vault in states
        // where the epoch queue is gated off (activateFixedMaturityCycle in
        // Starting, refundClaim in FundingFailed), so neither consults
        // reservedForClaims. That is only sound while no epoch claim can be
        // outstanding across the switch -- claimEpochAssets has no FixedMaturity
        // gate and would otherwise race the cycle deployment for the same cash.
        if (EpochQueueStorage.layout().outstandingClaimCount != 0) {
            revert CloseNotAllowedWithPendingShares();
        }
        fm.vaultMode = VaultMode.FixedMaturity;
        fm.vaultState = VaultState.Funding;
        emit Events.VaultModeConfigured(1);
    }

    /// @notice One-shot configuration of FixedMaturity parameters.
    ///         Cannot be called twice (fixedTermConfigured guard).
    function configureFixedMaturity(
        uint64  maturityTs_,
        uint256 minFundingAssets_,
        uint256 targetFundingAssets_,
        uint64  fundingDeadlineTs_,
        bool    autoCloseFundingOnTarget_,
        bool    instantEnabledAfterMaturity_,
        uint256 preMaturityForceExitPenaltyBps_,
        address fixedTermStrategy_
    ) external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.vaultMode != VaultMode.FixedMaturity) revert InvalidVaultMode();
        if (fm.vaultState != VaultState.Funding) revert InvalidVaultState();
        if (fm.fixedTermConfigured) revert AlreadyConfigured();
        if (maturityTs_ <= block.timestamp) revert InvalidVaultState();
        if (fundingDeadlineTs_ <= block.timestamp) revert InvalidVaultState();
        if (fundingDeadlineTs_ >= maturityTs_) revert InvalidVaultState();
        if (minFundingAssets_ == 0) revert ZeroAmount();
        if (targetFundingAssets_ < minFundingAssets_) revert InvalidVaultState();
        if (targetFundingAssets_ > 1_000_000_000e6) revert InvalidVaultState(); // overflow guard
        if (preMaturityForceExitPenaltyBps_ > 5_000) revert InvalidVaultState(); // max 50%
        if (fixedTermStrategy_ == address(0)) revert InvalidVaultState();

        fm.maturityTs                    = maturityTs_;
        fm.minFundingAssets              = minFundingAssets_;
        fm.targetFundingAssets           = targetFundingAssets_;
        fm.fundingDeadlineTs             = fundingDeadlineTs_;
        fm.autoCloseFundingOnTarget      = autoCloseFundingOnTarget_;
        fm.instantEnabledAfterMaturity   = instantEnabledAfterMaturity_;
        fm.preMaturityForceExitPenaltyBps = preMaturityForceExitPenaltyBps_;
        fm.fixedTermStrategy             = fixedTermStrategy_;
        fm.fixedTermConfigured           = true;

        emit Events.FixedMaturityConfigured(
            maturityTs_, minFundingAssets_, targetFundingAssets_, fundingDeadlineTs_,
            autoCloseFundingOnTarget_, instantEnabledAfterMaturity_, preMaturityForceExitPenaltyBps_
        );
    }

    /// @notice Manual trigger: Funding → Starting (net >= min required).
    function startFixedMaturityCycle() external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.vaultMode != VaultMode.FixedMaturity) revert InvalidVaultMode();
        if (fm.vaultState == VaultState.FundingFailed) revert FundingAlreadyFailed();
        _transitionFundingToStarting(false);
    }

    /// @notice Auto-close entry point — called by ERC4626Module deposit hook when target reached.
    ///         Best-effort: if already Starting (race), no-op.
    function autoCloseFunding() external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.vaultMode != VaultMode.FixedMaturity) return;
        if (fm.vaultState != VaultState.Funding) return;
        if (!fm.fixedTermConfigured) return;
        if (!fm.autoCloseFundingOnTarget) return;
        if (fm.startingTs != 0) return;
        if (!FixedMaturityLogicLib.isFundingTargetReached(fm, _totalAssets())) return;
        _transitionFundingToStarting(true);
    }

    /// @notice Starting → Active: deploys fixedTermCommittedAssets to fixedTermStrategy via StrategyRouter.
    function activateFixedMaturityCycle() external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.vaultState != VaultState.Starting) revert InvalidVaultState();
        if (fm.fixedTermCommittedAssets == 0) revert ZeroCommittedAssets();
        if (block.timestamp >= fm.maturityTs) revert InvalidVaultState();

        fm.startTs = uint64(block.timestamp);
        fm.vaultState = VaultState.Active;

        // Deploy via StrategyRouter — identical to LiquidityOpsModule._deployInternal pattern.
        // Pre-transfer funds to strategy, then executeDepositBatch with fundsAlreadyTransferred=true.
        CoreStorage.Layout storage core = CoreStorage.layout();
        address asset_ = _asset();
        uint256 amount = fm.fixedTermCommittedAssets;

        IERC20(asset_).safeTransfer(fm.fixedTermStrategy, amount);

        IStrategyRouter.Allocation[] memory plan = new IStrategyRouter.Allocation[](1);
        plan[0] = IStrategyRouter.Allocation({
            strat: fm.fixedTermStrategy,
            amount: amount,
            fundsAlreadyTransferred: true
        });
        core.router.executeDepositBatch(plan);

        emit Events.FixedMaturityCycleActivated(fm.startTs, fm.maturityTs, amount);
    }

    /// @notice Matured → Closed (requires outstandingClaimCount == 0, dust assets allowed).
    function closeFixedMaturityCycle() external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.vaultState != VaultState.Matured) revert InvalidVaultState();

        // outstandingClaimCount == 0 is the only hard requirement (no claim left
        // unclaimed across any epoch — open, closed-unfunded, or funded-unclaimed).
        // Dust assets are allowed.
        (bool ok, bytes memory data) = address(this).staticcall(
            abi.encodeWithSignature("outstandingClaimCount()")
        );
        if (!ok || abi.decode(data, (uint256)) != 0) revert CloseNotAllowedWithPendingShares();

        fm.vaultState = VaultState.Closed;
        emit Events.FixedMaturityClosed();
    }

    // ──────────────────────────────────────────────────────────────────────────
    // PERMISSIONLESS TIME/CONDITION-GATED — ROLE_PUBLIC
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Active → Matured. Takes immutable totalAssets snapshot, applies final perf fee.
    ///         Reverts if already Matured or Closed (idempotent guard).
    function markMatured() external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.vaultState != VaultState.Active) revert InvalidVaultState();
        if (block.timestamp < fm.maturityTs) revert MaturityNotReached();

        // FIRST: immutable snapshot before any state change or fee calculation.
        fm.finalPerformanceFeeBaseAssets = _totalAssets();

        fm.vaultState = VaultState.Matured;

        // Apply final performance fee using the immutable snapshot.
        if (!fm.finalPerformanceFeeApplied) {
            _applyFinalPerformanceFee();
        }

        emit Events.FixedMaturityMatured(fm.maturityTs);
    }

    /// @notice Mark funding as failed. Callable when deadline passed and net < min.
    ///         Reverts if vaultState != Funding (only callable in Funding state).
    function markFundingFailed() external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.vaultState != VaultState.Funding) revert InvalidVaultState();
        if (block.timestamp < fm.fundingDeadlineTs) revert InvalidVaultState();
        uint256 net = _totalAssets(); // == netFundedAssets() in Funding (no deployed assets)
        if (net >= fm.minFundingAssets) revert FundingBelowMinimumThreshold();

        // Snapshot PPS for deterministic refund — never updated after this.
        fm.fundingFailedPPS = _convertToAssets(1e18);
        fm.vaultState = VaultState.FundingFailed;

        emit Events.FundingFailed(net, fm.minFundingAssets, fm.fundingDeadlineTs);
    }

    /// @notice Recall capital from fixedTermStrategy via StrategyRouter.
    ///         Idempotent: returns immediately if nothing to recall.
    ///         Valid only in Matured state. Can be called by owner or automation upkeep.
    function recallFixedTermCapital() external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.vaultState != VaultState.Matured) revert InvalidVaultState();

        CoreStorage.Layout storage core = CoreStorage.layout();

        // Idempotent: if nothing withdrawable, return silently.
        (bool hasAssets, uint256 withdrawable) = _strategyWithdrawable(fm.fixedTermStrategy);
        if (!hasAssets || withdrawable == 0) return;

        IStrategyRouter.Pull[] memory plan = new IStrategyRouter.Pull[](1);
        plan[0] = IStrategyRouter.Pull({
            strat: fm.fixedTermStrategy,
            amount: withdrawable
        });
        core.router.executeRedeemBatch(plan);
    }

    /// @notice FundingFailed refund — hard separated from ExitFeeLib, zero fees.
    ///         Uses fundingFailedPPS snapshot (never live PPS).
    function refundClaim(uint256 shares) external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.vaultState != VaultState.FundingFailed) revert NotFundingFailed();
        if (shares == 0) revert ZeroAmount();

        uint256 balance = _balanceOf(msg.sender);
        if (balance < shares) revert ZeroAmount(); // reuse ZeroAmount for insufficient balance

        // Use snapshot PPS — deterministic, no drift.
        uint256 gross = (shares * fm.fundingFailedPPS) / 1e18;

        // Burn shares, then transfer. CEI pattern.
        _burn(msg.sender, shares);
        IERC20(_asset()).safeTransfer(msg.sender, gross);

        emit Events.FixedMaturityRefundClaimed(msg.sender, shares, gross);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // VIEW FUNCTIONS — ROLE_PUBLIC
    // ──────────────────────────────────────────────────────────────────────────

    function isDepositOpen() external view returns (bool) {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.vaultMode == VaultMode.OpenEnded) return true;
        return fm.vaultState == VaultState.Funding;
    }

    function isSettlementOpen() external view returns (bool) {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.vaultMode == VaultMode.OpenEnded) return true;
        return fm.vaultState == VaultState.Matured;
    }

    function isInstantExitOpen() external view returns (bool) {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.vaultMode == VaultMode.OpenEnded) return true;
        if (fm.vaultState != VaultState.Matured) return false;
        return fm.instantEnabledAfterMaturity;
    }

    function currentVaultModeAndState() external view returns (VaultMode, VaultState) {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        return (fm.vaultMode, fm.vaultState);
    }

    /// @notice Net funded assets in Funding phase (== totalAssets, deploy is blocked by invariant).
    function netFundedAssets() external view returns (uint256) {
        return _totalAssets();
    }

    function isFundingSuccessful() external view returns (bool) {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        return FixedMaturityLogicLib.isFundingSuccessful(fm, _totalAssets());
    }

    function isFundingTargetReached() external view returns (bool) {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        return FixedMaturityLogicLib.isFundingTargetReached(fm, _totalAssets());
    }

    function fundingProgressBps() external view returns (uint256) {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        return FixedMaturityLogicLib.fundingProgressBps(fm, _totalAssets());
    }

    function finalPerformanceFeeStatus() external view returns (bool applied, uint256 assets) {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        return (fm.finalPerformanceFeeApplied, fm.finalPerformanceFeeAssets);
    }

    function fundingDeadlineTs() external view returns (uint64) {
        return FixedMaturityStorage.layout().fundingDeadlineTs;
    }

    function maturityTs() external view returns (uint64) {
        return FixedMaturityStorage.layout().maturityTs;
    }

    function minFundingAssets() external view returns (uint256) {
        return FixedMaturityStorage.layout().minFundingAssets;
    }

    function fixedTermStrategy() external view returns (address) {
        return FixedMaturityStorage.layout().fixedTermStrategy;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // INTERNAL
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Single implementation for both auto-close (from deposit hook) and manual start.
    ///      Called from ERC4626Module._depositInternal inline code and from startFixedMaturityCycle().
    function _transitionFundingToStarting(bool autoClosed) internal {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.vaultState != VaultState.Funding) revert InvalidVaultState();
        if (!fm.fixedTermConfigured) revert FixedMaturityNotConfigured();
        if (fm.startingTs != 0) revert FixedMaturityAlreadyStarted();

        uint256 net = _totalAssets(); // == netFundedAssets() in Funding
        if (!FixedMaturityLogicLib.isFundingSuccessful(fm, net)) revert FundingBelowMinimumThreshold();

        // Retain the stricter of the FM hot floor and router ops reserve floor.
        // This keeps the Funding -> Starting commitment consistent with the
        // surplus check enforced later by StrategyRouter.executeDepositBatch().
        CoreStorage.Layout storage core = CoreStorage.layout();
        IBufferManager.BufferConfig memory cfg = core.bufferManager.getConfig();
        uint16 retainedHotBps = cfg.minHotBps >= cfg.opsReserveTargetBps
            ? cfg.minHotBps
            : cfg.opsReserveTargetBps;

        fm.retainedHotBuffer = FixedMaturityLogicLib.computeRetainedHotBuffer(net, retainedHotBps);
        if (net <= fm.retainedHotBuffer) revert ZeroCommittedAssets();
        fm.fixedTermCommittedAssets = net - fm.retainedHotBuffer;
        fm.fixedTermPrincipalBaseAssets = net;
        fm.startingTs = uint64(block.timestamp);
        fm.vaultState = VaultState.Starting;

        if (autoClosed) emit Events.FundingAutoClosedAtTarget(net, fm.targetFundingAssets);
        emit Events.FixedMaturityCycleStarted(fm.startingTs, fm.fixedTermCommittedAssets, fm.retainedHotBuffer);
    }

    /// @dev Apply final performance fee using the immutable snapshot in finalPerformanceFeeBaseAssets.
    ///      CEI pattern: set applied=true BEFORE any external calls.
    ///
    ///      This mints fee shares the same way EpochedQueueModule._crystallize() does (preview
    ///      deposit, mint to feeCollector), but it is NOT a duplicate of that function and
    ///      does not need its HWM-monotonicity or min-crystallize-interval fixes:
    ///      - No persistent high-water mark: profit is `finalPerformanceFeeBaseAssets -
    ///        fixedTermPrincipalBaseAssets`, a one-shot delta between two immutable
    ///        snapshots taken at fixed points in the FM lifecycle, not a running peak that
    ///        could be lowered on a drawdown.
    ///      - No repeat-extraction surface: `finalPerformanceFeeApplied` latches after the
    ///        first (and only) call, so there is nothing for a min-interval guard to
    ///        rate-limit.
    function _applyFinalPerformanceFee() internal {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        if (fm.finalPerformanceFeeApplied) revert FinalPerformanceFeeAlreadyApplied();

        uint256 profit = FixedMaturityLogicLib.computeGrossProfit(
            fm.finalPerformanceFeeBaseAssets,
            fm.fixedTermPrincipalBaseAssets
        );

        fm.finalPerformanceFeeApplied = true; // CEI: set before external calls

        if (profit == 0) return;

        FeeStorage.Layout storage f = FeeStorage.layout();
        uint256 feeAssets = FixedPoint.mulWadDown(profit, f.perfRateX);
        if (feeAssets == 0) return;

        // Mint fee shares to feeCollector — same pattern as _crystallize() in EpochedQueueModule.
        uint256 feeShares = _previewDeposit(feeAssets);
        if (feeShares == 0) return;

        CoreStorage.Layout storage core = CoreStorage.layout();
        _mint(core.feeCollector, feeShares);
        fm.finalPerformanceFeeAssets = feeAssets;

        emit Events.FixedMaturityFinalPerformanceFeeApplied(profit, feeAssets);
    }

    /// @dev Query strategy's withdrawable amount safely (view call, no revert on failure).
    function _strategyWithdrawable(address strat) internal view returns (bool ok, uint256 amount) {
        bytes memory data;
        (ok, data) = strat.staticcall(abi.encodeWithSignature("withdrawableAtMaturity()"));
        if (ok && data.length == 32) {
            amount = abi.decode(data, (uint256));
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // DELEGATECALL HELPERS (copied pattern from QueueModule)
    // ──────────────────────────────────────────────────────────────────────────

    // NOTE: direct interface calls, not low-level staticcall/call +
    // abi.encodeWithSignature. Same external-call semantics (delegatecall
    // context means address(this) is still the vault), but the compiler
    // resolves the selector at compile time and skips the manual bytes-memory
    // encode/decode + require(success, "...") boilerplate on every call site.
    function _totalAssets() internal view returns (uint256) {
        return IERC4626(address(this)).totalAssets();
    }

    function _totalSupply() internal view returns (uint256) {
        return IERC20(address(this)).totalSupply();
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        return IERC4626(address(this)).convertToAssets(shares);
    }

    function _previewDeposit(uint256 assets) internal view returns (uint256) {
        return IERC4626(address(this)).convertToShares(assets);
    }

    function _balanceOf(address account) internal view returns (uint256) {
        return IERC20(address(this)).balanceOf(account);
    }

    function _asset() internal view returns (address) {
        return IERC4626(address(this)).asset();
    }

    function _mint(address to, uint256 amount) internal {
        ICoreVault(address(this)).processorMint(to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        ICoreVault(address(this)).processorBurn(from, amount);
    }
}
