// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IParamsProvider
 * @notice Centralized configuration provider for CoreVault instances (Factory Pattern)
 * @dev Provides both default values and per-vault overrides for all operational parameters
 *
 *      Architecture:
 *      - GlobalConfig implements this interface
 *      - CoreVault reads params via `IParamsProvider public params`
 *      - Supports default + override pattern for multi-vault deployments
 */
interface IParamsProvider {
    /* ========== STRUCTS ========== */

    /// @notice Fee configuration parameters
    struct FeeParams {
        uint16 depositFeeBps; // Deposit fee in basis points (e.g., 10 = 0.1%)
        uint16 withdrawFeeBps; // Withdrawal fee in basis points (e.g., 30 = 0.3%)
        uint256 perfRateX; // Performance fee rate multiplier (e.g., 2e17 = 20%)
        uint64 minCrystallizeInterval; // Min time between perf fee crystalizations
        address treasury; // Fee recipient address
    }

    /// @notice Withdrawal cap and rate limiting parameters
    struct WithdrawalParams {
        uint16 capPerEpochBps; // Max immediate withdrawals per epoch (e.g., 1000 = 10%)
        uint256 maxWithdrawalPerBlock; // Max total withdrawals per block
        uint256 maxWithdrawalPerTx; // Max single transaction withdrawal
        uint256 minClaimAmount; // Minimum claim amount (anti-spam)
        uint64 lockPeriod; // Deposit lock period in seconds
    }

    /// @notice Dynamic withdrawal cap parameters (B5)
    struct DynamicCapParams {
        uint16 minBps; // Min cap when queue stressed (e.g., 200 = 2%)
        uint16 maxBps; // Max cap when queue empty (e.g., 2000 = 20%)
        uint256 queueStressThreshold; // Queue depth triggering min cap
        bool enabled; // Enable dynamic adjustment
    }

    /// @notice Queue anti-spam parameters (A4)
    struct QueueParams {
        uint8 maxClaimsPerUserPerEpoch; // Max claims per user per epoch
        uint64 cooldownPerClaim; // Cooldown between claims (seconds)
        uint64 epochDuration; // Duration of one epoch (seconds)
    }

    /// @notice Circuit breaker and security parameters
    struct SecurityParams {
        uint16 circuitBreakerBps; // Max TVL drop % before auto-pause (e.g., 1000 = 10%)
        uint64 tvlSnapshotInterval; // Interval for TVL snapshots
        address oracle; // Price oracle address
        uint256 oracleStalenessLimit; // Max age for oracle data
    }

    /// @notice Buffer and reserve targets
    struct BufferParams {
        uint16 targetHotBps; // Target hot buffer % (e.g., 300 = 3%)
        uint16 minHotBps; // Minimum hot buffer % (e.g., 200 = 2%)
        uint16 targetWarmBps; // Target warm buffer % (e.g., 700 = 7%)
        uint16 maxWarmBps; // Maximum warm buffer % (e.g., 1000 = 10%)
        uint16 opsReserveTargetBps; // Ops reserve target % (e.g., 100 = 1%)
        uint16 maxWarmSlippageBps; // Max slippage on warm withdraw (e.g., 50 = 0.5%)
    }

    /// @notice Strategy-level risk parameters
    struct StrategyParams {
        uint16 maxStrategyBps; // Max allocation per strategy (e.g., 2000 = 20%)
        uint16 lossCapBps; // Max acceptable loss per strategy (e.g., 100 = 1%)
        uint16 aggregateLossCapBps; // Max total loss across all strategies
        uint256 gasPerStrategyWithdraw; // Gas budget per strategy for batch operations
    }

    /// @notice Batch operation guardrails
    struct BatchGuardrails {
        uint8 maxActionsPerBatch; // Max operations in single batch
        uint16 maxNavDeltaBps; // Max NAV change per batch (e.g., 100 = 1%)
        uint256 maxStaleness; // Max time since last update
    }

    /// @notice Vault deposit limits
    struct DepositLimits {
        uint256 vaultDepositCap; // Max total deposits for vault
        uint256 userDepositCap; // Max deposit per user (0 = unlimited)
        uint256 minDepositAmount; // Min deposit amount in asset units (0 = disabled)
    }

    /// @notice NAV smoothing parameters (for UI/reporting via EMA)
    struct NavSmoothingParams {
        uint16 alphaBps; // EMA weight for real NAV (e.g., 200 = 2%, range: 1-10000)
        uint32 interval; // Min seconds between updates (e.g., 3600 = 1 hour)
        bool enabled; // Enable smoothing (false = totalAssetsSmooth() returns real NAV)
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Get fee parameters for a specific vault
    /// @param vault Address of the vault (address(0) returns defaults)
    /// @return Fee configuration parameters
    function getFeeParams(address vault) external view returns (FeeParams memory);

    /// @notice Get withdrawal parameters for a specific vault
    function getWithdrawalParams(address vault) external view returns (WithdrawalParams memory);

    /// @notice Get dynamic cap parameters for a specific vault
    function getDynamicCapParams(address vault) external view returns (DynamicCapParams memory);

    /// @notice Get queue parameters for a specific vault
    function getQueueParams(address vault) external view returns (QueueParams memory);

    /// @notice Get security parameters for a specific vault
    function getSecurityParams(address vault) external view returns (SecurityParams memory);

    /// @notice Get buffer parameters for a specific vault
    function getBufferParams(address vault) external view returns (BufferParams memory);

    /// @notice Get strategy parameters for a specific vault
    function getStrategyParams(address vault) external view returns (StrategyParams memory);

    /// @notice Get batch guardrails for a specific vault
    function getBatchGuardrails(address vault) external view returns (BatchGuardrails memory);

    /// @notice Get deposit limits for a specific vault
    function getDepositLimits(address vault) external view returns (DepositLimits memory);

    /// @notice Get NAV smoothing parameters for a specific vault
    function getNavSmoothingParams(address vault) external view returns (NavSmoothingParams memory);

    /// @notice Get minimum rebalance cooldown period (in seconds)
    function minRebalanceCooldown() external view returns (uint256);

    /// @notice Get maximum number of actions allowed per batch
    function maxActionsPerBatch() external view returns (uint8);

    /// @notice Get maximum NAV delta in basis points
    function maxNavDeltaBps() external view returns (uint16);

    /// @notice Get maximum staleness allowed for batch operations
    function maxStaleness() external view returns (uint256);

    /// @notice Check if a vault has custom overrides (vs using defaults)
    function hasOverrides(address vault) external view returns (bool);

    /// @notice Version number of this params provider (for factory/versioning)
    function version() external view returns (uint16);

    /* ========== GOVERNANCE-CONFIGURABLE CAPS (formerly hardcoded constants) ========== */

    /// @notice Minimum timelock delay for parameter changes (formerly MIN_PARAM_DELAY = 2 days)
    function minParamDelay(address vault) external view returns (uint64);

    /// @notice Maximum performance fee rate (formerly MAX_PERF_RATE = 5e17 = 50%)
    function maxPerfRate(address vault) external view returns (uint256);

    /// @notice Maximum deposit/withdraw fee in bps (formerly MAX_FEE_BPS = 500 = 5%)
    function maxFeeBps(address vault) external view returns (uint16);

    /// @notice Maximum immediate exit penalty in bps (formerly 200 = 2%)
    function maxImmediateExitPenaltyBps(address vault) external view returns (uint16);

    /// @notice Maximum force exit penalty in bps (formerly 200 = 2%)
    function maxForceExitPenaltyBps(address vault) external view returns (uint16);

    /// @notice Guardian pause cooldown duration (formerly GUARDIAN_PAUSE_COOLDOWN = 7 days)
    function guardianPauseCooldown(address vault) external view returns (uint64);

    /// @notice Minimum deploy amount threshold (formerly MIN_DEPLOY_AMOUNT = 10e6)
    function minDeployAmount(address vault) external view returns (uint256);

    /// @notice Gas cap per strategy totalAssets() call (formerly STRAT_TA_GAS = 1_000_000)
    function stratTaGas(address vault) external view returns (uint256);

    /// @notice Maximum ops share in bps (formerly OPS_MAX_BPS = 3000 = 30%)
    function opsMaxBps(address vault) external view returns (uint16);

    /* ========== ADAPTER & ORACLE POLICY (Existing) ========== */

    /// @notice Check if a strategy adapter is whitelisted
    function isAdapterAllowed(address adapter) external view returns (bool);

    /// @notice Get maximum allocation allowed for a specific adapter
    function adapterCap(address adapter) external view returns (uint256);

    /// @notice Get oracle address for a specific asset
    function oracleFor(address asset) external view returns (address);

    /// @notice Get oracle + staleness config for (asset, vault)
    /// @dev Lookup order: vault override > asset config > default
    /// @param asset The asset address to get oracle for
    /// @param vault The vault address for potential override (address(0) for default)
    /// @return oracle The oracle address
    /// @return maxStaleness Maximum allowed staleness in seconds
    function oracleConfigFor(address asset, address vault)
        external
        view
        returns (address oracle, uint256 maxStaleness);

    /* ========== EVENTS ========== */

    event DefaultFeeParamsUpdated(FeeParams params);
    event DefaultWithdrawalParamsUpdated(WithdrawalParams params);
    event DefaultSecurityParamsUpdated(SecurityParams params);
    event DefaultBufferParamsUpdated(BufferParams params);
    event DefaultStrategyParamsUpdated(StrategyParams params);
    event DefaultNavSmoothingParamsUpdated(NavSmoothingParams params);

    event VaultFeeParamsOverridden(address indexed vault, FeeParams params);
    event VaultWithdrawalParamsOverridden(address indexed vault, WithdrawalParams params);
    event VaultSecurityParamsOverridden(address indexed vault, SecurityParams params);
    event VaultBufferParamsOverridden(address indexed vault, BufferParams params);
    event VaultStrategyParamsOverridden(address indexed vault, StrategyParams params);
    event VaultNavSmoothingParamsOverridden(address indexed vault, NavSmoothingParams params);

    event VaultOverridesCleared(address indexed vault);
}
