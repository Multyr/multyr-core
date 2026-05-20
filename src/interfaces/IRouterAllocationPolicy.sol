// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AllocationTypes } from "./IAllocationTypes.sol";

/// @title IRouterAllocationPolicy
/// @notice Builds deterministic RebalancePlans and classifies safety conditions.
interface IRouterAllocationPolicy {
    /// @notice Build a complete RebalancePlan including realized-cost inputs.
    /// @dev Strategies sorted by address ascending (Correction #10). Safety classified via
    ///      AllocationInvariantLib.isSafetyCondition (Fix #1 — no APY dependency).
    function buildRebalancePlan(
        address[] calldata strategies,
        uint256[] calldata currentAllocs,
        uint256 tvl
    ) external view returns (AllocationTypes.RebalancePlan memory plan);

    /// @notice Classify whether current state requires a safety-only rebalance.
    function classifySafety(
        address[] calldata strategies,
        uint256[] calldata currentAllocs,
        uint256 tvl
    ) external view returns (bool isSafety, uint16 reasonCode);

    /// @notice Compute scaled drift (for Guard post-scale recomputation).
    function computeDriftBps(
        uint256 totalMoveUsd,
        uint256 tvl
    ) external pure returns (uint16);

    /// @notice Current regime (delegated to Guard)
    function currentRegime() external view returns (uint8);

    event RebalancePlanBuilt(
        uint256 totalMoveUsd,
        uint16  driftBps,
        int16   deltaAPYBps,
        uint16  aggregateConfidence,
        bool    isSafetyPlan,
        uint16  safetyReasonCode
    );
}
