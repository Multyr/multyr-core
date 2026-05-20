// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAllocationTypes — shared types for the allocation engine
/// @notice Canonical definitions used by Policy, Guard, and LiquidityOpsModule.
library AllocationTypes {
    /// @notice A concrete rebalance plan with realized-cost inputs (Correction #1).
    /// @dev Arrays MUST be aligned to `strategies[]`. Strategies sorted ascending by address (Correction #10).
    struct RebalancePlan {
        // Deterministic ordering
        address[] strategies;
        uint256[] withdrawAmounts;
        uint256[] depositAmounts;
        uint16[]  strategyConfidences;
        uint16[]  strategyScores;

        // Aggregates (computed by Policy, not recomputed by Guard)
        uint256 totalMoveUsd;
        uint256 estimatedWithdrawUsd;
        uint256 estimatedDepositUsd;
        uint16  driftBps;
        uint16  weightedCurrentAPYBps;
        uint16  weightedTargetAPYBps;
        int16   deltaAPYBps;
        uint16  aggregateConfidence;

        // Safety classification (Fix #1 — closed set, NO APY dependency)
        bool    isSafetyPlan;
        uint16  safetyReasonCode; // 0=none, 1=health, 2=queue, 3=concentration, 4=liquidity, 5=quarantine
    }

    /// @notice Queue safety context passed to Guard (Correction #6)
    struct QueueSafetyContext {
        uint256 queueReservedUsd;
        uint16  queuePressureBps;
        uint16  availableIdleAfterPlanBps;
    }

    /// @notice Safety context for isSafetyCondition (Fix #1)
    struct SafetyContext {
        uint16[]  strategyHealthBps;
        uint16[]  liquidityReadinessBps;
        uint256[] strategyAssetsUsd;
        uint16    queuePressureBps;
        bool[]    strategyDisabledOrQuarantined;
    }

    /// @notice Guard's evaluation result (Correction #2 — scaling integrated)
    struct PlanEvaluation {
        bool   proceed;
        uint16 allowedMoveBps;
        int256 netBenefitBpsBeforeScale;
        int256 netBenefitBpsAfterScale;
        uint8  reasonCode; // GuardReason as uint8
        uint16 safetyReasonCode;
    }

    /// @notice Enum-coded reasons (Correction #14 — no strings)
    enum GuardReason {
        PROCEED,
        STRESS_BLOCK,
        HYSTERESIS_ENTRY,
        HYSTERESIS_EXIT,
        MIN_MOVE,
        LOW_BENEFIT,
        LOW_RATIO,
        BUDGET,
        QUEUE_SAFETY,
        SAFETY_ONLY,
        INVALID_PLAN,
        ZERO_SCALED_MOVE
    }

    /// @notice Regime enum
    enum Regime { STABLE, VOLATILE, STRESS }

    /// @notice Per-regime multipliers
    struct RegimeConfig {
        uint16 hysteresisMultBps; // 10000 = 1x
        uint16 budgetMultBps;
        uint16 horizonDays;       // override if > 0
        uint16 confidenceMultBps;
    }
}
