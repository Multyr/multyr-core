// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CoreStorage } from "../storage/CoreStorage.sol";
import { Events } from "../libraries/Events.sol";
import { Percentage } from "../../libs/Percentage.sol";
import { IBufferManager } from "../../interfaces/IBufferManager.sol";
import { IStrategyRouter, IStrategy } from "../../interfaces/IStrategyRouter.sol";
import { IStrategyScorer } from "../../interfaces/IStrategyScorer.sol";
import { IRouterAllocationPolicy } from "../../interfaces/IRouterAllocationPolicy.sol";
import { IRouterRebalanceGuard } from "../../interfaces/IRouterRebalanceGuard.sol";
import { IExecutionMemory } from "../../interfaces/IExecutionMemory.sol";
import { AllocationTypes } from "../../interfaces/IAllocationTypes.sol";
import { AllocationInvariantLib } from "../libraries/AllocationInvariantLib.sol";
import {
    FixedMaturityStorage,
    _checkOpenEndedDeployAllowed
} from "../storage/FixedMaturityStorage.sol";

/// @dev Minimal interface to read scorer address from StrategyRouter
interface IRouterScorerView {
    function scorer() external view returns (address);
}

/// @title LiquidityOpsModule
/// @notice Handles deploy-to-strategy operations via delegatecall from CoreVault
/// @dev Called via delegatecall — uses EIP-7201 namespaced storage, no own storage.
///      address(this) in delegatecall context = CoreVault address.
///      External calls from this module (e.g. r.executeDepositBatch) see msg.sender = CoreVault.
contract LiquidityOpsModule {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════
    error ReentrancyGuardLocked();
    error NavQueryFailed();
    error AssetQueryFailed();
    error PlanExceedsSurplus(uint256 planTotal, uint256 surplus);

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════
    // P8: MIN_DEPLOY_AMOUNT now read from GlobalConfig via params

    // DeploySkipped reason codes (uint8, gas-efficient — no dynamic strings)
    uint8 internal constant SKIP_NO_BM_OR_ROUTER = 0;
    uint8 internal constant SKIP_HOT_BELOW_RESERVE = 1;
    uint8 internal constant SKIP_ZERO_SURPLUS = 2;
    uint8 internal constant SKIP_EMPTY_PLAN = 3;

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Check if surplus can be deployed to strategies
    /// @dev Accounts for warm headroom: only surplus AFTER reserve + warm goes to strategy
    function canDeploy() external view returns (bool) {
        CoreStorage.Layout storage cs = CoreStorage.layout();
        IBufferManager bm = cs.bufferManager;
        IStrategyRouter r = cs.router;
        if (address(bm) == address(0) || address(r) == address(0)) return false;

        // Get breakdown via staticcall to self (= CoreVault in delegatecall)
        (bool ok, bytes memory data) =
            address(this).staticcall(abi.encodeWithSignature("totalAssetsBreakdown()"));
        if (!ok || data.length < 96) return false;
        (uint256 nav, uint256 hot, uint256 warm) = abi.decode(data, (uint256, uint256, uint256));
        if (nav == 0) return false;

        // Compute surplus after reserve + warm headroom
        IBufferManager.BufferConfig memory cfg = bm.getConfig();
        uint256 reserveHot =
            cfg.opsReserveTargetBps > 0 ? Percentage.mulBpsDown(nav, cfg.opsReserveTargetBps) : 0;
        if (hot <= reserveHot) return false;

        uint256 maxWarm = cfg.maxWarmBps > 0 ? Percentage.mulBpsDown(nav, cfg.maxWarmBps) : 0;
        uint256 warmHeadroom = maxWarm > warm ? (maxWarm - warm) : 0;
        uint256 excessAfterReserve = hot - reserveHot;
        uint256 toWarm = excessAfterReserve > warmHeadroom ? warmHeadroom : excessAfterReserve;
        uint256 toStrategy = excessAfterReserve - toWarm;

        uint256 minDeploy = CoreStorage.layout().params.minDeployAmount(address(this));
        if (toStrategy < minDeploy) return false;

        // Check at least one enabled strategy exists
        IStrategyRouter.StrategyInfo[] memory strats = r.list();
        for (uint256 i = 0; i < strats.length;) {
            if (strats[i].enabled) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // WRITE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Deploy surplus to strategies using on-chain plan (via planDeposit)
    /// @param maxAmount Maximum amount to deploy (cap)
    function deployToStrategies(uint256 maxAmount) external {
        _deployInternal(maxAmount, new IStrategyRouter.Allocation[](0));
    }

    /// @notice Deploy surplus with off-chain pre-computed plan (PR-EO production path)
    /// @param plan Pre-computed allocation plan from off-chain planner
    /// @param maxAmount Maximum amount to deploy (cap)
    function deployToStrategiesWithPlan(
        IStrategyRouter.Allocation[] calldata plan,
        uint256 maxAmount
    ) external {
        _deployInternal(maxAmount, plan);
    }

    /// @notice Realize assets from strategies to cover queue settlement deficit.
    /// @dev Called by VaultUpkeep (REALIZE_FOR_QUEUE op) when hot+warm insufficient
    ///      for pending queue claims. Gas: ~4-5M (1 strategy, 7-8 adapters).
    ///      Must fit in Chainlink 5M since it's the ONLY op in the tx.
    /// @param target USDC amount to pull from strategies
    function realizeForQueue(uint256 target) external {
        CoreStorage.Layout storage cs = CoreStorage.layout();
        IStrategyRouter r = cs.router;
        require(address(r) != address(0), "no router");
        require(target > 0, "zero target");

        // Reentrancy guard
        if (cs.packedFlags & CoreStorage.FLAG_REENTRANCY_LOCKED != 0) {
            revert ReentrancyGuardLocked();
        }
        cs.packedFlags |= CoreStorage.FLAG_REENTRANCY_LOCKED;

        IStrategyRouter.Pull[] memory plan = r.planRedeem(target);
        if (plan.length > 0) {
            (uint256 got,) = r.executeRedeemBatch(plan);
            emit Events.RealizedForQueue(target, got);
        }

        cs.packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
    }

    /// @notice Realize assets to restore the ops reserve target.
    /// @dev Warm refill first, then strategy redeem for any residual gap.
    function realizeForReserveAndOps(uint256 maxAmount) external {
        CoreStorage.Layout storage cs = CoreStorage.layout();
        IBufferManager bm = cs.bufferManager;
        IStrategyRouter r = cs.router;
        require(address(bm) != address(0), "no buffer manager");
        require(address(r) != address(0), "no router");
        require(maxAmount > 0, "zero target");

        if (cs.packedFlags & CoreStorage.FLAG_REENTRANCY_LOCKED != 0) {
            revert ReentrancyGuardLocked();
        }
        cs.packedFlags |= CoreStorage.FLAG_REENTRANCY_LOCKED;

        uint256 pulledWarm = bm.realizeForReserveAndOps(maxAmount);
        uint256 remainingCap = maxAmount > pulledWarm ? maxAmount - pulledWarm : 0;

        if (remainingCap > 0) {
            uint16 targetBps = bm.getConfig().opsReserveTargetBps;
            if (targetBps > 0) {
                (bool assetOk, bytes memory assetData) =
                    address(this).staticcall(abi.encodeWithSignature("asset()"));
                if (!assetOk || assetData.length < 32) revert AssetQueryFailed();
                address assetAddr = abi.decode(assetData, (address));
                uint256 currentCash = IERC20(assetAddr).balanceOf(address(this));
                (bool ok, bytes memory data) =
                    address(this).staticcall(abi.encodeWithSignature("totalAssets()"));
                if (!ok || data.length < 32) revert AssetQueryFailed();
                uint256 tvl = abi.decode(data, (uint256));
                uint256 target = Percentage.mulBpsDown(tvl, targetBps);
                if (currentCash < target) {
                    uint256 gap = target - currentCash;
                    if (gap > remainingCap) gap = remainingCap;
                    if (gap > 0) {
                        IStrategyRouter.Pull[] memory plan = r.planRedeem(gap);
                        if (plan.length > 0) {
                            r.executeRedeemBatch(plan);
                        }
                    }
                }
            }
        }

        cs.packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // STRATEGY REBALANCE — Inter-strategy allocation rebalance
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Check if inter-strategy rebalance is warranted.
    /// @dev V10 flow: Policy.buildRebalancePlan → Guard.evaluatePlan → proceed.
    ///      Falls back to legacy scorer.shouldRebalance if Guard/Policy unset.
    function canRebalanceStrategies() external view returns (bool) {
        CoreStorage.Layout storage cs = CoreStorage.layout();
        IStrategyRouter r = cs.router;
        if (address(r) == address(0)) return false;

        // Build eligible list
        (address[] memory eligibleAddrs, uint256[] memory currentAllocs, uint256 tvl) = _eligibleList(r);
        if (eligibleAddrs.length < 2 || tvl == 0) return false;

        // V10 path: Policy + Guard
        if (cs.rebalancePolicy != address(0) && cs.rebalanceGuard != address(0)) {
            try IRouterAllocationPolicy(cs.rebalancePolicy).buildRebalancePlan(
                eligibleAddrs, currentAllocs, tvl
            ) returns (AllocationTypes.RebalancePlan memory plan) {
                AllocationTypes.QueueSafetyContext memory qs = _buildQueueSafetyContext(tvl);
                uint256 idleUsd = _getIdleUsd();
                try IRouterRebalanceGuard(cs.rebalanceGuard).evaluatePlan(plan, tvl, idleUsd, qs)
                    returns (AllocationTypes.PlanEvaluation memory ev)
                {
                    return ev.proceed;
                } catch { return false; }
            } catch { return false; }
        }

        // Legacy fallback (scorer.shouldRebalance)
        address scorerAddr;
        try IRouterScorerView(address(r)).scorer() returns (address s) {
            scorerAddr = s;
        } catch { return false; }
        if (scorerAddr == address(0)) return false;

        try IStrategyScorer(scorerAddr).shouldRebalance(eligibleAddrs, currentAllocs, tvl) returns (bool needed) {
            return needed;
        } catch { return false; }
    }

    /// @notice Execute inter-strategy rebalance using V10 engine.
    /// @dev Flow: buildPlan → evaluate → scale → Phase A/B → record execution.
    ///      Partial failure converges in subsequent cycles.
    function rebalanceStrategies() external {
        // FixedMaturity gate: open-ended rebalance blocked in FM vaults.
        _checkOpenEndedDeployAllowed(FixedMaturityStorage.layout());

        CoreStorage.Layout storage cs = CoreStorage.layout();
        IStrategyRouter r = cs.router;
        require(address(r) != address(0), "no router");

        // Reentrancy guard
        if (cs.packedFlags & CoreStorage.FLAG_REENTRANCY_LOCKED != 0) {
            revert ReentrancyGuardLocked();
        }
        cs.packedFlags |= CoreStorage.FLAG_REENTRANCY_LOCKED;

        // Build eligible list
        (address[] memory eligible, uint256[] memory currentAllocs, uint256 tvl) = _eligibleList(r);
        if (eligible.length < 2) {
            cs.packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
            return;
        }

        // V10 path: Policy + Guard
        if (cs.rebalancePolicy != address(0) && cs.rebalanceGuard != address(0)) {
            _rebalanceV10(cs, r, eligible, currentAllocs, tvl);
        } else {
            _rebalanceLegacy(cs, r, eligible, currentAllocs, tvl);
        }

        cs.packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // V10 Rebalance — scale-before-execute + ExecutionMemory recording
    // ═══════════════════════════════════════════════════════════════════════════════

    function _rebalanceV10(
        CoreStorage.Layout storage cs,
        IStrategyRouter r,
        address[] memory eligible,
        uint256[] memory currentAllocs,
        uint256 tvl
    ) internal {
        // Build plan via Policy
        AllocationTypes.RebalancePlan memory plan = IRouterAllocationPolicy(cs.rebalancePolicy)
            .buildRebalancePlan(eligible, currentAllocs, tvl);

        emit Events.StrategiesRebalancePlanBuilt(
            plan.totalMoveUsd, plan.driftBps, plan.deltaAPYBps, plan.aggregateConfidence,
            plan.isSafetyPlan, plan.safetyReasonCode
        );

        // Evaluate via Guard
        AllocationTypes.QueueSafetyContext memory qs = _buildQueueSafetyContext(tvl);
        uint256 idleUsd = _getIdleUsd();
        AllocationTypes.PlanEvaluation memory ev = IRouterRebalanceGuard(cs.rebalanceGuard)
            .evaluatePlan(plan, tvl, idleUsd, qs);

        emit Events.RebalanceGuardEvaluated(
            ev.proceed, ev.reasonCode,
            ev.netBenefitBpsBeforeScale, ev.netBenefitBpsAfterScale,
            ev.allowedMoveBps,
            IRouterRebalanceGuard(cs.rebalanceGuard).currentRegime()
        );

        if (!ev.proceed) {
            // Record skip so Guard can track consecutiveSkips.
            try IRouterRebalanceGuard(cs.rebalanceGuard).notifySkip() {} catch {}
            return;
        }

        // Scale to allowedMoveBps
        AllocationTypes.RebalancePlan memory scaled = _applyScaling(plan, ev.allowedMoveBps, tvl, idleUsd);

        // Execute Phase A/B using scaled plan
        (uint256 totalWithdrawn, ) = _executeScaledPlan(r, scaled);

        // Update Guard budget
        uint16 actualMovedBps = tvl > 0 ? uint16((totalWithdrawn * 10_000) / tvl) : 0;
        try IRouterRebalanceGuard(cs.rebalanceGuard).consumeBudget(actualMovedBps) {} catch {}

        // Record execution in ExecutionMemory (strict vs best-effort — Correction #11)
        _recordExecution(cs, scaled, totalWithdrawn);

        emit Events.StrategiesRebalanced(totalWithdrawn, scaled.strategies.length);
    }

    function _rebalanceLegacy(
        CoreStorage.Layout storage cs,
        IStrategyRouter r,
        address[] memory eligible,
        uint256[] memory currentAllocs,
        uint256 tvl
    ) internal {
        address scorerAddr = IRouterScorerView(address(r)).scorer();
        require(scorerAddr != address(0), "no scorer");

        uint256[] memory targets = IStrategyScorer(scorerAddr).computeAllocations(eligible, tvl);
        uint256 ek = eligible.length;

        // Phase A
        uint256 totalWithdrawn = 0;
        {
            uint256 pullCount = 0;
            for (uint256 i = 0; i < ek;) {
                if (currentAllocs[i] > targets[i]) pullCount++;
                unchecked { ++i; }
            }

            if (pullCount > 0) {
                IStrategyRouter.Pull[] memory pulls = new IStrategyRouter.Pull[](pullCount);
                uint256 pk = 0;
                for (uint256 i = 0; i < ek;) {
                    if (currentAllocs[i] > targets[i]) {
                        pulls[pk++] = IStrategyRouter.Pull(eligible[i], currentAllocs[i] - targets[i]);
                    }
                    unchecked { ++i; }
                }
                (uint256 got,) = r.executeRedeemBatch(pulls);
                totalWithdrawn = got;
            }
        }

        // Phase B
        if (totalWithdrawn > 0) {
            uint256 depositCount = 0;
            for (uint256 i = 0; i < ek;) {
                if (targets[i] > currentAllocs[i]) depositCount++;
                unchecked { ++i; }
            }

            if (depositCount > 0) {
                IStrategyRouter.Allocation[] memory deposits = new IStrategyRouter.Allocation[](depositCount);
                uint256 dk = 0;
                uint256 remaining = totalWithdrawn;
                for (uint256 i = 0; i < ek && remaining > 0;) {
                    if (targets[i] > currentAllocs[i]) {
                        uint256 need = targets[i] - currentAllocs[i];
                        uint256 give = need > remaining ? remaining : need;
                        (bool ok, bytes memory assetData) =
                            address(this).staticcall(abi.encodeWithSignature("asset()"));
                        if (ok && assetData.length == 32) {
                            address assetAddr = abi.decode(assetData, (address));
                            IERC20(assetAddr).safeTransfer(eligible[i], give);
                            deposits[dk++] = IStrategyRouter.Allocation(eligible[i], give, true);
                            remaining -= give;
                        }
                    }
                    unchecked { ++i; }
                }
                assembly { mstore(deposits, dk) }
                if (dk > 0) {
                    r.executeDepositBatch(deposits);
                }
            }
        }

        emit Events.StrategiesRebalanced(totalWithdrawn, ek);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // V10 REBALANCE — Internal helpers
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Build (eligible, currentAllocs, tvl) from router.list().
    function _eligibleList(IStrategyRouter r)
        internal view returns (address[] memory eligible, uint256[] memory currentAllocs, uint256 tvl)
    {
        IStrategyRouter.StrategyInfo[] memory strats = r.list();
        eligible = new address[](strats.length);
        currentAllocs = new uint256[](strats.length);
        uint256 ek = 0;
        for (uint256 i = 0; i < strats.length;) {
            if (strats[i].enabled) {
                try IStrategy(strats[i].strat).totalAssets() returns (uint256 ta) {
                    eligible[ek] = strats[i].strat;
                    currentAllocs[ek] = ta;
                    tvl += ta;
                    ek++;
                } catch {}
            }
            unchecked { ++i; }
        }
        assembly { mstore(eligible, ek) }
        assembly { mstore(currentAllocs, ek) }
    }

    /// @dev Build QueueSafetyContext from current vault state.
    ///      queueReservedUsd / queuePressureBps derived via staticcalls on self (delegatecall context = vault).
    function _buildQueueSafetyContext(uint256 tvl)
        internal view returns (AllocationTypes.QueueSafetyContext memory qs)
    {
        // Read pendingShares → queueReservedUsd approximation
        (bool ok, bytes memory data) = address(this).staticcall(abi.encodeWithSignature("pendingShares()"));
        if (ok && data.length == 32) {
            uint256 pending = abi.decode(data, (uint256));
            // Approx: pendingShares * pps ≈ reserved USD. We use a crude lower bound.
            qs.queueReservedUsd = pending; // caller may refine; this is fail-safe upper estimate in shares
            if (tvl > 0) {
                uint256 pressure = (pending * 10_000) / (tvl + 1);
                qs.queuePressureBps = pressure > type(uint16).max ? type(uint16).max : uint16(pressure);
            }
        }
        // availableIdleAfterPlanBps estimated as idleUsd/tvl (plan-agnostic lower bound).
        uint256 idle = _getIdleUsd();
        qs.availableIdleAfterPlanBps = tvl > 0 ? uint16((idle * 10_000) / tvl > type(uint16).max ? type(uint16).max : (idle * 10_000) / tvl) : 0;
    }

    /// @dev Read idle USD available in the CoreVault (for Guard scaling + queue safety).
    function _getIdleUsd() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(this).staticcall(abi.encodeWithSignature("asset()"));
        if (!ok || data.length != 32) return 0;
        address assetAddr = abi.decode(data, (address));
        return IERC20(assetAddr).balanceOf(address(this));
    }

    /// @dev Scale plan by `allowedMoveBps` via AllocationInvariantLib.scalePlan (Fix #3).
    function _applyScaling(
        AllocationTypes.RebalancePlan memory plan,
        uint16 allowedMoveBps,
        uint256 tvl,
        uint256 idleUsd
    ) internal pure returns (AllocationTypes.RebalancePlan memory scaled) {
        // If already within budget, keep as-is
        if (plan.driftBps <= allowedMoveBps) return plan;
        uint256 scaleBps = (uint256(allowedMoveBps) * 10_000) / plan.driftBps;
        if (scaleBps > 10_000) scaleBps = 10_000;
        // Use library to scale deterministically
        return _LIB_scalePlan(plan, scaleBps, idleUsd);
        // silence unused tvl
    }

    /// @dev Wrapper around AllocationInvariantLib.scalePlan (Fix #3).
    function _LIB_scalePlan(
        AllocationTypes.RebalancePlan memory plan,
        uint256 scaleBps,
        uint256 idleUsd
    ) internal pure returns (AllocationTypes.RebalancePlan memory) {
        return AllocationInvariantLib.scalePlan(plan, scaleBps, idleUsd);
    }

    /// @dev Execute the scaled plan via router.executeRedeemBatch + executeDepositBatch.
    function _executeScaledPlan(IStrategyRouter r, AllocationTypes.RebalancePlan memory scaled)
        internal returns (uint256 totalWithdrawn, uint256 totalDeposited)
    {
        uint256 n = scaled.strategies.length;

        // Phase A: withdraws
        {
            uint256 pullCount = 0;
            for (uint256 i = 0; i < n; i++) {
                if (scaled.withdrawAmounts[i] > 0) pullCount++;
            }
            if (pullCount > 0) {
                IStrategyRouter.Pull[] memory pulls = new IStrategyRouter.Pull[](pullCount);
                uint256 pk = 0;
                for (uint256 i = 0; i < n; i++) {
                    if (scaled.withdrawAmounts[i] > 0) {
                        pulls[pk++] = IStrategyRouter.Pull(scaled.strategies[i], scaled.withdrawAmounts[i]);
                    }
                }
                (uint256 got,) = r.executeRedeemBatch(pulls);
                totalWithdrawn = got;
            }
        }

        // Phase B: deposits
        if (totalWithdrawn > 0) {
            uint256 depCount = 0;
            for (uint256 i = 0; i < n; i++) {
                if (scaled.depositAmounts[i] > 0) depCount++;
            }
            if (depCount > 0) {
                IStrategyRouter.Allocation[] memory deposits = new IStrategyRouter.Allocation[](depCount);
                uint256 dk = 0;
                uint256 remaining = totalWithdrawn;
                (bool ok, bytes memory assetData) = address(this).staticcall(abi.encodeWithSignature("asset()"));
                if (!ok || assetData.length != 32) return (totalWithdrawn, 0);
                address assetAddr = abi.decode(assetData, (address));
                for (uint256 i = 0; i < n && remaining > 0; i++) {
                    uint256 want = scaled.depositAmounts[i];
                    if (want == 0) continue;
                    uint256 give = want > remaining ? remaining : want;
                    IERC20(assetAddr).safeTransfer(scaled.strategies[i], give);
                    deposits[dk++] = IStrategyRouter.Allocation(scaled.strategies[i], give, true);
                    remaining -= give;
                }
                assembly { mstore(deposits, dk) }
                if (dk > 0) {
                    r.executeDepositBatch(deposits);
                    totalDeposited = totalWithdrawn - remaining;
                }
            }
        }
    }

    /// @dev Record execution results in ExecutionMemory.
    ///      strictExecutionMemory == true: revert on failure.
    ///      false: emit ExecutionMemoryRecordFailed, continue.
    function _recordExecution(
        CoreStorage.Layout storage cs,
        AllocationTypes.RebalancePlan memory scaled,
        uint256 totalWithdrawn
    ) internal {
        if (cs.executionMemory == address(0)) return;

        for (uint256 i = 0; i < scaled.strategies.length; i++) {
            if (scaled.withdrawAmounts[i] == 0 && scaled.depositAmounts[i] == 0) continue;
            uint256 moveUsd = scaled.withdrawAmounts[i] + scaled.depositAmounts[i];
            // Slippage approximation: (planned - actual) / planned
            uint16 slipBps = 0;
            if (moveUsd > 0 && totalWithdrawn < scaled.totalMoveUsd) {
                uint256 slip = ((scaled.totalMoveUsd - totalWithdrawn) * 10_000) / scaled.totalMoveUsd;
                slipBps = slip > type(uint16).max ? type(uint16).max : uint16(slip);
            }
            // Gas usage best-effort: approximate with a fixed scalar (keeper records exact later off-chain).
            uint256 gasUsed = 100_000; // stub; real gas tracked by keeper post-tx
            int256 realizedVsExpected = 0; // placeholder; keeper updates with realized APY delta later
            try IExecutionMemory(cs.executionMemory).recordExecution(
                scaled.strategies[i], gasUsed, slipBps, realizedVsExpected, totalWithdrawn > 0
            ) {} catch {
                if (cs.strictExecutionMemory) {
                    revert("EM:record_failed");
                }
                emit Events.ExecutionMemoryRecordFailed(scaled.strategies[i]);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════════

    function _deployInternal(uint256 maxAmount, IStrategyRouter.Allocation[] memory externalPlan)
        internal
    {
        // FixedMaturity gate: open-ended deploy/rebalance blocked in FM vaults.
        _checkOpenEndedDeployAllowed(FixedMaturityStorage.layout());

        CoreStorage.Layout storage cs = CoreStorage.layout();
        IBufferManager bm = cs.bufferManager;
        IStrategyRouter r = cs.router;

        // GUARD: both bm and r required — same invariant as canDeploy()
        if (address(bm) == address(0) || address(r) == address(0)) {
            emit Events.DeploySkipped(SKIP_NO_BM_OR_ROUTER);
            return;
        }

        // Reentrancy guard (same flag as CoreVault.nonReentrant modifier)
        if (cs.packedFlags & CoreStorage.FLAG_REENTRANCY_LOCKED != 0) {
            revert ReentrancyGuardLocked();
        }
        cs.packedFlags |= CoreStorage.FLAG_REENTRANCY_LOCKED;

        // Get NAV breakdown via staticcall to self (= CoreVault in delegatecall)
        (bool ok, bytes memory data) =
            address(this).staticcall(abi.encodeWithSignature("totalAssetsBreakdown()"));
        if (!ok || data.length < 96) {
            cs.packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
            revert NavQueryFailed();
        }
        (uint256 nav, uint256 hot, uint256 warm) = abi.decode(data, (uint256, uint256, uint256));

        // Get asset address via staticcall (robust ABI check)
        bytes memory assetData;
        (ok, assetData) = address(this).staticcall(abi.encodeWithSignature("asset()"));
        if (!ok || assetData.length < 32) {
            cs.packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
            revert AssetQueryFailed();
        }
        address assetAddr = abi.decode(assetData, (address));

        // Compute deployable surplus (same formula as canDeploy)
        IBufferManager.BufferConfig memory cfg = bm.getConfig();
        uint256 reserveHot =
            cfg.opsReserveTargetBps > 0 ? Percentage.mulBpsDown(nav, cfg.opsReserveTargetBps) : 0;

        if (hot <= reserveHot) {
            cs.packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
            emit Events.DeploySkipped(SKIP_HOT_BELOW_RESERVE);
            return;
        }

        uint256 maxWarm = cfg.maxWarmBps > 0 ? Percentage.mulBpsDown(nav, cfg.maxWarmBps) : 0;
        uint256 warmHeadroom = maxWarm > warm ? (maxWarm - warm) : 0;
        uint256 excessAfterReserve = hot - reserveHot;
        uint256 toWarm = excessAfterReserve > warmHeadroom ? warmHeadroom : excessAfterReserve;
        uint256 surplus = excessAfterReserve - toWarm;
        if (surplus > maxAmount) surplus = maxAmount;

        if (surplus == 0) {
            cs.packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
            emit Events.DeploySkipped(SKIP_ZERO_SURPLUS);
            return;
        }

        // Plan: use external plan if provided, otherwise plan on-chain
        IStrategyRouter.Allocation[] memory plan;
        if (externalPlan.length > 0) {
            plan = externalPlan;
            uint256 planTotal;
            for (uint256 i = 0; i < plan.length;) {
                planTotal += plan[i].amount;
                unchecked {
                    ++i;
                }
            }
            if (planTotal > surplus) {
                cs.packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
                revert PlanExceedsSurplus(planTotal, surplus);
            }
        } else {
            plan = r.planDeposit(surplus);
        }

        if (plan.length == 0) {
            cs.packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
            emit Events.DeploySkipped(SKIP_EMPTY_PLAN);
            return;
        }

        emit Events.DeployPlanned(surplus, plan.length);

        // Transfer funds + mark as already transferred (B1 audit fix)
        // Pattern: safeTransfer FIRST, then executeDepositBatch with fundsAlreadyTransferred=true
        // This prevents double-counting in strategy.totalAssets()
        IERC20 asset_ = IERC20(assetAddr);
        uint256 transferred = 0;
        uint256 legsOk = 0;
        for (uint256 i = 0; i < plan.length;) {
            if (plan[i].amount > 0) {
                asset_.safeTransfer(plan[i].strat, plan[i].amount);
                plan[i].fundsAlreadyTransferred = true;
                transferred += plan[i].amount;
                legsOk++;
                emit Events.RoutedToStrategy(
                    plan[i].strat, plan[i].amount, asset_.balanceOf(address(this))
                );
            }
            unchecked {
                ++i;
            }
        }

        // Funds now sit as idleCash on the strategy.
        // StrategyUpkeep.deployIdle() will distribute to individual adapters.
        // This separation keeps VaultUpkeep gas < 1.5M and avoids 6-adapter iteration.
        emit Events.DeployExecuted(transferred, legsOk, plan.length);

        cs.packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
    }
}
