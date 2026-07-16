// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IStrategyHealthRegistry
 * @notice Centralized registry for tracking strategy health status
 * @dev Enables vault to use cached NAV for degraded/broken strategies
 *      and skip deposits to unhealthy strategies
 */
interface IStrategyHealthRegistry {
    /* ========== ENUMS ========== */

    /**
     * @notice Strategy operational state
     * @param OK Strategy operating normally, live NAV queries allowed
     * @param DEGRADED Strategy experiencing issues, use with caution
     * @param BROKEN Strategy non-functional, use cached NAV only
     */
    enum StrategyState {
        OK, // Normal operation
        DEGRADED, // Experiencing issues but operational
        BROKEN // Non-functional, use cached NAV
    }

    /* ========== STRUCTS ========== */

    /**
     * @notice Complete health information for a strategy
     * @param state Current operational state
     * @param lastKnownNAV Last successfully retrieved NAV value
     * @param lastUpdateTimestamp When the state or NAV was last updated
     * @param reason Human-readable reason for current state
     */
    struct StrategyHealth {
        StrategyState state;
        uint256 lastKnownNAV;
        uint64 lastUpdateTimestamp;
        string reason;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Get current state of a strategy
     * @param strategy Address of the strategy
     * @return Current StrategyState enum value
     */
    function getStrategyState(address strategy) external view returns (StrategyState);

    /**
     * @notice Get complete health information for a strategy
     * @param strategy Address of the strategy
     * @return health Complete StrategyHealth struct
     */
    function getStrategyHealth(address strategy) external view returns (StrategyHealth memory);

    /**
     * @notice Check if strategy is healthy enough for deposits
     * @param strategy Address of the strategy
     * @return True if state is OK, false if DEGRADED or BROKEN
     */
    function isHealthyForDeposit(address strategy) external view returns (bool);

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Update last known NAV for a strategy (called after successful query)
     * @param strategy Address of the strategy
     * @param nav The NAV value to cache
     * @dev Only callable by authorized callers (vault/router)
     */
    function updateLastKnownNAV(address strategy, uint256 nav) external;

    /**
     * @notice Set strategy state (called by guardian/owner when issues detected)
     * @param strategy Address of the strategy
     * @param newState New state to set
     * @param reason Human-readable explanation for state change
     * @dev Only callable by owner or guardian
     */
    function setStrategyState(address strategy, StrategyState newState, string calldata reason)
        external;

    /**
     * @notice Batch update strategy states (for emergency response)
     * @param strategies Array of strategy addresses
     * @param newStates Array of new states (must match strategies length)
     * @param reason Common reason for all state changes
     * @dev Only callable by owner or guardian
     */
    function batchSetStrategyState(
        address[] calldata strategies,
        StrategyState[] calldata newStates,
        string calldata reason
    ) external;

    /* ========== EVENTS ========== */

    /**
     * @notice Emitted when strategy state changes
     * @param strategy Address of the strategy
     * @param oldState Previous state
     * @param newState New state
     * @param cachedNAV Current cached NAV value
     * @param reason Explanation for state change
     */
    event StrategyStateChanged(
        address indexed strategy,
        StrategyState oldState,
        StrategyState newState,
        uint256 cachedNAV,
        string reason
    );

    /**
     * @notice Emitted when cached NAV is updated
     * @param strategy Address of the strategy
     * @param oldNAV Previous cached NAV
     * @param newNAV New cached NAV
     */
    event NAVUpdated(address indexed strategy, uint256 oldNAV, uint256 newNAV);
}
