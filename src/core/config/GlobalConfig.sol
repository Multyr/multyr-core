// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IParamsProvider } from "../../interfaces/IParamsProvider.sol";
import { IPriceOracleMiddleware } from "../../interfaces/IPriceOracleMiddleware.sol";

/**
 * @title GlobalConfig
 * @notice Centralized parameter provider for multiple vaults
 * @dev Implements IParamsProvider (factory pattern) con default e override per-vault.
 */
contract GlobalConfig is IParamsProvider {
    /* ========== ERRORS ========== */
    error NotGovernor();
    error ZeroAddress();
    error InvalidBps();
    error InvalidDelay();
    error InvalidStaleness();
    error InvalidMaxActions();
    error InvalidVersion();

    /* ========== EVENTS ========== */
    event GovernorChanged(address indexed oldGov, address indexed newGov);
    event DefaultFeesUpdated(uint16 depositBps, uint16 withdrawBps, uint16 perfBps);
    event DefaultLockPeriodUpdated(uint64 lockPeriod);
    event DefaultCapUpdated(uint256 vaultDepositCap);
    event DefaultDepositLimitsUpdated(
        uint256 vaultDepositCap,
        uint256 userDepositCap,
        uint256 minDepositAmount
    );
    event DefaultCooldownUpdated(uint256 minRebalanceCooldown);
    event DefaultBatchGuardrailsUpdated(uint8 maxActions, uint16 maxNavDelta);
    event DefaultOracleConfigUpdated(address indexed oracle, uint256 maxStaleness);
    event DefaultAdapterPolicyUpdated(address indexed adapter, bool allowed, uint256 cap);
    event DefaultWithdrawalUpdated(WithdrawalConfig cfg);
    event DefaultDynamicCapUpdated(DynamicCapConfig cfg);
    event DefaultQueueUpdated(QueueConfig cfg);
    event DefaultSecurityUpdated(SecurityConfig cfg);
    event DefaultBufferUpdated(BufferConfig cfg);
    event DefaultStrategyUpdated(StrategyConfig cfg);
    event VersionUpdated(uint16 oldVersion, uint16 newVersion);

    event VaultOverrideSet(address indexed vault, ParamType paramType);
    event VaultOverrideCleared(address indexed vault, ParamType paramType);

    // Oracle registry events (per-asset, per-vault, default)
    event AssetOracleConfigSet(address indexed asset, address indexed oracle, uint256 maxStaleness);
    event VaultOracleOverrideSet(
        address indexed vault, address indexed oracle, uint256 maxStaleness
    );
    event DefaultOracleConfigSet(address indexed oracle, uint256 maxStaleness);

    /* ========== ENUMS ========== */
    enum ParamType {
        FEES,
        LOCK_PERIOD,
        VAULT_CAP,
        COOLDOWN,
        BATCH_GUARDRAILS,
        ORACLE_CONFIG,
        ADAPTER_POLICY,
        WITHDRAWAL,
        DYNAMIC_CAP,
        QUEUE,
        SECURITY,
        BUFFER,
        STRATEGY,
        NAV_SMOOTHING,
        // Governance-configurable caps (P2-P10)
        GOV_CAPS
    }

    /* ========== STRUCTS ========== */
    struct FeeConfig {
        uint16 depositBps;
        uint16 withdrawBps;
        uint16 perfBps;
        uint256 perfRateX; // Performance fee rate multiplier (e.g., 2e17 = 20%)
        uint64 minCrystallizeInterval; // Min time between perf fee crystalizations
        address treasury; // Fee recipient address
    }

    struct WithdrawalConfig {
        uint16 capPerEpochBps; // Max immediate withdrawals per epoch
        uint256 maxWithdrawalPerBlock; // Max total withdrawals per block
        uint256 maxWithdrawalPerTx; // Max single transaction withdrawal
        uint256 minClaimAmount; // Minimum claim amount (anti-spam)
        uint64 lockPeriod; // Deposit lock period in seconds
    }

    struct DynamicCapConfig {
        uint16 minBps; // Min cap when queue stressed
        uint16 maxBps; // Max cap when queue empty
        uint256 queueStressThreshold; // Queue depth triggering min cap
        bool enabled; // Enable dynamic adjustment
    }

    struct QueueConfig {
        uint8 maxClaimsPerUserPerEpoch; // Max claims per user per epoch
        uint64 cooldownPerClaim; // Cooldown between claims (seconds)
        uint64 epochDuration; // Duration of one epoch (seconds)
    }

    struct SecurityConfig {
        uint16 circuitBreakerBps; // Max TVL drop % before auto-pause
        uint64 tvlSnapshotInterval; // Interval for TVL snapshots
        address oracle; // Price oracle
        uint256 oracleStalenessLimit; // Max age for oracle data
    }

    struct BufferConfig {
        uint16 targetHotBps; // Target hot buffer %
        uint16 minHotBps; // Minimum hot buffer %
        uint16 targetWarmBps; // Target warm buffer %
        uint16 maxWarmBps; // Maximum warm buffer %
        uint16 opsReserveTargetBps; // Ops reserve target %
        uint16 maxWarmSlippageBps; // Max slippage on warm withdraw
    }

    struct StrategyConfig {
        uint16 maxStrategyBps; // Max allocation per strategy
        uint16 lossCapBps; // Max acceptable loss per strategy
        uint16 aggregateLossCapBps; // Max total loss across all strategies
        uint256 gasPerStrategyWithdraw; // Gas budget per strategy for batch operations
    }

    struct NavSmoothingConfig {
        uint16 alphaBps; // EMA weight for real NAV (e.g., 200 = 2%)
        uint32 interval; // Min seconds between updates (e.g., 3600)
        bool enabled; // Enable smoothing
    }

    struct OracleConfig {
        IPriceOracleMiddleware oracle;
        uint256 maxStaleness;
    }

    struct AdapterPolicy {
        mapping(address => bool) allowlist;
        mapping(address => uint256) caps;
    }

    /* ========== STATE VARIABLES ========== */

    // Governance
    address public governor;
    uint16 public override version;

    // Default parameters (apply to all vaults unless overridden)
    FeeConfig public defaultFees;
    WithdrawalConfig public defaultWithdrawal;
    DynamicCapConfig public defaultDynamicCap;
    QueueConfig public defaultQueue;
    SecurityConfig public defaultSecurity;
    BufferConfig public defaultBuffer;
    StrategyConfig public defaultStrategy;
    NavSmoothingConfig public defaultNavSmoothing;
    uint64 public defaultLockPeriod;
    uint256 public defaultVaultDepositCap;
    uint256 public defaultUserDepositCap;
    uint256 public defaultMinDepositAmount;
    uint256 public defaultMinRebalanceCooldown;
    IParamsProvider.BatchGuardrails public defaultBatchGuardrails;
    OracleConfig public defaultOracleConfig;
    AdapterPolicy internal defaultAdapterPolicy;

    // Governance-configurable caps (formerly hardcoded constants)
    uint64 public defaultMinParamDelay = 2 days;              // P2: AdminModule MIN_PARAM_DELAY
    uint256 public defaultMaxPerfRate = 5e17;                 // P3: AdminModule MAX_PERF_RATE (50%)
    uint16 public defaultMaxFeeBps = 500;                     // P4: AdminModule MAX_FEE_BPS (5%)
    uint16 public defaultMaxImmediateExitPenaltyBps = 200;    // P5: AdminModule (2%)
    uint16 public defaultMaxForceExitPenaltyBps = 200;        // P6: AdminModule (2%)
    uint64 public defaultGuardianPauseCooldown = 7 days;      // P7: CoreVault
    uint256 public defaultMinDeployAmount = 10e6;             // P8: LiquidityOpsModule (10 USDC)
    uint256 public defaultStratTaGas = 1_000_000;             // P9: StrategyRouter
    uint16 public defaultOpsMaxBps = 3000;                    // P10: FeeCollector (30%)

    // Per-vault overrides (optional)
    mapping(address => FeeConfig) public vaultFeeOverrides;
    mapping(address => WithdrawalConfig) public vaultWithdrawalOverrides;
    mapping(address => DynamicCapConfig) public vaultDynamicCapOverrides;
    mapping(address => QueueConfig) public vaultQueueOverrides;
    mapping(address => SecurityConfig) public vaultSecurityOverrides;
    mapping(address => BufferConfig) public vaultBufferOverrides;
    mapping(address => StrategyConfig) public vaultStrategyOverrides;
    mapping(address => NavSmoothingConfig) public vaultNavSmoothingOverrides;
    mapping(address => uint64) public vaultLockOverrides; // legacy
    mapping(address => uint256) public vaultCapOverrides; // legacy
    mapping(address => uint256) public vaultUserCapOverrides;
    mapping(address => uint256) public vaultMinDepositOverrides;
    mapping(address => uint256) public vaultCooldownOverrides; // legacy
    mapping(address => IParamsProvider.BatchGuardrails) public vaultBatchOverrides;
    mapping(address => OracleConfig) public vaultOracleOverrides;
    mapping(address => AdapterPolicy) internal vaultAdapterOverrides;

    // Per-vault overrides for governance caps
    mapping(address => uint64) public vaultMinParamDelayOverrides;
    mapping(address => uint256) public vaultMaxPerfRateOverrides;
    mapping(address => uint16) public vaultMaxFeeBpsOverrides;
    mapping(address => uint16) public vaultMaxImmExitPenaltyOverrides;
    mapping(address => uint16) public vaultMaxForceExitPenaltyOverrides;
    mapping(address => uint64) public vaultGuardianPauseCooldownOverrides;
    mapping(address => uint256) public vaultMinDeployAmountOverrides;
    mapping(address => uint256) public vaultStratTaGasOverrides;
    mapping(address => uint16) public vaultOpsMaxBpsOverrides;

    // Per-asset oracle configuration (e.g., USDC -> Chainlink USDC/USD)
    mapping(address => OracleConfig) public assetOracleConfig;

    // Override flags (track which vaults have overrides)
    mapping(address => mapping(ParamType => bool)) public hasOverride;

    /* ========== MODIFIERS ========== */
    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    /* ========== CONSTRUCTOR ========== */
    constructor(
        address _governor,
        uint16 _depositBps,
        uint16 _withdrawBps,
        uint16 _perfBps,
        uint64 _lockPeriod,
        uint8 _maxActions,
        uint16 _maxNavDelta,
        uint256 _cooldown,
        uint256 _staleness
    ) {
        if (_governor == address(0)) revert ZeroAddress();
        if (_depositBps > 10000 || _withdrawBps > 10000 || _perfBps > 10000) revert InvalidBps();
        if (_maxActions == 0 || _maxActions > 100) revert InvalidMaxActions();
        if (_maxNavDelta > 10000) revert InvalidBps();
        if (_cooldown == 0) revert InvalidDelay();
        if (_staleness < 1 minutes || _staleness > 1 days) revert InvalidStaleness();

        governor = _governor;
        version = 1;
        emit VersionUpdated(0, version);

        // Set default fees
        defaultFees = FeeConfig({
            depositBps: _depositBps,
            withdrawBps: _withdrawBps,
            perfBps: _perfBps,
            perfRateX: 2e17, // 20%
            minCrystallizeInterval: 7 days,
            treasury: _governor
        });

        // Set default withdrawal params
        defaultWithdrawal = WithdrawalConfig({
            capPerEpochBps: 1000, // 10%
            maxWithdrawalPerBlock: 0,
            maxWithdrawalPerTx: 0,
            minClaimAmount: 100e6, // 100 USDC
            lockPeriod: _lockPeriod
        });

        // Set default dynamic cap params
        defaultDynamicCap = DynamicCapConfig({
            minBps: 200, // 2%
            maxBps: 2000, // 20%
            queueStressThreshold: 100,
            enabled: false
        });

        // Set default queue params
        defaultQueue = QueueConfig({
            maxClaimsPerUserPerEpoch: 10, cooldownPerClaim: 1 hours, epochDuration: 7 days
        });

        // Set default security params
        defaultSecurity = SecurityConfig({
            circuitBreakerBps: 1000, // 10%
            tvlSnapshotInterval: 1 hours,
            oracle: address(0),
            oracleStalenessLimit: _staleness
        });

        // Set default buffer params
        defaultBuffer = BufferConfig({
            targetHotBps: 300, // 3%
            minHotBps: 200, // 2%
            targetWarmBps: 700, // 7%
            maxWarmBps: 1000, // 10%
            opsReserveTargetBps: 100, // 1%
            maxWarmSlippageBps: 50 // 0.5%
        });

        // Set default strategy params
        defaultStrategy = StrategyConfig({
            maxStrategyBps: 2000, // 20%
            lossCapBps: 100, // 1%
            aggregateLossCapBps: 500, // 5%
            gasPerStrategyWithdraw: 100000
        });

        // Set default NAV smoothing params
        defaultNavSmoothing = NavSmoothingConfig({
            alphaBps: 200, // 2% weight to new NAV (slow smoothing)
            interval: 3600, // 1 hour between updates
            enabled: true // Enabled by default
        });

        // Set default params
        defaultLockPeriod = _lockPeriod;
        defaultVaultDepositCap    = 10_000_000e6; // 10M USDC
        defaultUserDepositCap     =    500_000e6; // 500K USDC per user
        defaultMinDepositAmount   =        100e6; // 100 USDC minimum
        defaultMinRebalanceCooldown = _cooldown;

        // Set default batch guardrails
        defaultBatchGuardrails = IParamsProvider.BatchGuardrails({
            maxActionsPerBatch: _maxActions, maxNavDeltaBps: _maxNavDelta, maxStaleness: _staleness
        });

        // Set default oracle config
        defaultOracleConfig = OracleConfig({
            oracle: IPriceOracleMiddleware(address(0)), // Can be set later
            maxStaleness: _staleness
        });

        emit GovernorChanged(address(0), _governor);
    }

    /* ========== GOVERNANCE FUNCTIONS ========== */

    /// @notice Bump config version to distinguish generations (e.g., v1 -> v2)
    function bumpVersion(uint16 newVersion) external onlyGovernor {
        if (newVersion <= version) revert InvalidVersion();
        emit VersionUpdated(version, newVersion);
        version = newVersion;
    }

    function setGovernor(address newGovernor) external onlyGovernor {
        if (newGovernor == address(0)) revert ZeroAddress();
        emit GovernorChanged(governor, newGovernor);
        governor = newGovernor;
    }

    /* ========== DEFAULT PARAMS SETTERS ========== */

    /// @notice Set default fees for all vaults (without overrides)
    function setDefaultFees(uint16 depositBps, uint16 withdrawBps, uint16 perfBps)
        external
        onlyGovernor
    {
        if (depositBps > 10000 || withdrawBps > 10000 || perfBps > 10000) {
            revert InvalidBps();
        }
        FeeConfig memory f = defaultFees;
        f.depositBps = depositBps;
        f.withdrawBps = withdrawBps;
        f.perfBps = perfBps;
        defaultFees = f;
        emit DefaultFeesUpdated(depositBps, withdrawBps, perfBps);
    }

    function setDefaultLockPeriod(uint64 lockPeriod) external onlyGovernor {
        defaultLockPeriod = lockPeriod;
        emit DefaultLockPeriodUpdated(lockPeriod);
    }

    function setDefaultVaultDepositCap(uint256 cap) external onlyGovernor {
        defaultVaultDepositCap = cap;
        emit DefaultCapUpdated(cap);
    }

    function setDefaultDepositLimits(
        uint256 vaultDepositCap,
        uint256 userDepositCap,
        uint256 minDepositAmount
    ) external onlyGovernor {
        defaultVaultDepositCap = vaultDepositCap;
        defaultUserDepositCap = userDepositCap;
        defaultMinDepositAmount = minDepositAmount;
        emit DefaultDepositLimitsUpdated(vaultDepositCap, userDepositCap, minDepositAmount);
    }

    function setVaultDepositLimits(
        address vault,
        uint256 vaultDepositCap,
        uint256 userDepositCap,
        uint256 minDepositAmount
    ) external onlyGovernor {
        if (vault == address(0)) revert ZeroAddress();
        vaultCapOverrides[vault] = vaultDepositCap;
        vaultUserCapOverrides[vault] = userDepositCap;
        vaultMinDepositOverrides[vault] = minDepositAmount;
        hasOverride[vault][ParamType.VAULT_CAP] = true;
        emit VaultOverrideSet(vault, ParamType.VAULT_CAP);
    }

    function setDefaultMinRebalanceCooldown(uint256 cooldown) external onlyGovernor {
        if (cooldown == 0) revert InvalidDelay();
        defaultMinRebalanceCooldown = cooldown;
        emit DefaultCooldownUpdated(cooldown);
    }

    function setDefaultBatchGuardrails(uint8 maxActions, uint16 maxNavDelta, uint256 maxStaleness_)
        external
        onlyGovernor
    {
        if (maxActions == 0 || maxActions > 100) revert InvalidMaxActions();
        if (maxNavDelta > 10000) revert InvalidBps();
        defaultBatchGuardrails.maxActionsPerBatch = maxActions;
        defaultBatchGuardrails.maxNavDeltaBps = maxNavDelta;
        defaultBatchGuardrails.maxStaleness = maxStaleness_;
        emit DefaultBatchGuardrailsUpdated(maxActions, maxNavDelta);
    }

    function setDefaultOracleConfig(address oracle, uint256 maxStaleness_) external onlyGovernor {
        if (oracle == address(0)) revert ZeroAddress();
        if (maxStaleness_ < 1 minutes || maxStaleness_ > 1 days) revert InvalidStaleness();
        defaultOracleConfig = OracleConfig(IPriceOracleMiddleware(oracle), maxStaleness_);
        emit DefaultOracleConfigUpdated(oracle, maxStaleness_);
        emit DefaultOracleConfigSet(oracle, maxStaleness_);
    }

    /// @notice Set oracle configuration for a specific asset
    /// @dev Used to configure per-asset oracles (e.g., USDC -> Chainlink USDC/USD)
    /// @param asset Address of the asset
    /// @param oracle Address of the price oracle middleware
    /// @param maxStaleness_ Maximum allowed staleness in seconds
    function setAssetOracleConfig(address asset, address oracle, uint256 maxStaleness_)
        external
        onlyGovernor
    {
        if (asset == address(0)) revert ZeroAddress();
        if (oracle == address(0)) revert ZeroAddress();
        if (maxStaleness_ < 1 minutes || maxStaleness_ > 1 days) revert InvalidStaleness();
        assetOracleConfig[asset] = OracleConfig(IPriceOracleMiddleware(oracle), maxStaleness_);
        emit AssetOracleConfigSet(asset, oracle, maxStaleness_);
    }

    function setDefaultAdapterAllowed(address adapter, bool allowed) external onlyGovernor {
        if (adapter == address(0)) revert ZeroAddress();
        defaultAdapterPolicy.allowlist[adapter] = allowed;
        emit DefaultAdapterPolicyUpdated(adapter, allowed, defaultAdapterPolicy.caps[adapter]);
    }

    function setDefaultAdapterCap(address adapter, uint256 cap) external onlyGovernor {
        if (adapter == address(0)) revert ZeroAddress();
        defaultAdapterPolicy.caps[adapter] = cap;
        emit DefaultAdapterPolicyUpdated(adapter, defaultAdapterPolicy.allowlist[adapter], cap);
    }

    function setDefaultNavSmoothing(uint16 _alphaBps, uint32 _interval, bool _enabled)
        external
        onlyGovernor
    {
        if (_alphaBps == 0 || _alphaBps > 10000) revert InvalidBps();
        defaultNavSmoothing =
            NavSmoothingConfig({ alphaBps: _alphaBps, interval: _interval, enabled: _enabled });
        emit DefaultNavSmoothingParamsUpdated(IParamsProvider.NavSmoothingParams({
                alphaBps: _alphaBps, interval: _interval, enabled: _enabled
            }));
    }

    /* ========== PER-VAULT OVERRIDE SETTERS ========== */

    /// @notice Set vault-specific fee override
    function setVaultFeeOverride(
        address vault,
        uint16 depositBps,
        uint16 withdrawBps,
        uint16 perfBps
    ) external onlyGovernor {
        if (vault == address(0)) revert ZeroAddress();
        if (depositBps > 10000 || withdrawBps > 10000 || perfBps > 10000) revert InvalidBps();

        vaultFeeOverrides[vault] = FeeConfig({
            depositBps: depositBps,
            withdrawBps: withdrawBps,
            perfBps: perfBps,
            perfRateX: defaultFees.perfRateX,
            minCrystallizeInterval: defaultFees.minCrystallizeInterval,
            treasury: defaultFees.treasury
        });
        hasOverride[vault][ParamType.FEES] = true;
        emit VaultOverrideSet(vault, ParamType.FEES);
    }

    function setVaultBatchOverride(
        address vault,
        uint8 maxActions,
        uint16 maxNavDelta,
        uint256 maxStaleness_
    ) external onlyGovernor {
        if (vault == address(0)) revert ZeroAddress();
        if (maxActions == 0 || maxActions > 100) revert InvalidMaxActions();
        if (maxNavDelta > 10000) revert InvalidBps();
        vaultBatchOverrides[vault].maxActionsPerBatch = maxActions;
        vaultBatchOverrides[vault].maxNavDeltaBps = maxNavDelta;
        vaultBatchOverrides[vault].maxStaleness = maxStaleness_;
        hasOverride[vault][ParamType.BATCH_GUARDRAILS] = true;
        emit VaultOverrideSet(vault, ParamType.BATCH_GUARDRAILS);
    }

    function setVaultOracleOverride(address vault, address oracle, uint256 maxStaleness_)
        external
        onlyGovernor
    {
        if (vault == address(0)) revert ZeroAddress();
        if (oracle == address(0)) revert ZeroAddress();
        if (maxStaleness_ < 1 minutes || maxStaleness_ > 1 days) revert InvalidStaleness();
        vaultOracleOverrides[vault] = OracleConfig(IPriceOracleMiddleware(oracle), maxStaleness_);
        hasOverride[vault][ParamType.ORACLE_CONFIG] = true;
        emit VaultOverrideSet(vault, ParamType.ORACLE_CONFIG);
        emit VaultOracleOverrideSet(vault, oracle, maxStaleness_);
    }

    function setVaultAdapterOverride(address vault, address adapter, bool allowed, uint256 cap)
        external
        onlyGovernor
    {
        if (vault == address(0) || adapter == address(0)) revert ZeroAddress();
        vaultAdapterOverrides[vault].allowlist[adapter] = allowed;
        vaultAdapterOverrides[vault].caps[adapter] = cap;
        hasOverride[vault][ParamType.ADAPTER_POLICY] = true;
        emit VaultOverrideSet(vault, ParamType.ADAPTER_POLICY);
    }

    function setVaultNavSmoothingOverride(
        address vault,
        uint16 _alphaBps,
        uint32 _interval,
        bool _enabled
    ) external onlyGovernor {
        if (vault == address(0)) revert ZeroAddress();
        if (_alphaBps == 0 || _alphaBps > 10000) revert InvalidBps();
        vaultNavSmoothingOverrides[vault] =
            NavSmoothingConfig({ alphaBps: _alphaBps, interval: _interval, enabled: _enabled });
        hasOverride[vault][ParamType.NAV_SMOOTHING] = true;
        emit VaultNavSmoothingParamsOverridden(
            vault,
            IParamsProvider.NavSmoothingParams({
                alphaBps: _alphaBps, interval: _interval, enabled: _enabled
            })
        );
    }

    /* ========== CLEAR OVERRIDES ========== */

    function clearVaultOverride(address vault, ParamType paramType) external onlyGovernor {
        // For ORACLE_CONFIG, delete the stored override to prevent stale data
        if (paramType == ParamType.ORACLE_CONFIG) {
            delete vaultOracleOverrides[vault];
        }
        hasOverride[vault][paramType] = false;
        emit VaultOverrideCleared(vault, paramType);
    }

    /* ========== IPARAMSPROVIDER IMPLEMENTATION ========== */

    /// @notice Get fee parameters for a vault (checks override first, then default)
    /* ========== IPARAMSPROVIDER METHODS (FACTORY PATTERN) ========== */

    function getFeeParams(address vault) external view returns (IParamsProvider.FeeParams memory) {
        // Note: IParamsProvider uses external queries with vault address
        // Convert internal FeeConfig to IParamsProvider.FeeParams format
        FeeConfig memory cfg =
            hasOverride[vault][ParamType.FEES] ? vaultFeeOverrides[vault] : defaultFees;

        return IParamsProvider.FeeParams({
            depositFeeBps: cfg.depositBps,
            withdrawFeeBps: cfg.withdrawBps,
            perfRateX: cfg.perfRateX,
            minCrystallizeInterval: cfg.minCrystallizeInterval,
            treasury: cfg.treasury
        });
    }

    function getWithdrawalParams(address vault)
        external
        view
        returns (IParamsProvider.WithdrawalParams memory)
    {
        WithdrawalConfig memory cfg = hasOverride[vault][ParamType.WITHDRAWAL]
            ? vaultWithdrawalOverrides[vault]
            : defaultWithdrawal;
        return IParamsProvider.WithdrawalParams({
            capPerEpochBps: cfg.capPerEpochBps,
            maxWithdrawalPerBlock: cfg.maxWithdrawalPerBlock,
            maxWithdrawalPerTx: cfg.maxWithdrawalPerTx,
            minClaimAmount: cfg.minClaimAmount,
            lockPeriod: cfg.lockPeriod
        });
    }

    function getDynamicCapParams(address vault)
        external
        view
        returns (IParamsProvider.DynamicCapParams memory)
    {
        DynamicCapConfig memory cfg = hasOverride[vault][ParamType.DYNAMIC_CAP]
            ? vaultDynamicCapOverrides[vault]
            : defaultDynamicCap;
        return IParamsProvider.DynamicCapParams({
            minBps: cfg.minBps,
            maxBps: cfg.maxBps,
            queueStressThreshold: cfg.queueStressThreshold,
            enabled: cfg.enabled
        });
    }

    function getQueueParams(address vault)
        external
        view
        returns (IParamsProvider.QueueParams memory)
    {
        QueueConfig memory cfg =
            hasOverride[vault][ParamType.QUEUE] ? vaultQueueOverrides[vault] : defaultQueue;
        return IParamsProvider.QueueParams({
            maxClaimsPerUserPerEpoch: cfg.maxClaimsPerUserPerEpoch,
            cooldownPerClaim: cfg.cooldownPerClaim,
            epochDuration: cfg.epochDuration
        });
    }

    function getSecurityParams(address vault)
        external
        view
        returns (IParamsProvider.SecurityParams memory)
    {
        SecurityConfig memory cfg = hasOverride[vault][ParamType.SECURITY]
            ? vaultSecurityOverrides[vault]
            : defaultSecurity;
        address oracle = cfg.oracle;
        uint256 staleness = cfg.oracleStalenessLimit;
        if (hasOverride[vault][ParamType.ORACLE_CONFIG]) {
            oracle = address(vaultOracleOverrides[vault].oracle);
            staleness = vaultOracleOverrides[vault].maxStaleness;
        }
        return IParamsProvider.SecurityParams({
            circuitBreakerBps: cfg.circuitBreakerBps,
            tvlSnapshotInterval: cfg.tvlSnapshotInterval,
            oracle: oracle,
            oracleStalenessLimit: staleness
        });
    }

    function getBufferParams(address vault)
        external
        view
        returns (IParamsProvider.BufferParams memory)
    {
        BufferConfig memory cfg =
            hasOverride[vault][ParamType.BUFFER] ? vaultBufferOverrides[vault] : defaultBuffer;
        return IParamsProvider.BufferParams({
            targetHotBps: cfg.targetHotBps,
            minHotBps: cfg.minHotBps,
            targetWarmBps: cfg.targetWarmBps,
            maxWarmBps: cfg.maxWarmBps,
            opsReserveTargetBps: cfg.opsReserveTargetBps,
            maxWarmSlippageBps: cfg.maxWarmSlippageBps
        });
    }

    function getStrategyParams(address vault)
        external
        view
        returns (IParamsProvider.StrategyParams memory)
    {
        StrategyConfig memory cfg = hasOverride[vault][ParamType.STRATEGY]
            ? vaultStrategyOverrides[vault]
            : defaultStrategy;
        return IParamsProvider.StrategyParams({
            maxStrategyBps: cfg.maxStrategyBps,
            lossCapBps: cfg.lossCapBps,
            aggregateLossCapBps: cfg.aggregateLossCapBps,
            gasPerStrategyWithdraw: cfg.gasPerStrategyWithdraw
        });
    }

    function getBatchGuardrails(address vault)
        external
        view
        returns (IParamsProvider.BatchGuardrails memory)
    {
        IParamsProvider.BatchGuardrails memory cfg = hasOverride[vault][ParamType.BATCH_GUARDRAILS]
            ? vaultBatchOverrides[vault]
            : defaultBatchGuardrails;
        return cfg;
    }

    function getDepositLimits(address vault)
        external
        view
        returns (IParamsProvider.DepositLimits memory)
    {
        bool overridden = hasOverride[vault][ParamType.VAULT_CAP];
        return IParamsProvider.DepositLimits({
            vaultDepositCap: overridden ? vaultCapOverrides[vault] : defaultVaultDepositCap,
            userDepositCap: overridden ? vaultUserCapOverrides[vault] : defaultUserDepositCap,
            minDepositAmount: overridden ? vaultMinDepositOverrides[vault] : defaultMinDepositAmount
        });
    }

    function getNavSmoothingParams(address vault)
        external
        view
        returns (IParamsProvider.NavSmoothingParams memory)
    {
        NavSmoothingConfig memory cfg = hasOverride[vault][ParamType.NAV_SMOOTHING]
            ? vaultNavSmoothingOverrides[vault]
            : defaultNavSmoothing;
        return IParamsProvider.NavSmoothingParams({
            alphaBps: cfg.alphaBps, interval: cfg.interval, enabled: cfg.enabled
        });
    }

    function minRebalanceCooldown() external view returns (uint256) {
        return defaultMinRebalanceCooldown;
    }

    function maxActionsPerBatch() external view returns (uint8) {
        return defaultBatchGuardrails.maxActionsPerBatch;
    }

    function maxNavDeltaBps() external view returns (uint16) {
        return defaultBatchGuardrails.maxNavDeltaBps;
    }

    function maxStaleness() external view returns (uint256) {
        return defaultBatchGuardrails.maxStaleness;
    }

    function hasOverrides(address vault) external view returns (bool) {
        return hasOverride[vault][ParamType.FEES] || hasOverride[vault][ParamType.LOCK_PERIOD]
            || hasOverride[vault][ParamType.VAULT_CAP] || hasOverride[vault][ParamType.COOLDOWN]
            || hasOverride[vault][ParamType.BATCH_GUARDRAILS]
            || hasOverride[vault][ParamType.ORACLE_CONFIG]
            || hasOverride[vault][ParamType.ADAPTER_POLICY]
            || hasOverride[vault][ParamType.WITHDRAWAL] || hasOverride[vault][ParamType.DYNAMIC_CAP]
            || hasOverride[vault][ParamType.QUEUE] || hasOverride[vault][ParamType.SECURITY]
            || hasOverride[vault][ParamType.BUFFER] || hasOverride[vault][ParamType.STRATEGY]
            || hasOverride[vault][ParamType.NAV_SMOOTHING]
            || hasOverride[vault][ParamType.GOV_CAPS];
    }

    /* ========== VIEW FUNCTIONS (FOR EXTERNAL QUERIES) ========== */

    // Legacy helpers retained for compatibility
    function getVaultFees(address vault)
        external
        view
        returns (uint16 dBps, uint16 wBps, uint16 pBps)
    {
        if (hasOverride[vault][ParamType.FEES]) {
            FeeConfig memory override_ = vaultFeeOverrides[vault];
            return (override_.depositBps, override_.withdrawBps, override_.perfBps);
        }
        return (defaultFees.depositBps, defaultFees.withdrawBps, defaultFees.perfBps);
    }

    function getVaultLockPeriod(address vault) external view returns (uint64) {
        return hasOverride[vault][ParamType.LOCK_PERIOD]
            ? vaultLockOverrides[vault]
            : defaultWithdrawal.lockPeriod;
    }

    function getVaultDepositCap(address vault) external view returns (uint256) {
        return
            hasOverride[vault][ParamType.VAULT_CAP]
                ? vaultCapOverrides[vault]
                : defaultVaultDepositCap;
    }

    /// @notice Check if adapter is allowed
    function isAdapterAllowed(
        address /* adapter */
    )
        external
        pure
        returns (bool)
    {
        return true; // All adapters allowed by default
    }

    /// @notice Get adapter cap
    function adapterCap(
        address /* adapter */
    )
        external
        pure
        returns (uint256)
    {
        return type(uint256).max; // No cap by default
    }

    /// @notice Get oracle for asset
    /// @dev Lookup order: asset config > default config
    /// @param asset Address of the asset
    /// @return oracle Address of the price oracle (or address(0) if not configured)
    function oracleFor(address asset) external view returns (address) {
        // Check asset-specific config first
        OracleConfig memory assetCfg = assetOracleConfig[asset];
        if (address(assetCfg.oracle) != address(0)) {
            return address(assetCfg.oracle);
        }
        // Fall back to default oracle config
        return address(defaultOracleConfig.oracle);
    }

    /// @notice Get oracle + staleness config for (asset, vault)
    /// @dev Lookup order: vault override > asset config > default
    /// @param asset The asset address to get oracle for
    /// @param vault The vault address for potential override (address(0) for default)
    /// @return oracle The oracle address
    /// @return maxStaleness_ Maximum allowed staleness in seconds
    function oracleConfigFor(address asset, address vault)
        external
        view
        returns (address oracle, uint256 maxStaleness_)
    {
        // 1. Check vault-specific override first
        if (vault != address(0) && hasOverride[vault][ParamType.ORACLE_CONFIG]) {
            OracleConfig memory vaultCfg = vaultOracleOverrides[vault];
            return (address(vaultCfg.oracle), vaultCfg.maxStaleness);
        }

        // 2. Check asset-specific config
        OracleConfig memory assetCfg = assetOracleConfig[asset];
        if (address(assetCfg.oracle) != address(0)) {
            return (address(assetCfg.oracle), assetCfg.maxStaleness);
        }

        // 3. Fall back to default oracle config
        return (address(defaultOracleConfig.oracle), defaultOracleConfig.maxStaleness);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GOVERNANCE-CONFIGURABLE CAPS — Getters (default + per-vault override)
    // ═══════════════════════════════════════════════════════════════════════════

    function minParamDelay(address vault) external view returns (uint64) {
        return hasOverride[vault][ParamType.GOV_CAPS] ? vaultMinParamDelayOverrides[vault] : defaultMinParamDelay;
    }

    function maxPerfRate(address vault) external view returns (uint256) {
        return hasOverride[vault][ParamType.GOV_CAPS] ? vaultMaxPerfRateOverrides[vault] : defaultMaxPerfRate;
    }

    function maxFeeBps(address vault) external view returns (uint16) {
        return hasOverride[vault][ParamType.GOV_CAPS] ? vaultMaxFeeBpsOverrides[vault] : defaultMaxFeeBps;
    }

    function maxImmediateExitPenaltyBps(address vault) external view returns (uint16) {
        return hasOverride[vault][ParamType.GOV_CAPS]
            ? vaultMaxImmExitPenaltyOverrides[vault]
            : defaultMaxImmediateExitPenaltyBps;
    }

    function maxForceExitPenaltyBps(address vault) external view returns (uint16) {
        return hasOverride[vault][ParamType.GOV_CAPS]
            ? vaultMaxForceExitPenaltyOverrides[vault]
            : defaultMaxForceExitPenaltyBps;
    }

    function guardianPauseCooldown(address vault) external view returns (uint64) {
        return hasOverride[vault][ParamType.GOV_CAPS]
            ? vaultGuardianPauseCooldownOverrides[vault]
            : defaultGuardianPauseCooldown;
    }

    function minDeployAmount(address vault) external view returns (uint256) {
        return hasOverride[vault][ParamType.GOV_CAPS]
            ? vaultMinDeployAmountOverrides[vault]
            : defaultMinDeployAmount;
    }

    function stratTaGas(address vault) external view returns (uint256) {
        return hasOverride[vault][ParamType.GOV_CAPS] ? vaultStratTaGasOverrides[vault] : defaultStratTaGas;
    }

    function opsMaxBps(address vault) external view returns (uint16) {
        return hasOverride[vault][ParamType.GOV_CAPS] ? vaultOpsMaxBpsOverrides[vault] : defaultOpsMaxBps;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GOVERNANCE-CONFIGURABLE CAPS — Setters (defaults)
    // ═══════════════════════════════════════════════════════════════════════════

    event DefaultGovCapsUpdated(
        uint64 minParamDelay, uint256 maxPerfRate, uint16 maxFeeBps,
        uint16 maxImmExitBps, uint16 maxForceExitBps, uint64 guardianPauseCooldown,
        uint256 minDeployAmount, uint256 stratTaGas, uint16 opsMaxBps
    );

    function setDefaultGovCaps(
        uint64 _minParamDelay,
        uint256 _maxPerfRate,
        uint16 _maxFeeBps,
        uint16 _maxImmExitBps,
        uint16 _maxForceExitBps,
        uint64 _guardianPauseCooldown,
        uint256 _minDeployAmount,
        uint256 _stratTaGas,
        uint16 _opsMaxBps
    ) external onlyGovernor {
        if (_maxFeeBps > 10000) revert InvalidBps();
        if (_maxImmExitBps > 10000) revert InvalidBps();
        if (_maxForceExitBps > 10000) revert InvalidBps();
        if (_opsMaxBps > 10000) revert InvalidBps();

        defaultMinParamDelay = _minParamDelay;
        defaultMaxPerfRate = _maxPerfRate;
        defaultMaxFeeBps = _maxFeeBps;
        defaultMaxImmediateExitPenaltyBps = _maxImmExitBps;
        defaultMaxForceExitPenaltyBps = _maxForceExitBps;
        defaultGuardianPauseCooldown = _guardianPauseCooldown;
        defaultMinDeployAmount = _minDeployAmount;
        defaultStratTaGas = _stratTaGas;
        defaultOpsMaxBps = _opsMaxBps;

        emit DefaultGovCapsUpdated(
            _minParamDelay, _maxPerfRate, _maxFeeBps,
            _maxImmExitBps, _maxForceExitBps, _guardianPauseCooldown,
            _minDeployAmount, _stratTaGas, _opsMaxBps
        );
    }
}
