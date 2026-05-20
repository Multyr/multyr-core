// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IExecutionMemory
/// @notice Bootstrap-safe cost model with observationCount thresholds and inactivity decay.
interface IExecutionMemory {
    struct ExecutionRecord {
        uint64 emaGasCost;
        uint32 emaSlippageBps;
        uint32 failedCount;
        uint32 successCount;
        int32  emaRealizedVsExpectedBps;
        uint64 lastUpdateTs;
        uint16 observationCount;
    }

    /// @notice Record execution outcome. Outliers above maxAcceptable* are rejected silently with event.
    function recordExecution(
        address strategy,
        uint256 gasUsed,
        uint16 slippageBps,
        int256 realizedVsExpectedBps,
        bool success
    ) external;

    /// @notice Expected cost for a strategy. Returns fallback if observationCount < minObservationsForLiveCost.
    ///         Applies inactivity decay (Improvement #4) if record is stale.
    function getExpectedCost(address strategy)
        external view returns (uint256 gasCostUsd, uint16 slippageBps);

    /// @notice Per-strategy execution penalty in bps. Zero/fallback if below minObservationsForPenalty.
    function getPenalty(address strategy) external view returns (uint16 penaltyBps);

    /// @notice Aggregate penalty across a set of strategies (average).
    function getAggregatePenalty(address[] calldata strategies)
        external view returns (uint16 avgPenaltyBps);

    /// @notice Record lookup
    function records(address strategy) external view returns (
        uint64 emaGasCost,
        uint32 emaSlippageBps,
        uint32 failedCount,
        uint32 successCount,
        int32  emaRealizedVsExpectedBps,
        uint64 lastUpdateTs,
        uint16 observationCount
    );

    // ── Events (Correction #13) ──
    event ExecutionMemoryRecorded(
        address indexed strategy,
        uint256 gasUsed,
        uint16 slippageBps,
        int256 realizedVsExpectedBps,
        uint16 observationCount
    );
    event ExecutionOutlierRejected(address indexed strategy, uint256 gasUsed, uint16 slippageBps);
}
