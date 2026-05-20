// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IStrategyScorer — Interface for inter-strategy dynamic scoring
/// @notice Computes scores and target allocations across multiple IStrategy instances.
///         Uses governance/keeper-poked metrics since IStrategy lacks APY/risk functions.
interface IStrategyScorer {

    struct StrategyScore {
        address strategy;
        uint256 score;          // normalized [0, 10000]
        uint16 apyBps;          // raw APY (poked by keeper)
        uint16 riskBps;         // risk component (inverted: 10000 - riskScore)
        uint16 liquidityBps;    // cached liquidity
        uint16 stabilityBps;    // stability EMA
        uint16 incentiveBps;    // decayed incentive
    }

    /// @notice Compute scores for an array of eligible strategies
    function computeScores(address[] calldata strategies)
        external view returns (StrategyScore[] memory);

    /// @notice Compute target allocations for a given TVL
    /// @param strategies Array of eligible strategy addresses
    /// @param tvl Total value to allocate (in asset units, e.g. USDC 6 decimals)
    /// @return allocations Target allocation per strategy (same order as input)
    function computeAllocations(address[] calldata strategies, uint256 tvl)
        external view returns (uint256[] memory allocations);

    /// @notice Check whether inter-strategy rebalance is warranted
    /// @param strategies Array of eligible strategy addresses
    /// @param currentAllocs Current allocation per strategy (IStrategy.totalAssets)
    /// @param tvl Total value across all strategies
    /// @return needed True if drift exceeds threshold
    function shouldRebalance(
        address[] calldata strategies,
        uint256[] calldata currentAllocs,
        uint256 tvl
    ) external view returns (bool needed);

    /// @notice Check if a strategy is eligible for deposits
    /// @dev Checks health registry — returns false for DEGRADED/BROKEN
    function isEligible(address strategy) external view returns (bool);
}
