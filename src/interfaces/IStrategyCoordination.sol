// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IStrategyCoordination — live coordination hooks (Correction #4)
/// @notice Optional hooks strategies expose for the Guard to compute coordination penalty.
/// @dev Guard reads these via try/catch. Missing hooks → fallback conservative values.
interface IStrategyCoordination {
    /// @notice Timestamp of last internal rebalance performed by the strategy
    function lastInternalRebalanceTs() external view returns (uint64);

    /// @notice Whether the strategy is currently performing an internal rebalance
    function isInternallyRebalancing() external view returns (bool);

    /// @notice Liquidity readiness in bps (10000 = fully ready for withdrawal)
    function liquidityReadinessBps() external view returns (uint16);

    /// @notice Self-reported penalty in bps if strategy is expensive/unready to rebalance
    function rebalancePenaltyBps() external view returns (uint16);
}
