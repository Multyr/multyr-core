// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IStrategyScorer } from "./IStrategyScorer.sol";

/// @title IStrategyScorerV10 — Extensions for portfolio-grade allocation engine.
/// @notice Additive interface. Legacy IStrategyScorer remains unchanged for backward compat.
/// @dev Callers that need the new fields (Guard, Policy) cast to IStrategyScorerV10.
interface IStrategyScorerV10 is IStrategyScorer {
    /// @notice Time-aware EMA state (Correction #9).
    function emaState(address strategy) external view returns (
        uint64 lastUpdateTs,
        uint32 emaApyBps,
        uint32 apyVolatilityBps
    );

    /// @notice Risk-adjusted APY in bps: emaAPY - volPenalty - illiqPenalty - opRisk (clamped to 0).
    function riskAdjustedAPY(address strategy) external view returns (uint16);

    /// @notice Effective confidence with source validity + staleness decay (Correction #8).
    function effectiveConfidence(address strategy) external view returns (uint16);

    /// @notice Capital bucket classification (0 = CORE, 1 = TACTICAL) — Correction #7.
    function strategyBucket(address strategy) external view returns (uint8);

    /// @notice Batch-poke metrics in a single call (keeper efficiency).
    function pokeStrategyMetrics(
        address strategy,
        uint16 spotApyBps,
        uint16 liqBps,
        uint16 stabBps,
        uint16 confBps
    ) external;
}
