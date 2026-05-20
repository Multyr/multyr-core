// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IRouterRebalanceGuard } from "../../interfaces/IRouterRebalanceGuard.sol";
import { IExecutionMemory } from "../../interfaces/IExecutionMemory.sol";
import { IStrategyCoordination } from "../../interfaces/IStrategyCoordination.sol";
import { AllocationTypes } from "../../interfaces/IAllocationTypes.sol";
import { AllocationInvariantLib } from "../libraries/AllocationInvariantLib.sol";

/// @title RouterRebalanceGuard — portfolio-grade gate (P0-P3 + budget + queue safety + safety exception)
/// @notice SINGLE source of decision for whether a rebalance proceeds. Integrated scaling (Correction #2),
///         formal safety (Fix #1), single benefit formula (Fix #2), formal scaling (Fix #3).
/// @dev Callable by LiquidityOpsModule. State-mutating functions (`consumeBudget`, `notifySkip`, `setRegime`)
///      are restricted to the orchestrator or keeper/owner.
contract RouterRebalanceGuard is IRouterRebalanceGuard {

    uint256 private constant BPS = 10_000;

    // ─────────────────────────────────────────────────────────────────────
    // Access
    // ─────────────────────────────────────────────────────────────────────

    address public owner;
    address public keeper;
    address public orchestrator; // LiquidityOpsModule / CoreVault

    // ─────────────────────────────────────────────────────────────────────
    // P0 — Gate config
    // ─────────────────────────────────────────────────────────────────────

    uint16 public entryDriftBps           = 500;    // 5%
    uint16 public exitDriftBps            = 200;    // 2%
    uint256 public minMoveUsd             = 1000 * 1e6;
    uint16 public minMoveBps              = 10;     // 0.1%
    uint16 public minBenefitCostRatioBps  = 15_000; // 1.5x
    uint16 public gateHorizonDays         = 30;
    uint16 public minNetBenefitBps        = 10;     // 0.1%
    bool   public wasRebalancing;

    // ─────────────────────────────────────────────────────────────────────
    // P1 — Budget
    // ─────────────────────────────────────────────────────────────────────

    enum BudgetMode { HARD_RESET, ROLLING_DECAY }
    BudgetMode public budgetMode              = BudgetMode.HARD_RESET;
    uint64 public lastBudgetResetTs;
    uint32 public cumulativeMovedBps;
    uint16 public maxMoveBpsPerCycle          = 1_000;  // 10%
    uint16 public maxMoveBpsPerDay            = 2_000;  // 20%
    uint16 public safetyMaxMoveBpsPerDay      = 5_000;  // 50% (emergency override — Correction #15)
    uint32 public budgetResetIntervalSeconds  = 86_400;

    // ─────────────────────────────────────────────────────────────────────
    // P3 — Regime
    // ─────────────────────────────────────────────────────────────────────

    uint8 public override currentRegime;

    AllocationTypes.RegimeConfig[3] public regimeConfigs;

    // ─────────────────────────────────────────────────────────────────────
    // Queue safety
    // ─────────────────────────────────────────────────────────────────────

    uint16 public queuePressureThresholdBps      = 3_000;
    uint16 public minAvailableIdleAfterPlanBps   = 500;
    uint256 public queueReserveFloorUsd;

    // ─────────────────────────────────────────────────────────────────────
    // Cost model pointer
    // ─────────────────────────────────────────────────────────────────────

    address public override executionMemory;
    bool public strictExecutionMemory;

    // Fallback cost if ExecutionMemory absent/below threshold.
    uint256 public baseGasCostUsd       = 50 * 1e6;
    uint16 public baseSlippageBps       = 5;
    uint16 public basePenaltyBps        = 50;
    uint32 public maxAcceptableGasCost  = 500 * 1e6;
    uint16 public maxAcceptableSlippageBps = 1_000;

    // ─────────────────────────────────────────────────────────────────────
    // Coordination (Correction #4 — derived, not keeper-poked)
    // ─────────────────────────────────────────────────────────────────────

    uint16 public coordRecencyMultBps = 5_000; // halve benefit if recently rebalanced
    uint32 public coordWindowSeconds  = 3_600;

    // ─────────────────────────────────────────────────────────────────────
    // Improvement #5 — consecutive skips relaxation
    // ─────────────────────────────────────────────────────────────────────

    uint8 public consecutiveSkips;
    uint8 public maxConsecutiveSkips = 5;
    uint16 public skipRelaxMultBps   = 7_000;

    // ─────────────────────────────────────────────────────────────────────
    // Improvement #6 — confidence clamp
    // ─────────────────────────────────────────────────────────────────────

    uint16 public minConfidenceBps = 1_000;
    uint16 public maxConfidenceBps = 10_000;

    // ─────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────

    error NotOwner();
    error NotKeeper();
    error NotOrchestrator();
    error ZeroAddress();
    error InvalidRegime();

    // ─────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyKeeperOrOwner() { if (msg.sender != keeper && msg.sender != owner) revert NotKeeper(); _; }
    modifier onlyOrchestrator() { if (msg.sender != orchestrator) revert NotOrchestrator(); _; }

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(address owner_, address keeper_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (keeper_ == address(0)) revert ZeroAddress();
        owner = owner_;
        keeper = keeper_;
        lastBudgetResetTs = uint64(block.timestamp);

        // Default regime configs
        // STABLE
        regimeConfigs[0] = AllocationTypes.RegimeConfig({
            hysteresisMultBps: 10_000,
            budgetMultBps: 10_000,
            horizonDays: 30,
            confidenceMultBps: 10_000
        });
        // VOLATILE
        regimeConfigs[1] = AllocationTypes.RegimeConfig({
            hysteresisMultBps: 15_000,
            budgetMultBps: 7_000,
            horizonDays: 14,
            confidenceMultBps: 8_000
        });
        // STRESS
        regimeConfigs[2] = AllocationTypes.RegimeConfig({
            hysteresisMultBps: 20_000,
            budgetMultBps: 3_000,
            horizonDays: 7,
            confidenceMultBps: 5_000
        });
    }

    // ─────────────────────────────────────────────────────────────────────
    // evaluatePlan — integrated scaling (Correction #2)
    // ─────────────────────────────────────────────────────────────────────

    /// @inheritdoc IRouterRebalanceGuard
    function evaluatePlan(
        AllocationTypes.RebalancePlan calldata plan,
        uint256 tvl,
        uint256 idleUsd,
        AllocationTypes.QueueSafetyContext calldata qs
    ) external view override returns (AllocationTypes.PlanEvaluation memory r) {
        // Step 1: basic plan validity
        if (plan.strategies.length == 0 || tvl == 0) {
            r.reasonCode = uint8(AllocationTypes.GuardReason.INVALID_PLAN);
            return r;
        }

        AllocationTypes.RegimeConfig memory rc = regimeConfigs[currentRegime];

        // Step 2: STRESS + safety exception (Correction #5)
        if (currentRegime == uint8(AllocationTypes.Regime.STRESS) && !plan.isSafetyPlan) {
            r.reasonCode = uint8(AllocationTypes.GuardReason.STRESS_BLOCK);
            return r;
        }

        // Step 3: Queue safety (Correction #6 — machine-checked)
        if (!plan.isSafetyPlan) {
            if (qs.queuePressureBps > queuePressureThresholdBps) {
                r.reasonCode = uint8(AllocationTypes.GuardReason.QUEUE_SAFETY);
                return r;
            }
            if (qs.availableIdleAfterPlanBps < minAvailableIdleAfterPlanBps) {
                r.reasonCode = uint8(AllocationTypes.GuardReason.QUEUE_SAFETY);
                return r;
            }
        }

        // Step 4: Hysteresis (skip for safety plans)
        if (!plan.isSafetyPlan) {
            uint256 effEntry = (uint256(entryDriftBps) * rc.hysteresisMultBps) / BPS;
            uint256 effExit  = (uint256(exitDriftBps)  * rc.hysteresisMultBps) / BPS;
            // Apply consecutive-skip relaxation (Improvement #5)
            if (consecutiveSkips >= maxConsecutiveSkips) {
                effEntry = (effEntry * skipRelaxMultBps) / BPS;
                effExit  = (effExit  * skipRelaxMultBps) / BPS;
            }
            if (wasRebalancing) {
                if (plan.driftBps < effExit) {
                    r.reasonCode = uint8(AllocationTypes.GuardReason.HYSTERESIS_EXIT);
                    return r;
                }
            } else {
                if (plan.driftBps < effEntry) {
                    r.reasonCode = uint8(AllocationTypes.GuardReason.HYSTERESIS_ENTRY);
                    return r;
                }
            }
        }

        // Step 5: Min move
        if (!plan.isSafetyPlan) {
            uint256 minFromBps = (tvl * uint256(minMoveBps)) / BPS;
            uint256 minRequired = minMoveUsd > minFromBps ? minMoveUsd : minFromBps;
            if (plan.totalMoveUsd < minRequired) {
                r.reasonCode = uint8(AllocationTypes.GuardReason.MIN_MOVE);
                return r;
            }
        }

        // Step 6: Benefit / cost (pre-scale)
        uint16 horizon = rc.horizonDays > 0 ? rc.horizonDays : gateHorizonDays;
        uint16 finalConf = _finalConfidence(plan.aggregateConfidence, rc.confidenceMultBps);
        uint256 costUsd = _estimateCost(plan);

        r.netBenefitBpsBeforeScale = AllocationInvariantLib.computeNetBenefitBps(
            plan.totalMoveUsd, plan.deltaAPYBps, finalConf, horizon, costUsd
        );

        if (!plan.isSafetyPlan) {
            if (r.netBenefitBpsBeforeScale < int256(uint256(minNetBenefitBps))) {
                r.reasonCode = uint8(AllocationTypes.GuardReason.LOW_BENEFIT);
                return r;
            }
            if (costUsd > 0) {
                // Use the same formula components: grossBenefit = netBenefit + cost (in USD)
                int256 grossUsd = (int256(r.netBenefitBpsBeforeScale) * int256(plan.totalMoveUsd)) / int256(BPS)
                                + int256(costUsd);
                if (grossUsd * int256(BPS) / int256(costUsd) < int256(uint256(minBenefitCostRatioBps))) {
                    r.reasonCode = uint8(AllocationTypes.GuardReason.LOW_RATIO);
                    return r;
                }
            }
        }

        // Step 7: Budget → allowedMoveBps
        r.allowedMoveBps = _allowedMoveBps(plan.isSafetyPlan, rc.budgetMultBps);

        // If plan's drift already under allowed, we can let it proceed as-is (scaleBps = 10000).
        // Otherwise scaleBps = allowedMoveBps / driftBps.
        uint256 scaleBps;
        if (plan.driftBps == 0) {
            scaleBps = BPS;
        } else if (plan.driftBps <= r.allowedMoveBps) {
            scaleBps = BPS;
        } else {
            scaleBps = (uint256(r.allowedMoveBps) * BPS) / plan.driftBps;
        }

        // Step 8: Scale plan (Fix #3)
        AllocationTypes.RebalancePlan memory scaled = AllocationInvariantLib.scalePlan(
            _copyPlanToMemory(plan), scaleBps, idleUsd
        );

        if (scaled.totalMoveUsd == 0) {
            r.reasonCode = uint8(AllocationTypes.GuardReason.ZERO_SCALED_MOVE);
            return r;
        }

        // Step 9: Post-scale re-evaluation
        r.netBenefitBpsAfterScale = AllocationInvariantLib.computeNetBenefitBps(
            scaled.totalMoveUsd, scaled.deltaAPYBps, finalConf, horizon, _estimateCostScaled(scaled)
        );

        if (!plan.isSafetyPlan) {
            uint256 minFromBps = (tvl * uint256(minMoveBps)) / BPS;
            uint256 minRequired = minMoveUsd > minFromBps ? minMoveUsd : minFromBps;
            if (scaled.totalMoveUsd < minRequired) {
                r.reasonCode = uint8(AllocationTypes.GuardReason.MIN_MOVE);
                return r;
            }
            if (r.netBenefitBpsAfterScale < 0) {
                r.reasonCode = uint8(AllocationTypes.GuardReason.LOW_BENEFIT);
                return r;
            }
        }

        r.proceed = true;
        r.reasonCode = uint8(AllocationTypes.GuardReason.PROCEED);
        r.safetyReasonCode = plan.safetyReasonCode;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────

    function _finalConfidence(uint16 agg, uint16 regimeConfMult) internal view returns (uint16) {
        uint256 adjusted = (uint256(agg) * uint256(regimeConfMult)) / BPS;
        if (adjusted > BPS) adjusted = BPS;
        return AllocationInvariantLib.clamp16(uint16(adjusted), minConfidenceBps, maxConfidenceBps);
    }

    function _estimateCost(AllocationTypes.RebalancePlan calldata plan) internal view returns (uint256) {
        uint256 totalGas;
        uint256 totalSlippage;
        uint256 totalPenalty;

        if (executionMemory == address(0)) {
            // No memory → fallback scaled per strategy
            totalGas = baseGasCostUsd * plan.strategies.length;
            totalSlippage = (plan.totalMoveUsd * uint256(baseSlippageBps)) / BPS;
            totalPenalty = (plan.totalMoveUsd * uint256(basePenaltyBps)) / BPS;
        } else {
            for (uint256 i = 0; i < plan.strategies.length; i++) {
                if (plan.withdrawAmounts[i] == 0 && plan.depositAmounts[i] == 0) continue;
                (uint256 g, uint16 slip) = IExecutionMemory(executionMemory).getExpectedCost(plan.strategies[i]);
                totalGas += g;
                uint256 moveUsd = plan.withdrawAmounts[i] + plan.depositAmounts[i];
                totalSlippage += (moveUsd * uint256(slip)) / BPS;
            }
            uint16 aggPenalty = IExecutionMemory(executionMemory).getAggregatePenalty(plan.strategies);
            totalPenalty = (plan.totalMoveUsd * uint256(aggPenalty)) / BPS;
        }

        // Coordination penalty: if any strategy was recently rebalanced internally, apply a penalty
        // Reads IStrategyCoordination hooks live (Correction #4).
        // Use extcodesize check to avoid revert on EOA targets (Solidity try/catch does NOT catch
        // "call to non-contract address" errors on empty code).
        uint256 coordPen = 0;
        for (uint256 i = 0; i < plan.strategies.length; i++) {
            if (plan.withdrawAmounts[i] == 0 && plan.depositAmounts[i] == 0) continue;
            address s = plan.strategies[i];
            uint256 codeLen;
            assembly { codeLen := extcodesize(s) }
            if (codeLen == 0) continue;
            try IStrategyCoordination(s).lastInternalRebalanceTs() returns (uint64 ts) {
                if (block.timestamp <= coordWindowSeconds || block.timestamp - ts < coordWindowSeconds) {
                    uint256 moveUsd = plan.withdrawAmounts[i] + plan.depositAmounts[i];
                    coordPen += (moveUsd * uint256(coordRecencyMultBps)) / BPS;
                }
            } catch {}
        }

        return totalGas + totalSlippage + totalPenalty + coordPen;
    }

    function _estimateCostScaled(AllocationTypes.RebalancePlan memory plan) internal view returns (uint256) {
        if (executionMemory == address(0)) {
            uint256 g = baseGasCostUsd * plan.strategies.length;
            uint256 s = (plan.totalMoveUsd * uint256(baseSlippageBps)) / BPS;
            uint256 p = (plan.totalMoveUsd * uint256(basePenaltyBps)) / BPS;
            return g + s + p;
        }
        uint256 totalGas;
        uint256 totalSlippage;
        for (uint256 i = 0; i < plan.strategies.length; i++) {
            if (plan.withdrawAmounts[i] == 0 && plan.depositAmounts[i] == 0) continue;
            (uint256 g, uint16 slip) = IExecutionMemory(executionMemory).getExpectedCost(plan.strategies[i]);
            totalGas += g;
            uint256 moveUsd = plan.withdrawAmounts[i] + plan.depositAmounts[i];
            totalSlippage += (moveUsd * uint256(slip)) / BPS;
        }
        uint16 aggPenalty = IExecutionMemory(executionMemory).getAggregatePenalty(plan.strategies);
        uint256 penalty = (plan.totalMoveUsd * uint256(aggPenalty)) / BPS;
        return totalGas + totalSlippage + penalty;
    }

    function _allowedMoveBps(bool isSafety, uint16 regimeBudgetMult) internal view returns (uint16) {
        // Safety override: uses safetyMaxMoveBpsPerDay and ignores regime budget mult
        if (isSafety) {
            uint16 dayRem = _remainingDayBudgetBps(true);
            uint16 cycle = maxMoveBpsPerCycle;
            return dayRem < cycle ? dayRem : cycle;
        }
        uint16 dayRem = _remainingDayBudgetBps(false);
        uint256 cycleAdj = (uint256(maxMoveBpsPerCycle) * uint256(regimeBudgetMult)) / BPS;
        uint256 effective = dayRem < cycleAdj ? dayRem : cycleAdj;
        return effective > BPS ? uint16(BPS) : uint16(effective);
    }

    function _remainingDayBudgetBps(bool safety) internal view returns (uint16) {
        uint16 cap = safety ? safetyMaxMoveBpsPerDay : maxMoveBpsPerDay;

        if (budgetMode == BudgetMode.HARD_RESET) {
            uint256 elapsed = block.timestamp - lastBudgetResetTs;
            if (elapsed >= budgetResetIntervalSeconds) return cap;
            if (cap > cumulativeMovedBps) return cap - uint16(cumulativeMovedBps);
            return 0;
        } else {
            // ROLLING_DECAY
            uint256 elapsed = block.timestamp - lastBudgetResetTs;
            uint256 remaining = budgetResetIntervalSeconds > elapsed
                ? budgetResetIntervalSeconds - elapsed : 0;
            uint256 decayed = uint256(cumulativeMovedBps) * remaining / uint256(budgetResetIntervalSeconds);
            return cap > decayed ? cap - uint16(decayed) : 0;
        }
    }

    /// @dev Copy calldata plan to memory so scalePlan (which takes memory) can process it.
    function _copyPlanToMemory(AllocationTypes.RebalancePlan calldata src)
        internal pure returns (AllocationTypes.RebalancePlan memory out)
    {
        uint256 n = src.strategies.length;
        out.strategies = new address[](n);
        out.withdrawAmounts = new uint256[](n);
        out.depositAmounts = new uint256[](n);
        out.strategyConfidences = new uint16[](n);
        out.strategyScores = new uint16[](n);
        for (uint256 i = 0; i < n; i++) {
            out.strategies[i] = src.strategies[i];
            out.withdrawAmounts[i] = src.withdrawAmounts[i];
            out.depositAmounts[i] = src.depositAmounts[i];
            out.strategyConfidences[i] = src.strategyConfidences[i];
            out.strategyScores[i] = src.strategyScores[i];
        }
        out.totalMoveUsd = src.totalMoveUsd;
        out.estimatedWithdrawUsd = src.estimatedWithdrawUsd;
        out.estimatedDepositUsd = src.estimatedDepositUsd;
        out.driftBps = src.driftBps;
        out.weightedCurrentAPYBps = src.weightedCurrentAPYBps;
        out.weightedTargetAPYBps = src.weightedTargetAPYBps;
        out.deltaAPYBps = src.deltaAPYBps;
        out.aggregateConfidence = src.aggregateConfidence;
        out.isSafetyPlan = src.isSafetyPlan;
        out.safetyReasonCode = src.safetyReasonCode;
    }

    // ─────────────────────────────────────────────────────────────────────
    // consumeBudget — called after successful execution
    // ─────────────────────────────────────────────────────────────────────

    /// @inheritdoc IRouterRebalanceGuard
    function consumeBudget(uint16 movedBps) external override onlyOrchestrator {
        _rollDayIfNeeded();
        cumulativeMovedBps += uint32(movedBps);
        wasRebalancing = true;
        consecutiveSkips = 0;
        emit RebalanceBudgetConsumed(movedBps, cumulativeMovedBps, lastBudgetResetTs);
    }

    /// @inheritdoc IRouterRebalanceGuard
    function notifySkip() external override onlyOrchestrator {
        _rollDayIfNeeded();
        if (consecutiveSkips < 255) consecutiveSkips += 1;
        wasRebalancing = false;
        if (consecutiveSkips == maxConsecutiveSkips) {
            uint256 relaxedEntry = (uint256(entryDriftBps) * skipRelaxMultBps) / BPS;
            uint256 relaxedExit  = (uint256(exitDriftBps)  * skipRelaxMultBps) / BPS;
            uint16 safeEntry = relaxedEntry > type(uint16).max ? type(uint16).max : uint16(relaxedEntry);
            uint16 safeExit  = relaxedExit  > type(uint16).max ? type(uint16).max : uint16(relaxedExit);
            emit ThresholdsRelaxed(consecutiveSkips, safeEntry, safeExit);
        }
    }

    function _rollDayIfNeeded() internal {
        uint256 elapsed = block.timestamp - lastBudgetResetTs;
        if (budgetMode == BudgetMode.HARD_RESET && elapsed >= budgetResetIntervalSeconds) {
            lastBudgetResetTs = uint64(block.timestamp);
            cumulativeMovedBps = 0;
        }
        // ROLLING_DECAY needs no reset — _remainingDayBudgetBps computes decay directly.
    }

    // ─────────────────────────────────────────────────────────────────────
    // Regime
    // ─────────────────────────────────────────────────────────────────────

    /// @inheritdoc IRouterRebalanceGuard
    function setRegime(uint8 regime) external override onlyKeeperOrOwner {
        if (regime >= 3) revert InvalidRegime();
        uint8 old = currentRegime;
        currentRegime = regime;
        emit RegimeChanged(old, regime, msg.sender);
    }

    /// @inheritdoc IRouterRebalanceGuard
    function forceRegime(uint8 regime) external override onlyOwner {
        if (regime >= 3) revert InvalidRegime();
        uint8 old = currentRegime;
        currentRegime = regime;
        emit RegimeChanged(old, regime, msg.sender);
    }

    // wasRebalancing() / executionMemory() — auto-generated from public state.

    // ─────────────────────────────────────────────────────────────────────
    // Governance
    // ─────────────────────────────────────────────────────────────────────

    function setOrchestrator(address o) external onlyOwner {
        require(o != address(0), "zero");
        orchestrator = o;
    }

    function setKeeper(address k) external onlyOwner {
        require(k != address(0), "zero");
        keeper = k;
    }

    function setExecutionMemory(address em) external onlyOwner {
        require(em != address(0), "zero");
        executionMemory = em;
    }

    function setStrictExecutionMemory(bool s) external onlyOwner { strictExecutionMemory = s; }

    function setGateConfig(
        uint16 _entryDriftBps,
        uint16 _exitDriftBps,
        uint256 _minMoveUsd,
        uint16 _minMoveBps,
        uint16 _minBenefitCostRatioBps,
        uint16 _gateHorizonDays,
        uint16 _minNetBenefitBps
    ) external onlyOwner {
        entryDriftBps = _entryDriftBps;
        exitDriftBps = _exitDriftBps;
        minMoveUsd = _minMoveUsd;
        minMoveBps = _minMoveBps;
        minBenefitCostRatioBps = _minBenefitCostRatioBps;
        gateHorizonDays = _gateHorizonDays;
        minNetBenefitBps = _minNetBenefitBps;
    }

    function setBudgetConfig(
        uint8 _mode,
        uint16 _maxMoveBpsPerCycle,
        uint16 _maxMoveBpsPerDay,
        uint16 _safetyMaxMoveBpsPerDay,
        uint32 _resetIntervalSeconds
    ) external onlyOwner {
        require(_mode < 2, "mode");
        budgetMode = BudgetMode(_mode);
        maxMoveBpsPerCycle = _maxMoveBpsPerCycle;
        maxMoveBpsPerDay = _maxMoveBpsPerDay;
        safetyMaxMoveBpsPerDay = _safetyMaxMoveBpsPerDay;
        budgetResetIntervalSeconds = _resetIntervalSeconds;
    }

    function setRegimeConfig(uint8 regime, AllocationTypes.RegimeConfig calldata cfg) external onlyOwner {
        if (regime >= 3) revert InvalidRegime();
        regimeConfigs[regime] = cfg;
    }

    function setQueueSafetyConfig(
        uint16 _queuePressureThresholdBps,
        uint16 _minAvailableIdleAfterPlanBps,
        uint256 _queueReserveFloorUsd
    ) external onlyOwner {
        queuePressureThresholdBps = _queuePressureThresholdBps;
        minAvailableIdleAfterPlanBps = _minAvailableIdleAfterPlanBps;
        queueReserveFloorUsd = _queueReserveFloorUsd;
    }

    function setCostModelFallbacks(
        uint256 _baseGasCostUsd,
        uint16 _baseSlippageBps,
        uint16 _basePenaltyBps
    ) external onlyOwner {
        baseGasCostUsd = _baseGasCostUsd;
        baseSlippageBps = _baseSlippageBps;
        basePenaltyBps = _basePenaltyBps;
    }

    function setSkipRelaxation(uint8 _maxSkips, uint16 _relaxMultBps) external onlyOwner {
        maxConsecutiveSkips = _maxSkips;
        skipRelaxMultBps = _relaxMultBps;
    }

    function setConfidenceClamp(uint16 _min, uint16 _max) external onlyOwner {
        require(_min <= _max && _max <= BPS, "bps");
        minConfidenceBps = _min;
        maxConfidenceBps = _max;
    }

    function setCoordinationParams(uint16 _recencyMultBps, uint32 _windowSeconds) external onlyOwner {
        coordRecencyMultBps = _recencyMultBps;
        coordWindowSeconds = _windowSeconds;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}
