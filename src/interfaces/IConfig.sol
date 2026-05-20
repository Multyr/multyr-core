// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IConfig
 * @notice External configuration contract for vault parameters
 * @dev All parameters are mutable by timelock without requiring vault upgrades
 *      This enables no-VASP parameter updates for fees, caps, locks, and oracle settings
 */
interface IConfig {
    /* ========== STRUCTS ========== */

    /**
     * @notice Vault-level capacity constraints
     * @param vaultDepositCap Maximum total deposits allowed in the vault (in asset units)
     * @param minRebalanceCooldown Minimum seconds between batch rebalance operations
     */
    struct Caps {
        uint256 vaultDepositCap;
        uint256 minRebalanceCooldown;
    }

    /* ========== EVENTS ========== */

    event FeesUpdated(uint16 depositBps, uint16 withdrawBps, uint16 perfBps);
    event LockPeriodUpdated(uint32 lockPeriod);
    event CapsUpdated(uint256 vaultDepositCap, uint256 minRebalanceCooldown);
    event AdapterCapUpdated(address indexed adapter, uint256 cap);
    event AdapterAllowed(address indexed adapter, bool allowed);
    event OracleSet(address indexed asset, address indexed oracle);
    event LimitsUpdated(uint256 maxStaleness, uint8 maxActionsPerBatch, uint16 maxNavDeltaBps);

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Get current fee parameters
     * @return dBps Deposit fee in basis points (100 = 1%)
     * @return wBps Withdraw fee in basis points (100 = 1%)
     * @return pBps Performance fee in basis points (100 = 1%)
     */
    function fees() external view returns (uint16 dBps, uint16 wBps, uint16 pBps);

    /**
     * @notice Get current lock period for deposits
     * @return Lock period in seconds (users must wait this long before withdrawing after deposit)
     */
    function lockPeriod() external view returns (uint32);

    /**
     * @notice Get vault capacity constraints
     * @return Caps struct with vaultDepositCap and minRebalanceCooldown
     */
    function caps() external view returns (Caps memory);

    /**
     * @notice Get maximum allocation allowed for a specific adapter
     * @param adapter Address of the strategy adapter
     * @return Maximum amount (in asset units) that can be allocated to this adapter
     */
    function adapterCap(address adapter) external view returns (uint256);

    /**
     * @notice Check if an adapter is allowed to be used
     * @param adapter Address of the strategy adapter
     * @return true if adapter is whitelisted, false otherwise
     */
    function isAdapterAllowed(address adapter) external view returns (bool);

    /**
     * @notice Get the oracle address for a specific asset
     * @param asset Address of the asset
     * @return Address of the oracle contract for this asset
     */
    function oracleFor(address asset) external view returns (address);

    /**
     * @notice Get oracle + staleness config for (asset, vault)
     * @dev Lookup order: vault override > asset config > default
     * @param asset The asset address to get oracle for
     * @param vault The vault address for potential override (address(0) for default)
     * @return oracle The oracle address
     * @return maxStaleness Maximum allowed staleness in seconds
     */
    function oracleConfigFor(address asset, address vault)
        external
        view
        returns (address oracle, uint256 maxStaleness);

    /**
     * @notice Get maximum allowed staleness for oracle data
     * @return Maximum seconds since last oracle update before data is considered stale
     */
    function maxStaleness() external view returns (uint256);

    /**
     * @notice Get maximum number of actions allowed in a single batch
     * @return Maximum actions per batch operation
     */
    function maxActionsPerBatch() external view returns (uint8);

    /**
     * @notice Get maximum allowed NAV delta during batch operations
     * @return Maximum NAV change in basis points (100 = 1%)
     */
    function maxNavDeltaBps() external view returns (uint16);

    /* ========== SETTER FUNCTIONS (OnlyTimelock) ========== */

    /**
     * @notice Update fee parameters
     * @dev Only callable by timelock, enforces bounds (e.g., perf fee <= 30%)
     * @param d Deposit fee in basis points
     * @param w Withdraw fee in basis points
     * @param p Performance fee in basis points
     */
    function setFees(uint16 d, uint16 w, uint16 p) external;

    /**
     * @notice Update lock period
     * @dev Only callable by timelock, enforces bounds (e.g., <= 30 days)
     * @param lp Lock period in seconds
     */
    function setLockPeriod(uint32 lp) external;

    /**
     * @notice Update vault capacity constraints
     * @dev Only callable by timelock, enforces vaultDepositCap > 0
     * @param newCaps New capacity constraints
     */
    function setCaps(Caps calldata newCaps) external;

    /**
     * @notice Set maximum allocation for a specific adapter
     * @dev Only callable by timelock
     * @param adapter Address of the strategy adapter
     * @param cap Maximum allocation amount
     */
    function setAdapterCap(address adapter, uint256 cap) external;

    /**
     * @notice Whitelist or blacklist an adapter
     * @dev Only callable by timelock
     * @param adapter Address of the strategy adapter
     * @param allowed true to whitelist, false to blacklist
     */
    function allowAdapter(address adapter, bool allowed) external;

    /**
     * @notice Set oracle for a specific asset
     * @dev Only callable by timelock
     * @param asset Address of the asset
     * @param oracle Address of the oracle contract
     */
    function setOracleFor(address asset, address oracle) external;

    /**
     * @notice Update maximum oracle staleness
     * @dev Only callable by timelock
     * @param secs Maximum seconds since last update
     */
    function setMaxStaleness(uint256 secs) external;

    /**
     * @notice Update maximum actions per batch
     * @dev Only callable by timelock
     * @param max Maximum number of actions
     */
    function setMaxActionsPerBatch(uint8 max) external;

    /**
     * @notice Update maximum NAV delta allowed in batches
     * @dev Only callable by timelock
     * @param bps Maximum delta in basis points
     */
    function setMaxNavDeltaBps(uint16 bps) external;
}
