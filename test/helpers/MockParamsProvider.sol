// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IParamsProvider } from "../../src/interfaces/IParamsProvider.sol";

/**
 * @title MockParamsProvider
 * @notice Minimal mock implementation of IParamsProvider for testing
 * @dev Returns sensible defaults for all parameters, simplifying test setup
 */
contract MockParamsProvider is IParamsProvider {
    // Configurable parameters for tests that need non-default values
    uint64 private _lockPeriod;
    uint16 private _capPerEpochBps = 10000; // Default: 100% (no cap)
    uint256 private _minClaimAmount = 0; // Default: no minimum
    uint256 private _maxWithdrawalPerBlock = 0; // Default: unlimited
    uint256 private _maxWithdrawalPerTx = 0; // Default: unlimited
    uint256 private _vaultDepositCap = 0; // Default: unlimited
    uint256 private _userDepositCap = 0; // Default: unlimited
    uint256 private _minDepositAmount = 0; // Default: disabled

    constructor() {
        _lockPeriod = 0; // Default: no lock
    }

    /// @notice Set lock period (for tests that need custom values)
    function setLockPeriod(uint64 lockPeriod_) external {
        _lockPeriod = lockPeriod_;
    }

    /// @notice Set cap per epoch in bps (for tests that need custom values)
    function setCapPerEpochBps(uint16 capBps_) external {
        _capPerEpochBps = capBps_;
    }

    /// @notice Set minimum claim amount (for tests that need custom values)
    function setMinClaimAmount(uint256 minClaim_) external {
        _minClaimAmount = minClaim_;
    }

    /// @notice Set max withdrawal per block (for tests that need custom values)
    function setMaxWithdrawalPerBlock(uint256 maxPerBlock_) external {
        _maxWithdrawalPerBlock = maxPerBlock_;
    }

    /// @notice Set max withdrawal per tx (for tests that need custom values)
    function setMaxWithdrawalPerTx(uint256 maxPerTx_) external {
        _maxWithdrawalPerTx = maxPerTx_;
    }

    function setDepositLimits(
        uint256 vaultDepositCap_,
        uint256 userDepositCap_,
        uint256 minDepositAmount_
    ) external {
        _vaultDepositCap = vaultDepositCap_;
        _userDepositCap = userDepositCap_;
        _minDepositAmount = minDepositAmount_;
    }

    /// @notice Returns default fee parameters (no fees)
    function getFeeParams(
        address /* vault */
    )
        external
        pure
        returns (FeeParams memory)
    {
        return FeeParams({
            depositFeeBps: 0,
            withdrawFeeBps: 0,
            perfRateX: 2e17, // 20%
            minCrystallizeInterval: 1 days,
            treasury: address(0)
        });
    }

    /// @notice Returns default withdrawal parameters (permissive)
    function getWithdrawalParams(
        address /* vault */
    )
        external
        view
        returns (WithdrawalParams memory)
    {
        return WithdrawalParams({
            capPerEpochBps: _capPerEpochBps, // configurable (default: 100% no cap)
            maxWithdrawalPerBlock: _maxWithdrawalPerBlock, // configurable (default: unlimited)
            maxWithdrawalPerTx: _maxWithdrawalPerTx, // configurable (default: unlimited)
            minClaimAmount: _minClaimAmount, // configurable (default: 0)
            lockPeriod: _lockPeriod // configurable (default: 0)
        });
    }

    /// @notice Returns default dynamic cap parameters (disabled)
    function getDynamicCapParams(
        address /* vault */
    )
        external
        pure
        returns (DynamicCapParams memory)
    {
        return
            DynamicCapParams({
                minBps: 100, maxBps: 10000, queueStressThreshold: 0, enabled: false
            });
    }

    /// @notice Returns default queue parameters (permissive)
    function getQueueParams(
        address /* vault */
    )
        external
        pure
        returns (QueueParams memory)
    {
        return
            QueueParams({
                maxClaimsPerUserPerEpoch: 255, cooldownPerClaim: 0, epochDuration: 7 days
            });
    }

    /// @notice Returns default security parameters (no circuit breaker)
    function getSecurityParams(
        address /* vault */
    )
        external
        pure
        returns (SecurityParams memory)
    {
        return SecurityParams({
            circuitBreakerBps: 0, // disabled
            tvlSnapshotInterval: 1 hours,
            oracle: address(0),
            oracleStalenessLimit: 1 hours
        });
    }

    /// @notice Returns default buffer parameters
    function getBufferParams(
        address /* vault */
    )
        external
        pure
        returns (BufferParams memory)
    {
        return BufferParams({
            targetHotBps: 300, // 3%
            minHotBps: 200, // 2%
            targetWarmBps: 700, // 7%
            maxWarmBps: 1000, // 10%
            opsReserveTargetBps: 100, // 1%
            maxWarmSlippageBps: 50 // 0.5%
        });
    }

    /// @notice Returns default strategy parameters
    function getStrategyParams(
        address /* vault */
    )
        external
        pure
        returns (StrategyParams memory)
    {
        return StrategyParams({
            maxStrategyBps: 2000, // 20%
            lossCapBps: 100, // 1%
            aggregateLossCapBps: 500, // 5%
            gasPerStrategyWithdraw: 100000
        });
    }

    /// @notice Returns default batch guardrails
    function getBatchGuardrails(
        address /* vault */
    )
        external
        pure
        returns (BatchGuardrails memory)
    {
        return BatchGuardrails({
            maxActionsPerBatch: 100,
            maxNavDeltaBps: 1000, // 10%
            maxStaleness: 1 hours
        });
    }

    /// @notice Returns default deposit limits (unlimited)
    function getDepositLimits(
        address /* vault */
    )
        external
        view
        returns (DepositLimits memory)
    {
        return DepositLimits({
            vaultDepositCap: _vaultDepositCap,
            userDepositCap: _userDepositCap,
            minDepositAmount: _minDepositAmount
        });
    }

    /// @notice Returns default NAV smoothing parameters (disabled)
    function getNavSmoothingParams(
        address /* vault */
    )
        external
        pure
        returns (NavSmoothingParams memory)
    {
        return NavSmoothingParams({
            alphaBps: 200, // 2% EMA weight
            interval: 3600, // 1 hour
            enabled: false // Disabled by default
        });
    }

    /// @notice Always returns false (no overrides in mock)
    function hasOverrides(
        address /* vault */
    )
        external
        pure
        returns (bool)
    {
        return false;
    }

    /// @notice All adapters allowed by default
    function isAdapterAllowed(
        address /* adapter */
    )
        external
        pure
        returns (bool)
    {
        return true;
    }

    /// @notice No cap on adapters
    function adapterCap(
        address /* adapter */
    )
        external
        pure
        returns (uint256)
    {
        return type(uint256).max;
    }

    /// @notice Returns zero address for oracle
    function oracleFor(
        address /* asset */
    )
        external
        pure
        returns (address)
    {
        return address(0);
    }

    /// @notice Get oracle + staleness config for (asset, vault)
    /// @dev Returns default values (no oracle configured)
    function oracleConfigFor(
        address,
        /* asset */
        address /* vault */
    )
        external
        pure
        returns (address oracle, uint256 maxStaleness_)
    {
        return (address(0), 3600);
    }

    /// @notice Returns permissive max actions (100)
    function maxActionsPerBatch() external pure returns (uint8) {
        return 100; // High limit for testing
    }

    /// @notice Returns permissive NAV delta (10000 bps = 100%)
    function maxNavDeltaBps() external pure returns (uint16) {
        return 10000; // 100% - permissive for testing
    }

    /// @notice Returns permissive staleness (1 hour)
    function maxStaleness() external pure returns (uint256) {
        return 3600; // 1 hour
    }

    /// @notice Returns permissive cooldown (0 for tests)
    function minRebalanceCooldown() external pure returns (uint256) {
        return 0; // No cooldown for tests
    }

    /// @notice Returns version
    function version() external pure returns (uint16) {
        return 1;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GOVERNANCE-CONFIGURABLE CAPS (P2-P10) — defaults matching original constants
    // ═══════════════════════════════════════════════════════════════════════════

    function minParamDelay(address) external pure returns (uint64) { return 2 days; }
    function maxPerfRate(address) external pure returns (uint256) { return 5e17; }
    function maxFeeBps(address) external pure returns (uint16) { return 500; }
    function maxImmediateExitPenaltyBps(address) external pure returns (uint16) { return 200; }
    function maxForceExitPenaltyBps(address) external pure returns (uint16) { return 200; }
    function guardianPauseCooldown(address) external pure returns (uint64) { return 7 days; }
    function minDeployAmount(address) external pure returns (uint256) { return 10e6; }
    function stratTaGas(address) external pure returns (uint256) { return 1_000_000; }
    function opsMaxBps(address) external pure returns (uint16) { return 3000; }
}
