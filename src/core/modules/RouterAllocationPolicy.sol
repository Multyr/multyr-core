// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IRouterAllocationPolicy } from "../../interfaces/IRouterAllocationPolicy.sol";
import { IStrategyScorerV10 } from "../../interfaces/IStrategyScorerV10.sol";
import { IStrategyScorer } from "../../interfaces/IStrategyScorer.sol";
import { IStrategyHealthRegistry } from "../../interfaces/IStrategyHealthRegistry.sol";
import { IStrategyCoordination } from "../../interfaces/IStrategyCoordination.sol";
import { AllocationTypes } from "../../interfaces/IAllocationTypes.sol";
import { AllocationInvariantLib } from "../libraries/AllocationInvariantLib.sol";

/// @title RouterAllocationPolicy — target computation + RebalancePlan builder
/// @notice Produces deterministic RebalancePlans with realized-cost inputs.
///         Classifies safety conditions via AllocationInvariantLib.isSafetyCondition (Fix #1).
/// @dev Standalone view contract (no delegatecall). Reads from StrategyScorer (V10) and health registry.
contract RouterAllocationPolicy is IRouterAllocationPolicy {

    uint256 private constant BPS = 10_000;

    // ─────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────

    address public owner;
    IStrategyScorerV10 public scorer;
    IStrategyHealthRegistry public healthRegistry;
    address public guard; // for currentRegime() read

    // Regime-aware bucket limits (static class assignment — Correction #7)
    uint16[3] public coreBucketMinBpsByRegime;
    uint16[3] public coreBucketMaxBpsByRegime;

    // Safety thresholds (Fix #1 — no APY dependency)
    uint16 public healthThresholdBps           = 7000;
    uint16 public liquidityReadinessThresholdBps = 3000;
    uint16 public maxStrategyExposureBps       = 4000;
    uint16 public queuePressureThresholdBps    = 3000;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event ScorerSet(address indexed scorer);
    event HealthRegistrySet(address indexed registry);
    event GuardSet(address indexed guard);
    event BucketLimitsSet(uint8 regime, uint16 coreMinBps, uint16 coreMaxBps);
    event SafetyThresholdsSet(uint16 healthBps, uint16 liqReadyBps, uint16 maxExposureBps, uint16 queuePressureBps);

    // ─────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────

    error NotOwner();
    error ZeroAddress();
    error InvalidRegime();

    // ─────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(address owner_, address scorer_, address healthRegistry_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        if (scorer_ != address(0)) scorer = IStrategyScorerV10(scorer_);
        if (healthRegistry_ != address(0)) healthRegistry = IStrategyHealthRegistry(healthRegistry_);

        // Default bucket limits per regime.
        coreBucketMinBpsByRegime = [uint16(8000), uint16(7500), uint16(9000)];
        coreBucketMaxBpsByRegime = [uint16(9000), uint16(8500), uint16(9500)];
    }

    // ─────────────────────────────────────────────────────────────────────
    // IRouterAllocationPolicy
    // ─────────────────────────────────────────────────────────────────────

    /// @inheritdoc IRouterAllocationPolicy
    function buildRebalancePlan(
        address[] calldata strategies,
        uint256[] calldata currentAllocs,
        uint256 tvl
    ) external view override returns (AllocationTypes.RebalancePlan memory plan) {
        uint256 n = strategies.length;
        require(n == currentAllocs.length, "Policy:len");

        // 1. Deterministic ordering: sort strategies ascending by address (Correction #10)
        (address[] memory sortedStrats, uint256[] memory sortedAllocs) =
            _sortAscending(strategies, currentAllocs);

        // 2. Compute targets via scorer
        uint256[] memory targets = _computeTargets(sortedStrats, tvl);

        // 3. Apply bucket constraints (regime-aware limits, static class)
        targets = _applyBucketConstraints(sortedStrats, targets, tvl);

        // 4. Compute withdraw / deposit amounts per strategy
        plan.strategies = sortedStrats;
        plan.withdrawAmounts = new uint256[](n);
        plan.depositAmounts = new uint256[](n);
        plan.strategyConfidences = new uint16[](n);
        plan.strategyScores = new uint16[](n);

        uint256 sumWithdraw = 0;
        uint256 sumDeposit = 0;

        IStrategyScorer.StrategyScore[] memory scores = address(scorer) != address(0)
            ? scorer.computeScores(sortedStrats)
            : new IStrategyScorer.StrategyScore[](n);

        for (uint256 i = 0; i < n; i++) {
            if (sortedAllocs[i] > targets[i]) {
                plan.withdrawAmounts[i] = sortedAllocs[i] - targets[i];
                sumWithdraw += plan.withdrawAmounts[i];
            } else if (targets[i] > sortedAllocs[i]) {
                plan.depositAmounts[i] = targets[i] - sortedAllocs[i];
                sumDeposit += plan.depositAmounts[i];
            }
            // Strategy confidence (effective, already source-valid/decay-adjusted)
            plan.strategyConfidences[i] = address(scorer) != address(0)
                ? scorer.effectiveConfidence(sortedStrats[i])
                : uint16(5000);
            // Score from scorer.computeScores (already normalized to sum 10000)
            plan.strategyScores[i] = scores.length > i ? uint16(scores[i].score) : 0;
        }

        plan.totalMoveUsd = sumWithdraw;
        plan.estimatedWithdrawUsd = sumWithdraw;
        plan.estimatedDepositUsd = sumDeposit;

        // 5. Drift BPS
        plan.driftBps = tvl > 0 ? uint16((sumWithdraw * BPS) / tvl) : 0;

        // 6. Weighted APYs: risk-adjusted EMA APY weighted by allocation
        plan.weightedCurrentAPYBps = _weightedApy(sortedStrats, sortedAllocs, tvl);
        plan.weightedTargetAPYBps  = _weightedApy(sortedStrats, targets, tvl);
        // Signed delta
        {
            int256 delta = int256(uint256(plan.weightedTargetAPYBps))
                         - int256(uint256(plan.weightedCurrentAPYBps));
            int256 maxI16 = int256(int16(type(int16).max));
            int256 minI16 = int256(int16(type(int16).min));
            if (delta > maxI16) delta = maxI16;
            else if (delta < minI16) delta = minI16;
            plan.deltaAPYBps = int16(delta);
        }

        // 7. Aggregate confidence (weighted by target allocation)
        plan.aggregateConfidence = _aggregateConfidence(plan.strategyConfidences, targets, tvl);

        // 8. Safety classification (Fix #1)
        (bool isSafety, uint16 reasonCode) = _classifySafetyInternal(sortedStrats, sortedAllocs, tvl);
        plan.isSafetyPlan = isSafety;
        plan.safetyReasonCode = reasonCode;

        // NOTE: RebalancePlanBuilt event is emitted by LiquidityOpsModule (caller)
        // to keep this function pure/view for composability with guard.evaluatePlan().
    }

    /// @inheritdoc IRouterAllocationPolicy
    function classifySafety(
        address[] calldata strategies,
        uint256[] calldata currentAllocs,
        uint256 tvl
    ) external view override returns (bool isSafety, uint16 reasonCode) {
        (address[] memory sortedStrats, uint256[] memory sortedAllocs) =
            _sortAscending(strategies, currentAllocs);
        return _classifySafetyInternal(sortedStrats, sortedAllocs, tvl);
    }

    /// @inheritdoc IRouterAllocationPolicy
    function computeDriftBps(uint256 totalMoveUsd, uint256 tvl)
        external pure override returns (uint16)
    {
        if (tvl == 0) return 0;
        uint256 b = (totalMoveUsd * BPS) / tvl;
        return b > type(uint16).max ? type(uint16).max : uint16(b);
    }

    // coreBucketMinBpsByRegime / coreBucketMaxBpsByRegime auto-generated from public state arrays.

    /// @inheritdoc IRouterAllocationPolicy
    function currentRegime() external view override returns (uint8) {
        if (guard == address(0)) return 0; // STABLE default
        // Low-level call to avoid creating a hard import dependency loop.
        (bool ok, bytes memory data) = guard.staticcall(abi.encodeWithSignature("currentRegime()"));
        if (!ok || data.length < 32) return 0;
        return uint8(abi.decode(data, (uint256)));
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Insertion sort by address ascending. Returns memory copies aligned.
    function _sortAscending(address[] calldata strategies, uint256[] calldata allocs)
        internal pure returns (address[] memory outStrats, uint256[] memory outAllocs)
    {
        uint256 n = strategies.length;
        outStrats = new address[](n);
        outAllocs = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            outStrats[i] = strategies[i];
            outAllocs[i] = allocs[i];
        }
        // insertion sort (n is small — max 10)
        for (uint256 i = 1; i < n; i++) {
            address keyS = outStrats[i];
            uint256 keyA = outAllocs[i];
            uint256 j = i;
            while (j > 0 && outStrats[j - 1] > keyS) {
                outStrats[j] = outStrats[j - 1];
                outAllocs[j] = outAllocs[j - 1];
                unchecked { --j; }
            }
            outStrats[j] = keyS;
            outAllocs[j] = keyA;
        }
    }

    /// @dev Compute target allocations using scorer.
    ///      Uses the existing scorer.computeAllocations() API for backward compat.
    function _computeTargets(address[] memory strategies, uint256 tvl)
        internal view returns (uint256[] memory targets)
    {
        uint256 n = strategies.length;
        targets = new uint256[](n);
        if (address(scorer) == address(0) || tvl == 0) return targets;

        // Convert memory → calldata by reallocation (unavoidable Solidity limitation)
        address[] memory tmp = new address[](n);
        for (uint256 i = 0; i < n; i++) tmp[i] = strategies[i];
        // Cast memory array to calldata via external self-call pattern; simpler: call view via `this`
        // We use scorer's `computeAllocations` directly; scorer accepts calldata — so we rely on
        // the fact that memory array is ABI-encoded identically at the external call boundary.
        targets = scorer.computeAllocations(tmp, tvl);
    }

    /// @dev Apply regime-aware core/tactical bucket constraints.
    ///      CORE bucket min/max of TVL enforced. TACTICAL takes the remainder.
    function _applyBucketConstraints(
        address[] memory strategies,
        uint256[] memory targets,
        uint256 tvl
    ) internal view returns (uint256[] memory) {
        if (address(scorer) == address(0) || tvl == 0) return targets;
        uint8 regime = this.currentRegime();
        uint16 coreMin = coreBucketMinBpsByRegime[regime];
        uint16 coreMax = coreBucketMaxBpsByRegime[regime];

        // Compute current core/tactical shares
        uint256 coreTotal = 0;
        uint256 tacticalTotal = 0;
        uint256 n = strategies.length;
        bool[] memory isCore = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            uint8 b = scorer.strategyBucket(strategies[i]);
            if (b == 0) {
                isCore[i] = true;
                coreTotal += targets[i];
            } else {
                tacticalTotal += targets[i];
            }
        }

        uint256 sumT = coreTotal + tacticalTotal;
        if (sumT == 0) return targets;

        uint256 coreMinUsd = (uint256(coreMin) * tvl) / BPS;
        uint256 coreMaxUsd = (uint256(coreMax) * tvl) / BPS;

        // If core under min → redistribute proportionally from tactical to core
        if (coreTotal < coreMinUsd && coreTotal > 0) {
            uint256 gap = coreMinUsd - coreTotal;
            // Cap the gap at what's available in tactical
            if (gap > tacticalTotal) gap = tacticalTotal;
            // Scale core targets up by (coreTotal + gap) / coreTotal
            // Scale tactical targets down by (tacticalTotal - gap) / tacticalTotal
            uint256 newCoreScale = ((coreTotal + gap) * BPS) / coreTotal;
            uint256 newTacticalScale = tacticalTotal > 0
                ? ((tacticalTotal - gap) * BPS) / tacticalTotal : 0;
            for (uint256 i = 0; i < n; i++) {
                if (isCore[i]) {
                    targets[i] = (targets[i] * newCoreScale) / BPS;
                } else {
                    targets[i] = (targets[i] * newTacticalScale) / BPS;
                }
            }
        }

        // If core over max → redistribute proportionally from core to tactical
        if (coreTotal > coreMaxUsd && coreTotal > 0) {
            uint256 excess = coreTotal - coreMaxUsd;
            uint256 newCoreScale = ((coreTotal - excess) * BPS) / coreTotal;
            uint256 newTacticalScale = tacticalTotal > 0
                ? ((tacticalTotal + excess) * BPS) / tacticalTotal
                : BPS; // no tactical = keep core at max, excess stays (caller handles)
            for (uint256 i = 0; i < n; i++) {
                if (isCore[i]) {
                    targets[i] = (targets[i] * newCoreScale) / BPS;
                } else if (tacticalTotal > 0) {
                    targets[i] = (targets[i] * newTacticalScale) / BPS;
                }
            }
        }

        return targets;
    }

    /// @dev Weighted APY = sum(alloc[i] * riskAdjAPY[i]) / totalAlloc
    function _weightedApy(address[] memory strategies, uint256[] memory allocs, uint256 tvl)
        internal view returns (uint16)
    {
        if (address(scorer) == address(0) || tvl == 0) return 0;
        uint256 numer = 0;
        uint256 denom = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            uint16 apy = scorer.riskAdjustedAPY(strategies[i]);
            numer += uint256(apy) * allocs[i];
            denom += allocs[i];
        }
        if (denom == 0) return 0;
        uint256 w = numer / denom;
        return w > type(uint16).max ? type(uint16).max : uint16(w);
    }

    /// @dev Aggregate confidence weighted by target allocation
    function _aggregateConfidence(
        uint16[] memory confidences,
        uint256[] memory targets,
        uint256 tvl
    ) internal pure returns (uint16) {
        if (tvl == 0) return 0;
        uint256 numer = 0;
        uint256 denom = 0;
        for (uint256 i = 0; i < confidences.length; i++) {
            numer += uint256(confidences[i]) * targets[i];
            denom += targets[i];
        }
        if (denom == 0) return 0;
        uint256 w = numer / denom;
        return w > type(uint16).max ? type(uint16).max : uint16(w);
    }

    /// @dev Classify safety using AllocationInvariantLib (Fix #1).
    ///      NO APY dependency. Uses health registry + coordination hooks + queue pressure.
    function _classifySafetyInternal(
        address[] memory strategies,
        uint256[] memory currentAllocs,
        uint256 tvl
    ) internal view returns (bool, uint16) {
        uint256 n = strategies.length;
        AllocationTypes.SafetyContext memory ctx;
        ctx.strategyHealthBps = new uint16[](n);
        ctx.liquidityReadinessBps = new uint16[](n);
        ctx.strategyAssetsUsd = currentAllocs;
        ctx.strategyDisabledOrQuarantined = new bool[](n);

        // Health from registry
        for (uint256 i = 0; i < n; i++) {
            if (address(healthRegistry) != address(0)) {
                try healthRegistry.isHealthyForDeposit(strategies[i]) returns (bool ok) {
                    ctx.strategyHealthBps[i] = ok ? 10000 : 0;
                    ctx.strategyDisabledOrQuarantined[i] = !ok;
                } catch {
                    ctx.strategyHealthBps[i] = 0; // fail-closed
                    ctx.strategyDisabledOrQuarantined[i] = true;
                }
            } else {
                ctx.strategyHealthBps[i] = 10000;
            }

            // Liquidity readiness via coordination hook (fallback 10000 if not implemented)
            try IStrategyCoordination(strategies[i]).liquidityReadinessBps() returns (uint16 l) {
                ctx.liquidityReadinessBps[i] = l;
            } catch {
                ctx.liquidityReadinessBps[i] = 10000;
            }
        }

        // Queue pressure is provided by caller (Guard/LiquidityOps). In classifySafety view,
        // we don't have it — use 0 (no pressure assumption). The Guard enforces queue safety separately.
        ctx.queuePressureBps = 0;

        return AllocationInvariantLib.isSafetyCondition(
            ctx,
            healthThresholdBps,
            liquidityReadinessThresholdBps,
            maxStrategyExposureBps,
            queuePressureThresholdBps,
            tvl
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Governance
    // ─────────────────────────────────────────────────────────────────────

    function setScorer(address s) external onlyOwner {
        require(s != address(0), "zero");
        scorer = IStrategyScorerV10(s);
        emit ScorerSet(s);
    }

    function setHealthRegistry(address r) external onlyOwner {
        require(r != address(0), "zero");
        healthRegistry = IStrategyHealthRegistry(r);
        emit HealthRegistrySet(r);
    }

    function setGuard(address g) external onlyOwner {
        require(g != address(0), "zero");
        guard = g;
        emit GuardSet(g);
    }

    function setBucketLimits(uint8 regime, uint16 coreMinBps, uint16 coreMaxBps) external onlyOwner {
        if (regime >= 3) revert InvalidRegime();
        require(coreMinBps <= coreMaxBps && coreMaxBps <= BPS, "bps");
        coreBucketMinBpsByRegime[regime] = coreMinBps;
        coreBucketMaxBpsByRegime[regime] = coreMaxBps;
        emit BucketLimitsSet(regime, coreMinBps, coreMaxBps);
    }

    function setSafetyThresholds(
        uint16 healthBps,
        uint16 liqReadyBps,
        uint16 maxExposureBps,
        uint16 queuePressureBps
    ) external onlyOwner {
        healthThresholdBps = healthBps;
        liquidityReadinessThresholdBps = liqReadyBps;
        maxStrategyExposureBps = maxExposureBps;
        queuePressureThresholdBps = queuePressureBps;
        emit SafetyThresholdsSet(healthBps, liqReadyBps, maxExposureBps, queuePressureBps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }
}
