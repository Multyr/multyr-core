// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AllocationTypes } from "./IAllocationTypes.sol";

/// @title IRouterRebalanceGuard
/// @notice P0-P3 gate + budget enforcement + integrated scaling (Correction #2).
interface IRouterRebalanceGuard {
    /// @notice Evaluate a RebalancePlan and return proceed/skip decision with scaled benefit.
    /// @dev Integrated scaling: Guard computes allowedMoveBps and re-evaluates benefit post-scale.
    ///      Uses AllocationInvariantLib.computeNetBenefitBps as the SINGLE benefit formula (Fix #2).
    function evaluatePlan(
        AllocationTypes.RebalancePlan calldata plan,
        uint256 tvl,
        uint256 idleUsd,
        AllocationTypes.QueueSafetyContext calldata qs
    ) external view returns (AllocationTypes.PlanEvaluation memory r);

    /// @notice Mutating: called by LiquidityOpsModule after successful execution to update budget + hysteresis state.
    function consumeBudget(uint16 movedBps) external;

    /// @notice Mutating: called when evaluation returns non-PROCEED, for consecutive-skip tracking (Improvement #5).
    function notifySkip() external;

    /// @notice Current regime (0=STABLE, 1=VOLATILE, 2=STRESS)
    function currentRegime() external view returns (uint8);

    /// @notice Regime setters (keeper + governance)
    function setRegime(uint8 regime) external;
    function forceRegime(uint8 regime) external;

    /// @notice Current hysteresis state (was last rebalance accepted?)
    function wasRebalancing() external view returns (bool);

    /// @notice Execution memory pointer (can be zero — fallback costs used)
    function executionMemory() external view returns (address);

    // ── Events (Correction #13) ──
    event RebalanceGuardEvaluated(
        bool proceed,
        uint8 reasonCode,
        int256 netBenefitBeforeScale,
        int256 netBenefitAfterScale,
        uint16 allowedMoveBps,
        uint8 regime
    );
    event RebalanceBudgetConsumed(uint16 movedBps, uint32 cumulativeMovedBps, uint64 periodStartTs);
    event SafetyOverrideTriggered(uint8 reasonCode);
    event ThresholdsRelaxed(uint8 consecutiveSkips, uint16 relaxedEntry, uint16 relaxedExit);
    event RegimeChanged(uint8 oldRegime, uint8 newRegime, address bySource);
}
