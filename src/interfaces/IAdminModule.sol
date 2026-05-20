// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAdminModule
/// @notice Interface for AdminModule functions accessible via CoreVault fallback routing
/// @dev Use this interface to call admin functions on CoreVault: IAdminModule(address(vault)).submitFeeParams(...)
interface IAdminModule {
    // ═══════════════════════════════════════════════════════════════════════════════
    // FEE PARAMS (timelock)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Submit new fee parameters (starts timelock)
    /// @param depBps Deposit fee in basis points
    /// @param witBps Withdrawal fee in basis points (applies to all withdrawals)
    /// @param immediateExitPenaltyBps Additional penalty for immediate withdrawals (ERC4626Module only)
    /// @param forceExitPenaltyBps Additional penalty for force withdrawals (forceWithdraw only)
    /// @param treasury Fee recipient address
    function submitFeeParams(
        uint16 depBps,
        uint16 witBps,
        uint16 immediateExitPenaltyBps,
        uint16 forceExitPenaltyBps,
        address treasury
    ) external;

    /// @notice Accept pending fee parameters after timelock
    function acceptFeeParams() external;

    /// @notice Revoke pending fee parameters
    function revokeFeeParams() external;

    // ═══════════════════════════════════════════════════════════════════════════════
    // PERF PARAMS (timelock)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Submit new performance fee parameters
    function submitPerfParams(uint256 rateX, uint64 minInterval) external;

    /// @notice Accept pending performance parameters after timelock
    function acceptPerfParams() external;

    /// @notice Revoke pending performance parameters
    function revokePerfParams() external;

    // ═══════════════════════════════════════════════════════════════════════════════
    // MIN DELAY (timelock)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Submit new minimum delay for timelocks
    function submitMinDelay(uint64 newDelay) external;

    /// @notice Accept pending minimum delay
    function acceptMinDelay() external;

    /// @notice Revoke pending minimum delay
    function revokeMinDelay() external;

    // ═══════════════════════════════════════════════════════════════════════════════
    // COMPONENT SETTERS (owner only, no timelock)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Set params provider
    function setParams(address newParams) external;

    /// @notice Set buffer manager
    function setBufferManager(address newBuffer) external;

    /// @notice Set strategy router
    function setRouter(address newRouter) external;

    /// @notice Set health registry
    function setHealthRegistry(address newRegistry) external;

    /// @notice Set incentives module
    function setIncentives(address newIncentives) external;

    /// @notice Set fee collector address
    function setFeeCollector(address newCollector) external;

    /// @notice Set vetoer address
    function setVetoer(address newVetoer) external;

    /// @notice Freeze all parameters permanently
    function freezeParams() external;

    // ═══════════════════════════════════════════════════════════════════════════════
    // DEAD DEPOSIT (Inflation Attack Hardening)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Seed dead deposit to prevent inflation attacks
    /// @dev MANDATORY before system seal. One-shot, pre-seal only.
    /// @param assets Amount of assets to deposit (must be > 0)
    function seedDeadDeposit(uint256 assets) external;

    /// @notice Check if dead deposit has been seeded
    function isDeadDepositDone() external view returns (bool);

    // ═══════════════════════════════════════════════════════════════════════════════
    // INITIAL FEES (one-shot, pre-seal only)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Set initial fee parameters during deployment (one-shot, pre-seal only)
    /// @dev Bypasses timelock for initial setup. Can only be called once before system seal.
    /// @param depBps Deposit fee in basis points (max 500 = 5%)
    /// @param witBps Withdrawal fee in basis points (max 500 = 5%)
    /// @param immediateExitPenaltyBps Additional penalty for immediate withdrawals (max 200 = 2%)
    /// @param forceExitPenaltyBps Additional penalty for force withdrawals (max 200 = 2%)
    /// @param treasury Fee recipient address
    function setInitialFees(
        uint16 depBps,
        uint16 witBps,
        uint16 immediateExitPenaltyBps,
        uint16 forceExitPenaltyBps,
        address treasury
    ) external;

    /// @notice Check if initial fees have been set
    function isFeesInitialized() external view returns (bool);

    /// @notice Set initial performance fee parameters during deployment (one-shot, pre-seal only)
    /// @param rateX Performance fee rate (WAD-scaled, e.g., 1e17 = 10%)
    /// @param minInterval Minimum seconds between crystallizations (e.g., 259200 = 3 days)
    function setInitialPerfParams(uint256 rateX, uint64 minInterval) external;

    /// @notice Check if initial perf params have been set
    function isPerfInitialized() external view returns (bool);

    // ═══════════════════════════════════════════════════════════════════════════════
    // COMPONENT TIMELOCK (BufferManager & Router)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Enable timelock for component changes
    function enableComponentsTimelock() external;

    /// @notice Check if component changes are timelocked
    function isComponentsTimelocked() external view returns (bool);

    /// @notice Submit new buffer manager (timelocked)
    function submitBufferManager(address newBuffer) external;

    /// @notice Accept pending buffer manager after timelock
    function acceptBufferManager() external;

    /// @notice Revoke pending buffer manager
    function revokeBufferManager() external;

    /// @notice Submit new strategy router (timelocked)
    function submitRouter(address newRouter) external;

    /// @notice Accept pending router after timelock
    function acceptRouter() external;

    /// @notice Revoke pending router
    function revokeRouter() external;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ECOSYSTEM BATCH SETTER
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Ecosystem configuration struct for atomic initialization
    struct EcosystemConfig {
        address bufferManager; // BufferManager contract
        address strategyRouter; // StrategyRouter contract
        address healthRegistry; // StrategyHealthRegistry contract (can be address(0))
        address incentives; // Incentives contract (can be address(0))
        address guardian; // Guardian address
        address vetoer; // Vetoer address (can be address(0))
    }

    /// @notice Set all ecosystem components atomically
    /// @dev Used by factory during vault initialization. BufferManager and StrategyRouter are required.
    /// @param config Ecosystem configuration
    function setEcosystem(EcosystemConfig calldata config) external;

    /// @notice Get current ecosystem configuration
    function getEcosystem() external view returns (EcosystemConfig memory);

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Get pending fee parameters
    function getPendingFeeParams()
        external
        view
        returns (uint16 depBps, uint16 witBps, address treasury, uint64 eta, bool exists);

    /// @notice Get pending performance parameters
    function getPendingPerfParams()
        external
        view
        returns (uint256 rateX, uint64 minInterval, uint64 eta, bool exists);

    /// @notice Get pending minimum delay
    function getPendingMinDelay() external view returns (uint64 newDelay, uint64 eta, bool exists);

    /// @notice Get current fee parameters
    function getFeeParams() external view returns (uint16 depBps, uint16 witBps, address treasury);

    /// @notice Get the immediate exit penalty for direct ERC4626 withdrawals
    function getImmediateExitPenalty() external view returns (uint16 penaltyBps);

    /// @notice Get the force exit penalty for forceWithdraw operations
    function getForceExitPenalty() external view returns (uint16 penaltyBps);

    /// @notice Get current performance parameters
    function getPerfParams()
        external
        view
        returns (uint256 rateX, uint64 minInterval, uint256 hwm, uint64 lastCryst);

    /// @notice Get current minimum delay
    function getMinDelay() external view returns (uint64);

    /// @notice Check if parameters are frozen
    function isParamsFrozen() external view returns (bool);

    /// @notice Get pending buffer manager
    function getPendingBufferManager()
        external
        view
        returns (address newBuffer, uint64 eta, bool exists);

    /// @notice Get pending router
    function getPendingRouter() external view returns (address newRouter, uint64 eta, bool exists);
}
