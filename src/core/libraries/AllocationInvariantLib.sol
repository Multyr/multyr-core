// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AllocationTypes } from "../../interfaces/IAllocationTypes.sol";

/// @title AllocationInvariantLib
/// @notice The SINGLE source of truth for safety classification, net benefit,
///         plan scaling, and invariant assertions in the allocation engine.
/// @dev Pure library. No state. Called by Policy and Guard.
///      Enforces CTO mandatory fixes: #1 (formal safety), #2 (single formula), #3 (formal scaling).
library AllocationInvariantLib {
    // ═════════════════════════════════════════════════════════════════════
    // Constants
    // ═════════════════════════════════════════════════════════════════════

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR_DAYS = 365;

    // Safety reason codes (Fix #1 — closed set)
    uint16 internal constant REASON_NONE            = 0;
    uint16 internal constant REASON_HEALTH          = 1;
    uint16 internal constant REASON_QUEUE           = 2;
    uint16 internal constant REASON_CONCENTRATION   = 3;
    uint16 internal constant REASON_LIQUIDITY       = 4;
    uint16 internal constant REASON_QUARANTINE      = 5;

    // ═════════════════════════════════════════════════════════════════════
    // Fix #1 — Formal safety definition (closed condition set, NO APY dependency)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Closed definition of a safety condition. MUST NOT depend on APY/scoring.
    /// @dev Priority order: health > liquidity > concentration > queue > quarantine.
    ///      First match wins to keep reason code deterministic.
    function isSafetyCondition(
        AllocationTypes.SafetyContext memory ctx,
        uint16 healthThresholdBps,
        uint16 liquidityReadinessThresholdBps,
        uint16 maxStrategyExposureBps,
        uint16 queuePressureThresholdBps,
        uint256 tvl
    ) internal pure returns (bool isSafety, uint16 reasonCode) {
        uint256 n;

        // Reason 1: strategy health below threshold
        n = ctx.strategyHealthBps.length;
        for (uint256 i = 0; i < n; i++) {
            if (ctx.strategyHealthBps[i] < healthThresholdBps) {
                return (true, REASON_HEALTH);
            }
        }

        // Reason 4: liquidity readiness breach
        n = ctx.liquidityReadinessBps.length;
        for (uint256 i = 0; i < n; i++) {
            if (ctx.liquidityReadinessBps[i] < liquidityReadinessThresholdBps) {
                return (true, REASON_LIQUIDITY);
            }
        }

        // Reason 3: concentration above max exposure
        n = ctx.strategyAssetsUsd.length;
        if (tvl > 0) {
            for (uint256 i = 0; i < n; i++) {
                if ((ctx.strategyAssetsUsd[i] * BPS) / tvl > maxStrategyExposureBps) {
                    return (true, REASON_CONCENTRATION);
                }
            }
        }

        // Reason 2: queue pressure above threshold
        if (ctx.queuePressureBps > queuePressureThresholdBps) {
            return (true, REASON_QUEUE);
        }

        // Reason 5: strategy disabled or quarantined
        n = ctx.strategyDisabledOrQuarantined.length;
        for (uint256 i = 0; i < n; i++) {
            if (ctx.strategyDisabledOrQuarantined[i]) {
                return (true, REASON_QUARANTINE);
            }
        }

        return (false, REASON_NONE);
    }

    // ═════════════════════════════════════════════════════════════════════
    // Fix #2 — Single deterministic net-benefit formula
    // ═════════════════════════════════════════════════════════════════════

    /// @notice The ONLY net-benefit formula used by Guard before and after scaling.
    /// @dev gross = moveUsd * deltaApyBps * horizonDays / (365 * 10000)
    ///      adjGross = gross * confidenceBps / 10000
    ///      netUsd = adjGross - costUsd
    ///      netBps = netUsd * 10000 / moveUsd
    /// @param moveUsd total capital moved (in asset units, e.g. USDC 6 decimals)
    /// @param deltaApyBps signed APY improvement in bps (can be negative)
    /// @param confidenceBps aggregate confidence [0, 10000]
    /// @param horizonDays benefit horizon in days (after regime override)
    /// @param costUsd total estimated cost (gas + slippage + execution penalty)
    function computeNetBenefitBps(
        uint256 moveUsd,
        int16   deltaApyBps,
        uint16  confidenceBps,
        uint16  horizonDays,
        uint256 costUsd
    ) internal pure returns (int256 netBenefitBps) {
        if (moveUsd == 0) return 0;

        // gross benefit in USD-units (signed: deltaApy can be negative)
        int256 gross;
        unchecked {
            gross = (int256(moveUsd) * int256(deltaApyBps) * int256(uint256(horizonDays)))
                  / int256(YEAR_DAYS * BPS);
        }

        // confidence-adjusted gross
        int256 adjGross = (gross * int256(uint256(confidenceBps))) / int256(BPS);

        int256 netUsd = adjGross - int256(costUsd);
        netBenefitBps = (netUsd * int256(BPS)) / int256(moveUsd);
    }

    // ═════════════════════════════════════════════════════════════════════
    // Fix #3 — Formal scalePlan with capital conservation, deterministic rounding,
    //          zero-strategy cleanup
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Scale a RebalancePlan by scaleBps with capital conservation and
    ///         deterministic rounding. Unchanged aggregates (APY, confidence) are preserved.
    /// @param plan original plan
    /// @param scaleBps fraction to keep [0, 10000]
    /// @param idleUsd idle USD available in the CoreVault (for capital conservation check)
    function scalePlan(
        AllocationTypes.RebalancePlan memory plan,
        uint256 scaleBps,
        uint256 idleUsd
    ) internal pure returns (AllocationTypes.RebalancePlan memory scaled) {
        require(scaleBps <= BPS, "scaleBps>10000");
        (uint256[] memory sw, uint256[] memory sd, uint256 sumW, uint256 sumD) =
            _scaleProportional(plan, scaleBps);
        sumD = _enforceCapitalConservation(sw, sd, sumW, sumD, idleUsd);
        scaled = _buildScaledPlan(plan, sw, sd, sumW, sumD);
    }

    function _scaleProportional(
        AllocationTypes.RebalancePlan memory plan,
        uint256 scaleBps
    ) private pure returns (uint256[] memory sw, uint256[] memory sd, uint256 sumW, uint256 sumD) {
        uint256 n = plan.strategies.length;
        sw = new uint256[](n);
        sd = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            sw[i] = (plan.withdrawAmounts[i] * scaleBps) / BPS;
            sd[i] = (plan.depositAmounts[i] * scaleBps) / BPS;
            sumW += sw[i];
            sumD += sd[i];
        }
    }

    function _enforceCapitalConservation(
        uint256[] memory sw,
        uint256[] memory sd,
        uint256 sumW,
        uint256 sumD,
        uint256 idleUsd
    ) private pure returns (uint256 newSumD) {
        uint256 n = sd.length;
        if (sumD <= sumW + idleUsd) return sumD;
        uint256 maxD = sumW + idleUsd;
        if (sumD > 0) {
            uint256 totalReduction = sumD - maxD;
            for (uint256 i = 0; i < n; i++) {
                uint256 cut = (sd[i] * totalReduction) / sumD;
                sd[i] = sd[i] > cut ? sd[i] - cut : 0;
            }
        } else {
            for (uint256 i = 0; i < n; i++) sd[i] = 0;
        }
        uint256 newSum = 0;
        for (uint256 i = 0; i < n; i++) newSum += sd[i];
        if (newSum < maxD && n > 0) {
            sd[n - 1] += (maxD - newSum);
        }
        newSumD = maxD;
    }

    /// @dev Helper to extract non-zero strategies and build final scaled plan.
    ///      Split into two sub-helpers to avoid Yul stack-too-deep.
    function _buildScaledPlan(
        AllocationTypes.RebalancePlan memory plan,
        uint256[] memory sw,
        uint256[] memory sd,
        uint256 sumW,
        uint256 sumD
    ) private pure returns (AllocationTypes.RebalancePlan memory scaled) {
        _buildScaledArrays(plan, sw, sd, scaled);
        _buildScaledAggregates(plan, sumW, sumD, scaled);
    }

    function _buildScaledArrays(
        AllocationTypes.RebalancePlan memory plan,
        uint256[] memory sw,
        uint256[] memory sd,
        AllocationTypes.RebalancePlan memory scaled
    ) private pure {
        uint256 n = sw.length;
        uint256 keepCount = _countNonZero(sw, sd);
        scaled.strategies = new address[](keepCount);
        scaled.withdrawAmounts = new uint256[](keepCount);
        scaled.depositAmounts = new uint256[](keepCount);
        scaled.strategyConfidences = new uint16[](keepCount);
        scaled.strategyScores = new uint16[](keepCount);
        _fillScaledArrays(plan, sw, sd, scaled, n);
    }

    function _countNonZero(uint256[] memory sw, uint256[] memory sd) private pure returns (uint256 c) {
        uint256 n = sw.length;
        for (uint256 i = 0; i < n; i++) {
            if (sw[i] > 0 || sd[i] > 0) c++;
        }
    }

    function _fillScaledArrays(
        AllocationTypes.RebalancePlan memory plan,
        uint256[] memory sw,
        uint256[] memory sd,
        AllocationTypes.RebalancePlan memory scaled,
        uint256 n
    ) private pure {
        address[] memory srcStrats = plan.strategies;
        uint16[] memory srcConf = plan.strategyConfidences;
        uint16[] memory srcScores = plan.strategyScores;
        address[] memory outStrats = scaled.strategies;
        uint256[] memory outW = scaled.withdrawAmounts;
        uint256[] memory outD = scaled.depositAmounts;
        uint16[] memory outConf = scaled.strategyConfidences;
        uint16[] memory outScores = scaled.strategyScores;

        uint256 j = 0;
        for (uint256 i = 0; i < n; i++) {
            if (sw[i] > 0 || sd[i] > 0) {
                outStrats[j] = srcStrats[i];
                outW[j] = sw[i];
                outD[j] = sd[i];
                outConf[j] = srcConf[i];
                outScores[j] = srcScores[i];
                j++;
            }
        }
    }

    function _buildScaledAggregates(
        AllocationTypes.RebalancePlan memory plan,
        uint256 sumW,
        uint256 sumD,
        AllocationTypes.RebalancePlan memory scaled
    ) private pure {
        scaled.totalMoveUsd = sumW;
        scaled.estimatedWithdrawUsd = sumW;
        scaled.estimatedDepositUsd = sumD;
        scaled.driftBps = 0;
        scaled.weightedCurrentAPYBps = plan.weightedCurrentAPYBps;
        scaled.weightedTargetAPYBps  = plan.weightedTargetAPYBps;
        scaled.deltaAPYBps           = plan.deltaAPYBps;
        scaled.aggregateConfidence   = plan.aggregateConfidence;
        scaled.isSafetyPlan      = plan.isSafetyPlan;
        scaled.safetyReasonCode  = plan.safetyReasonCode;
    }

    // ═════════════════════════════════════════════════════════════════════
    // Invariants (Correction #16 — enforced from day 1)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Assert invariants on a RebalancePlan. Reverts on violation.
    /// @dev Inv 1: totalMoveUsd == sum(withdraws)  (with dust tolerance of 1 wei per strategy)
    ///      Inv 2: estimatedDepositUsd <= estimatedWithdrawUsd + idleUsd
    ///      Inv 3: array lengths aligned
    ///      Inv 4: strictly ascending addresses (deterministic ordering)
    function assertPlanInvariants(
        AllocationTypes.RebalancePlan memory plan,
        uint256 idleUsd
    ) internal pure {
        uint256 n = plan.strategies.length;
        require(plan.withdrawAmounts.length == n, "INV:len_w");
        require(plan.depositAmounts.length == n, "INV:len_d");
        require(plan.strategyConfidences.length == n, "INV:len_c");
        require(plan.strategyScores.length == n, "INV:len_s");

        uint256 sumW = 0;
        uint256 sumD = 0;
        address prev = address(0);
        for (uint256 i = 0; i < n; i++) {
            require(plan.strategies[i] != address(0), "INV:zero_strat");
            // Strictly ascending (Correction #10 — deterministic ordering).
            // Skip check on first element.
            if (i > 0) {
                require(plan.strategies[i] > prev, "INV:ordering");
            }
            prev = plan.strategies[i];
            sumW += plan.withdrawAmounts[i];
            sumD += plan.depositAmounts[i];
        }

        // Dust tolerance: 1 wei per strategy (rounding errors from proportional scaling)
        uint256 dustTol = n;
        if (plan.totalMoveUsd > sumW) {
            require(plan.totalMoveUsd - sumW <= dustTol, "INV:totalMove>sumW");
        } else {
            require(sumW - plan.totalMoveUsd <= dustTol, "INV:totalMove<sumW");
        }

        require(sumD <= sumW + idleUsd, "INV:capital_conservation");
        require(plan.estimatedWithdrawUsd <= sumW + dustTol, "INV:estW");
        require(plan.estimatedDepositUsd <= sumD + dustTol, "INV:estD");
    }

    /// @notice Assert that scaled plan does not exceed original plan's aggregates.
    function assertScaledPlanBounds(
        AllocationTypes.RebalancePlan memory original,
        AllocationTypes.RebalancePlan memory scaled
    ) internal pure {
        require(scaled.totalMoveUsd <= original.totalMoveUsd, "INV:scaledMove>original");
        require(scaled.estimatedWithdrawUsd <= original.estimatedWithdrawUsd, "INV:scaledW>originalW");
    }

    /// @notice Assert queue reserve preservation.
    /// @dev idleUsd - estimatedDepositUsd + estimatedWithdrawUsd >= queueReserveFloorUsd
    function assertQueueReserve(
        uint256 idleUsd,
        AllocationTypes.RebalancePlan memory plan,
        uint256 queueReserveFloorUsd
    ) internal pure {
        int256 idleAfter = int256(idleUsd)
                         - int256(plan.estimatedDepositUsd)
                         + int256(plan.estimatedWithdrawUsd);
        require(idleAfter >= int256(queueReserveFloorUsd), "INV:queue_reserve");
    }

    // ═════════════════════════════════════════════════════════════════════
    // Helper — clamp (Improvement #6)
    // ═════════════════════════════════════════════════════════════════════

    function clamp16(uint16 value, uint16 lo, uint16 hi) internal pure returns (uint16) {
        if (value < lo) return lo;
        if (value > hi) return hi;
        return value;
    }
}
