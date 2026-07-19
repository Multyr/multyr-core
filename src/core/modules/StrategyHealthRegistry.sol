// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IStrategyHealthRegistry } from "../../interfaces/IStrategyHealthRegistry.sol";

/**
 * @title StrategyHealthRegistry
 * @notice Implementation of centralized strategy health tracking
 * @dev Manages strategy states and cached NAV values for fault tolerance
 *
 * SECURITY:
 * - Owner should be Timelock
 * - Guardian can mark strategies DEGRADED/BROKEN (but not OK)
 * - Authorized callers (vault/router) can update cached NAV
 * - Events emitted for all state changes
 */
contract StrategyHealthRegistry is IStrategyHealthRegistry {
    /* ========== STATE VARIABLES ========== */

    address public owner;
    address public guardian;

    // Authorized callers (vault, router) that can update cached NAV
    mapping(address => bool) public authorizedCallers;

    // Strategy health tracking
    mapping(address => StrategyHealth) private _strategyHealth;

    /* ========== ERRORS ========== */

    error OnlyOwner();
    error OnlyOwnerOrGuardian();
    error OnlyAuthorizedCaller();
    error ArrayLengthMismatch();
    error ZeroAddress();
    error GuardianCannotMarkOK();

    /* ========== MODIFIERS ========== */

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner && msg.sender != guardian) revert OnlyOwnerOrGuardian();
        _;
    }

    modifier onlyAuthorizedCaller() {
        if (!authorizedCallers[msg.sender]) revert OnlyAuthorizedCaller();
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    /**
     * @notice Initialize registry with owner and guardian
     * @param _owner Address of owner (should be Timelock)
     * @param _guardian Address of guardian (can mark strategies unhealthy)
     */
    constructor(address _owner, address _guardian) {
        if (_owner == address(0) || _guardian == address(0)) revert ZeroAddress();
        owner = _owner;
        guardian = _guardian;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @inheritdoc IStrategyHealthRegistry
    function getStrategyState(address strategy) external view override returns (StrategyState) {
        return _strategyHealth[strategy].state;
    }

    /// @inheritdoc IStrategyHealthRegistry
    function getStrategyHealth(address strategy)
        external
        view
        override
        returns (StrategyHealth memory)
    {
        return _strategyHealth[strategy];
    }

    /// @inheritdoc IStrategyHealthRegistry
    function isHealthyForDeposit(address strategy) external view override returns (bool) {
        return _strategyHealth[strategy].state == StrategyState.OK;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /// @inheritdoc IStrategyHealthRegistry
    function updateLastKnownNAV(address strategy, uint256 nav)
        external
        override
        onlyAuthorizedCaller
    {
        StrategyHealth storage health = _strategyHealth[strategy];
        uint256 oldNAV = health.lastKnownNAV;

        health.lastKnownNAV = nav;
        health.lastUpdateTimestamp = uint64(block.timestamp);

        emit NAVUpdated(strategy, oldNAV, nav);
    }

    /// @inheritdoc IStrategyHealthRegistry
    function setStrategyState(address strategy, StrategyState newState, string calldata reason)
        external
        override
        onlyOwnerOrGuardian
    {
        // Guardian can only mark strategies as DEGRADED or BROKEN, not OK
        if (msg.sender == guardian && newState == StrategyState.OK) {
            revert GuardianCannotMarkOK();
        }

        StrategyHealth storage health = _strategyHealth[strategy];
        StrategyState oldState = health.state;

        health.state = newState;
        health.lastUpdateTimestamp = uint64(block.timestamp);
        health.reason = reason;

        emit StrategyStateChanged(strategy, oldState, newState, health.lastKnownNAV, reason);
    }

    /// @inheritdoc IStrategyHealthRegistry
    function batchSetStrategyState(
        address[] calldata strategies,
        StrategyState[] calldata newStates,
        string calldata reason
    ) external override onlyOwnerOrGuardian {
        uint256 len = strategies.length;
        if (len != newStates.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len; i++) {
            // Guardian can only mark strategies as DEGRADED or BROKEN, not OK
            if (msg.sender == guardian && newStates[i] == StrategyState.OK) {
                revert GuardianCannotMarkOK();
            }

            StrategyHealth storage health = _strategyHealth[strategies[i]];
            StrategyState oldState = health.state;

            health.state = newStates[i];
            health.lastUpdateTimestamp = uint64(block.timestamp);
            health.reason = reason;

            emit StrategyStateChanged(
                strategies[i], oldState, newStates[i], health.lastKnownNAV, reason
            );
        }
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /**
     * @notice Set authorized caller (vault or router)
     * @param caller Address to authorize/deauthorize
     * @param authorized True to authorize, false to revoke
     */
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        authorizedCallers[caller] = authorized;
    }

    /**
     * @notice Update guardian address
     * @param newGuardian New guardian address
     */
    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        guardian = newGuardian;
    }

    /**
     * @notice Transfer ownership (two-step recommended via Timelock)
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}
