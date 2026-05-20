// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CoreStorage } from "../storage/CoreStorage.sol";
import { FeeStorage } from "../storage/FeeStorage.sol";
import { Events } from "../libraries/Events.sol";
import { IParamsProvider } from "../../interfaces/IParamsProvider.sol";
import { IBufferManager } from "../../interfaces/IBufferManager.sol";
import { IStrategyRouter } from "../../interfaces/IStrategyRouter.sol";
import { IStrategyHealthRegistry } from "../../interfaces/IStrategyHealthRegistry.sol";
import { IIncentives } from "../../interfaces/IIncentives.sol";
import { IIncentivesEngine } from "../../interfaces/IIncentivesEngine.sol";

/// @title AdminModule
/// @notice Handles all timelock-protected admin functions
/// @dev Called via delegatecall from CoreVault - uses namespaced storage
contract AdminModule {
    using SafeERC20 for IERC20;
    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════
    error EtaNotReached();
    error EtaExpired();
    error NotPending();
    error PerfRateTooHigh();
    error ParamsFrozen();
    error MinDelayTooShort();
    error FeeTooHigh();
    error NotOwnerOrVetoer();
    error ZeroAddress();
    error ZeroAmount();
    error ComponentsTimelocked();
    error ComponentsNotTimelocked();
    error SystemSealed();
    error DeadDepositAlreadySeeded();
    error ImmediateExitPenaltyTooHigh();
    error ForceExitPenaltyTooHigh();
    error PendingParamsNotResolved();

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════
    uint64 internal constant MAX_WINDOW = 7 days;
    // P2-P6: Governance-configurable caps — read from GlobalConfig via params
    function _minParamDelay() internal view returns (uint64) {
        return CoreStorage.layout().params.minParamDelay(address(this));
    }
    function _maxPerfRate() internal view returns (uint256) {
        return CoreStorage.layout().params.maxPerfRate(address(this));
    }
    function _maxFeeBps() internal view returns (uint16) {
        return CoreStorage.layout().params.maxFeeBps(address(this));
    }
    function _maxImmediateExitPenaltyBps() internal view returns (uint16) {
        return CoreStorage.layout().params.maxImmediateExitPenaltyBps(address(this));
    }
    function _maxForceExitPenaltyBps() internal view returns (uint16) {
        return CoreStorage.layout().params.maxForceExitPenaltyBps(address(this));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FEE PARAMS TIMELOCK
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
    ) external {
        _requireNotFrozen();
        // H4: Block overwrite of pending params (must revoke first)
        if (FeeStorage.layout().pendingFee.exists) revert PendingParamsNotResolved();
        if (depBps > _maxFeeBps() || witBps > _maxFeeBps()) revert FeeTooHigh();
        if (immediateExitPenaltyBps > _maxImmediateExitPenaltyBps()) {
            revert ImmediateExitPenaltyTooHigh();
        }
        if (forceExitPenaltyBps > _maxForceExitPenaltyBps()) revert ForceExitPenaltyTooHigh();

        CoreStorage.Layout storage core = CoreStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();

        uint64 eta = uint64(block.timestamp) + core.paramMinDelay;
        f.pendingFee.dep = depBps;
        f.pendingFee.wit = witBps;
        f.pendingFee.immediateExitPenalty = immediateExitPenaltyBps;
        f.pendingFee.forceExitPenalty = forceExitPenaltyBps;
        f.pendingFee.treasury = treasury;
        f.pendingFee.eta = eta;
        f.pendingFee.exists = true;

        emit Events.FeeParamsSubmitted(depBps, witBps, treasury, eta);
    }

    /// @notice Accept pending fee parameters after timelock
    function acceptFeeParams() external {
        FeeStorage.Layout storage f = FeeStorage.layout();
        _validateEta(f.pendingFee.eta, f.pendingFee.exists);

        uint16 oldImmediatePenalty = f.fee.immediateExitPenaltyBps;
        uint16 oldForcePenalty = f.fee.forceExitPenaltyBps;

        f.fee.depBps = f.pendingFee.dep;
        f.fee.witBps = f.pendingFee.wit;
        f.fee.immediateExitPenaltyBps = f.pendingFee.immediateExitPenalty;
        f.fee.forceExitPenaltyBps = f.pendingFee.forceExitPenalty;
        f.fee.treasury = f.pendingFee.treasury;

        emit Events.FeeParamsAccepted(f.pendingFee.dep, f.pendingFee.wit, f.pendingFee.treasury);

        // Emit penalty updates if changed
        if (oldImmediatePenalty != f.pendingFee.immediateExitPenalty) {
            emit Events.ImmediateExitPenaltyUpdated(
                oldImmediatePenalty, f.pendingFee.immediateExitPenalty
            );
        }
        if (oldForcePenalty != f.pendingFee.forceExitPenalty) {
            emit Events.ForceExitPenaltyUpdated(oldForcePenalty, f.pendingFee.forceExitPenalty);
        }

        // Clear pending
        delete f.pendingFee.dep;
        delete f.pendingFee.wit;
        delete f.pendingFee.immediateExitPenalty;
        delete f.pendingFee.forceExitPenalty;
        delete f.pendingFee.treasury;
        delete f.pendingFee.eta;
        f.pendingFee.exists = false;
    }

    /// @notice Revoke pending fee parameters (callable by owner or vetoer)
    function revokeFeeParams() external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (msg.sender != core.owner && msg.sender != core.vetoer) revert NotOwnerOrVetoer();

        FeeStorage.Layout storage f = FeeStorage.layout();
        delete f.pendingFee.dep;
        delete f.pendingFee.wit;
        delete f.pendingFee.immediateExitPenalty;
        delete f.pendingFee.forceExitPenalty;
        delete f.pendingFee.treasury;
        delete f.pendingFee.eta;
        f.pendingFee.exists = false;
        emit Events.FeeParamsRevoked();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PERFORMANCE FEE TIMELOCK
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Submit new performance fee parameters (starts timelock)
    function submitPerfParams(uint256 rateX, uint64 minInterval) external {
        _requireNotFrozen();
        if (rateX > _maxPerfRate()) revert PerfRateTooHigh();

        CoreStorage.Layout storage core = CoreStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();

        uint64 eta = uint64(block.timestamp) + core.paramMinDelay;
        f.pendingPerf.rateX = rateX;
        f.pendingPerf.minInterval = minInterval;
        f.pendingPerf.eta = eta;
        f.pendingPerf.exists = true;

        emit Events.PerfParamsSubmitted(rateX, minInterval, eta);
    }

    /// @notice Accept pending performance fee parameters after timelock
    function acceptPerfParams() external {
        FeeStorage.Layout storage f = FeeStorage.layout();
        _validateEta(f.pendingPerf.eta, f.pendingPerf.exists);

        f.perfRateX = f.pendingPerf.rateX;
        f.minCrystallizeInterval = f.pendingPerf.minInterval;

        emit Events.PerfParamsAccepted(f.pendingPerf.rateX, f.pendingPerf.minInterval);

        // Clear pending
        delete f.pendingPerf.rateX;
        delete f.pendingPerf.minInterval;
        delete f.pendingPerf.eta;
        f.pendingPerf.exists = false;
    }

    /// @notice Revoke pending performance fee parameters (callable by owner or vetoer)
    function revokePerfParams() external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (msg.sender != core.owner && msg.sender != core.vetoer) revert NotOwnerOrVetoer();

        FeeStorage.Layout storage f = FeeStorage.layout();
        delete f.pendingPerf.rateX;
        delete f.pendingPerf.minInterval;
        delete f.pendingPerf.eta;
        f.pendingPerf.exists = false;
        emit Events.PerfParamsRevoked();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MIN DELAY TIMELOCK
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Submit new minimum delay (starts timelock with CURRENT delay)
    function submitMinDelay(uint64 newDelay) external {
        _requireNotFrozen();
        // H3: After seal, enforce floor >= 1 day (no return to 0 in production)
        {
            CoreStorage.Layout storage _cs = CoreStorage.layout();
            if (_cs.packedFlags & CoreStorage.FLAG_SYSTEM_SEALED != 0) {
                if (newDelay < 1 days) revert MinDelayTooShort();
            }
        }
        if (newDelay < _minParamDelay()) revert MinDelayTooShort();

        CoreStorage.Layout storage core = CoreStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();

        uint64 eta = uint64(block.timestamp) + core.paramMinDelay;
        f.pendingDelay.newDelay = newDelay;
        f.pendingDelay.eta = eta;
        f.pendingDelay.exists = true;
        emit Events.MinDelaySubmitted(newDelay, eta);
    }

    /// @notice Accept pending minimum delay after timelock
    function acceptMinDelay() external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();
        _validateEta(f.pendingDelay.eta, f.pendingDelay.exists);

        uint64 accepted = f.pendingDelay.newDelay;
        core.paramMinDelay = accepted;

        // Clear pending
        delete f.pendingDelay.newDelay;
        delete f.pendingDelay.eta;
        f.pendingDelay.exists = false;
        emit Events.MinDelayAccepted(accepted);
    }

    /// @notice Revoke pending minimum delay (callable by owner or vetoer)
    function revokeMinDelay() external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (msg.sender != core.owner && msg.sender != core.vetoer) revert NotOwnerOrVetoer();

        FeeStorage.Layout storage f = FeeStorage.layout();
        delete f.pendingDelay.newDelay;
        delete f.pendingDelay.eta;
        f.pendingDelay.exists = false;
        emit Events.MinDelayRevoked();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // COMPONENT SETTERS (immediate, owner-only via router)
    // ═══════════════════════════════════════════════════════════════════════════════

    function _requireNotSealed() internal view {
        if (CoreStorage.layout().packedFlags & CoreStorage.FLAG_SYSTEM_SEALED != 0) {
            revert SystemSealed();
        }
    }

    function setParams(address newParams) external {
        _requireNotSealed();
        CoreStorage.layout().params = IParamsProvider(newParams);
        emit Events.ParamsProviderUpdated(newParams);
    }

    /// @notice Set buffer manager (bootstrap only - blocked after enableComponentsTimelock)
    function setBufferManager(address newBuffer) external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_COMPONENTS_TIMELOCKED != 0) {
            revert ComponentsTimelocked();
        }
        core.bufferManager = IBufferManager(newBuffer);
        emit Events.BufferManagerUpdated(newBuffer);
    }

    /// @notice Set strategy router (bootstrap only - blocked after enableComponentsTimelock)
    function setRouter(address newRouter) external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_COMPONENTS_TIMELOCKED != 0) {
            revert ComponentsTimelocked();
        }
        core.router = IStrategyRouter(newRouter);
        emit Events.StrategyRouterUpdated(newRouter);
    }

    function setHealthRegistry(address newRegistry) external {
        _requireNotSealed();
        CoreStorage.layout().healthRegistry = IStrategyHealthRegistry(newRegistry);
        emit Events.HealthRegistryUpdated(newRegistry);
    }

    function setIncentives(address newIncentives) external {
        _requireNotSealed();
        CoreStorage.layout().incentives = IIncentives(newIncentives);
        emit Events.IncentivesUpdated(newIncentives);
    }

    /// @notice Set the IncentivesEngine v2 (tranche-based)
    function setIncentivesEngine(address newEngine) external {
        _requireNotSealed();
        CoreStorage.layout().incentivesEngine = IIncentivesEngine(newEngine);
        emit Events.IncentivesEngineUpdated(newEngine);
    }

    /// @notice Set the RewardsPayoutManager (sole payout point for incentive rewards)
    function setRewardsPayoutManager(address newManager) external {
        _requireNotSealed();
        CoreStorage.layout().rewardsPayoutManager = newManager;
        emit Events.RewardsPayoutManagerUpdated(newManager);
    }

    /// @notice Set the RouterAllocationPolicy (V10 engine)
    function setRebalancePolicy(address p) external {
        _requireNotSealed();
        CoreStorage.layout().rebalancePolicy = p;
        emit Events.RebalancePolicyUpdated(p);
    }

    /// @notice Set the RouterRebalanceGuard (V10 engine)
    function setRebalanceGuard(address g) external {
        _requireNotSealed();
        CoreStorage.layout().rebalanceGuard = g;
        emit Events.RebalanceGuardUpdated(g);
    }

    /// @notice Set the ExecutionMemory (V10 engine)
    function setExecutionMemory(address em) external {
        _requireNotSealed();
        CoreStorage.layout().executionMemory = em;
        emit Events.ExecutionMemoryUpdated(em);
    }

    /// @notice Enable/disable strict ExecutionMemory mode (reverts on record failure).
    function setStrictExecutionMemory(bool strict) external {
        _requireNotSealed();
        CoreStorage.layout().strictExecutionMemory = strict;
        emit Events.StrictExecutionMemorySet(strict);
    }

    function setFeeCollector(address newCollector) external {
        _requireNotSealed();
        CoreStorage.layout().feeCollector = newCollector;
        emit Events.FeeCollectorUpdated(newCollector);
    }

    function setVetoer(address newVetoer) external {
        _requireNotSealed();
        CoreStorage.layout().vetoer = newVetoer;
        emit Events.VetoerUpdated(newVetoer);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ECOSYSTEM BATCH SETTER
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Set all ecosystem components atomically
    /// @dev Used by factory during vault initialization. BufferManager and StrategyRouter are required.
    /// @param config Ecosystem configuration struct
    function setEcosystem(EcosystemConfig calldata config) external {
        _requireNotSealed();
        if (config.bufferManager == address(0)) revert ZeroAddress();
        if (config.strategyRouter == address(0)) revert ZeroAddress();
        if (config.guardian == address(0)) revert ZeroAddress();

        CoreStorage.Layout storage core = CoreStorage.layout();

        core.bufferManager = IBufferManager(config.bufferManager);
        core.router = IStrategyRouter(config.strategyRouter);
        core.guardian = config.guardian;

        // Optional components (can be address(0))
        if (config.healthRegistry != address(0)) {
            core.healthRegistry = IStrategyHealthRegistry(config.healthRegistry);
        }
        if (config.incentives != address(0)) {
            core.incentives = IIncentives(config.incentives);
        }
        if (config.vetoer != address(0)) {
            core.vetoer = config.vetoer;
        }

        emit Events.EcosystemConfigured(
            config.bufferManager,
            config.strategyRouter,
            config.healthRegistry,
            config.incentives,
            config.guardian,
            config.vetoer
        );
    }

    /// @notice Get current ecosystem configuration
    function getEcosystem() external view returns (EcosystemConfig memory config) {
        CoreStorage.Layout storage core = CoreStorage.layout();
        config.bufferManager = address(core.bufferManager);
        config.strategyRouter = address(core.router);
        config.healthRegistry = address(core.healthRegistry);
        config.incentives = address(core.incentives);
        config.guardian = core.guardian;
        config.vetoer = core.vetoer;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ECOSYSTEM CONFIG STRUCT (must match IAdminModule)
    // ═══════════════════════════════════════════════════════════════════════════════

    struct EcosystemConfig {
        address bufferManager;
        address strategyRouter;
        address healthRegistry;
        address incentives;
        address guardian;
        address vetoer;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PARAMS FREEZE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Permanently freeze all timelock parameters
    function freezeParams() external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        core.packedFlags |= CoreStorage.FLAG_PARAMS_FROZEN;
        emit Events.ParamsFrozen();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // DEAD DEPOSIT (Inflation Attack Hardening)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Dead shares receiver address (standard burn address)
    address internal constant DEAD_SHARES_RECEIVER = 0x000000000000000000000000000000000000dEaD;

    /// @notice Seed dead deposit to prevent inflation attacks
    /// @dev MANDATORY before system seal. One-shot, pre-seal only.
    ///      Does NOT call deposit(), router, BufferManager, or warmNav.
    ///      Uses previewDeposit() for deterministic share calculation.
    /// @param assets Amount of assets to deposit (must be > 0)
    function seedDeadDeposit(uint256 assets) external {
        CoreStorage.Layout storage core = CoreStorage.layout();

        // Pre-seal only
        if (core.packedFlags & CoreStorage.FLAG_SYSTEM_SEALED != 0) revert SystemSealed();

        // One-shot only
        if (core.packedFlags & CoreStorage.FLAG_DEAD_DEPOSIT_DONE != 0) {
            revert DeadDepositAlreadySeeded();
        }

        if (assets == 0) revert ZeroAmount();

        // CRITICAL: Calculate shares BEFORE transferring assets.
        // ERC4626 previewDeposit uses totalAssets() which includes vault balance.
        // If we transfer first, totalAssets includes the new assets and shares = 0 due to
        // the formula: shares = assets * totalSupply / totalAssets (when totalSupply=0, this is ~0).
        uint256 shares = _previewDeposit(assets);

        // Transfer assets from owner
        address assetAddr = _asset();
        IERC20(assetAddr).safeTransferFrom(msg.sender, address(this), assets);

        // Mint shares directly to dead address (bypass ERC4626 deposit path)
        _processorMint(DEAD_SHARES_RECEIVER, shares);

        // Mark as done (one-shot)
        core.packedFlags |= CoreStorage.FLAG_DEAD_DEPOSIT_DONE;

        emit Events.DeadDepositSeeded(assets, shares, DEAD_SHARES_RECEIVER);
    }

    /// @notice Check if dead deposit has been seeded
    function isDeadDepositDone() external view returns (bool) {
        return CoreStorage.layout().packedFlags & CoreStorage.FLAG_DEAD_DEPOSIT_DONE != 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INITIAL FEES (one-shot, pre-seal only)
    // ═══════════════════════════════════════════════════════════════════════════════

    error FeesAlreadyInitialized();

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
    ) external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();

        // Pre-seal only
        if (core.packedFlags & CoreStorage.FLAG_SYSTEM_SEALED != 0) revert SystemSealed();

        // One-shot only
        if (core.packedFlags & CoreStorage.FLAG_FEES_INITIALIZED != 0) {
            revert FeesAlreadyInitialized();
        }

        // Validate
        if (depBps > _maxFeeBps() || witBps > _maxFeeBps()) revert FeeTooHigh();
        if (immediateExitPenaltyBps > _maxImmediateExitPenaltyBps()) {
            revert ImmediateExitPenaltyTooHigh();
        }
        if (forceExitPenaltyBps > _maxForceExitPenaltyBps()) revert ForceExitPenaltyTooHigh();
        if (treasury == address(0)) revert ZeroAddress();

        // Set fees directly (no timelock for initial setup)
        f.fee.depBps = depBps;
        f.fee.witBps = witBps;
        f.fee.immediateExitPenaltyBps = immediateExitPenaltyBps;
        f.fee.forceExitPenaltyBps = forceExitPenaltyBps;
        f.fee.treasury = treasury;

        // Mark as initialized (one-shot)
        core.packedFlags |= CoreStorage.FLAG_FEES_INITIALIZED;

        emit Events.FeeParamsAccepted(depBps, witBps, treasury);
        if (immediateExitPenaltyBps > 0) {
            emit Events.ImmediateExitPenaltyUpdated(0, immediateExitPenaltyBps);
        }
        if (forceExitPenaltyBps > 0) {
            emit Events.ForceExitPenaltyUpdated(0, forceExitPenaltyBps);
        }
    }

    /// @notice Check if initial fees have been set
    function isFeesInitialized() external view returns (bool) {
        return CoreStorage.layout().packedFlags & CoreStorage.FLAG_FEES_INITIALIZED != 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INITIAL PERFORMANCE PARAMS (one-shot, pre-seal only)
    // ═══════════════════════════════════════════════════════════════════════════════

    error PerfAlreadyInitialized();

    /// @notice Set initial performance fee parameters during deployment (one-shot, pre-seal only)
    /// @dev Bypasses timelock for initial setup. Can only be called once before system seal.
    /// @param rateX Performance fee rate (WAD-scaled, e.g., 1e17 = 10%)
    /// @param minInterval Minimum seconds between crystallizations (e.g., 259200 = 3 days)
    function setInitialPerfParams(uint256 rateX, uint64 minInterval) external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();

        // Pre-seal only
        if (core.packedFlags & CoreStorage.FLAG_SYSTEM_SEALED != 0) revert SystemSealed();

        // One-shot only
        if (core.packedFlags & CoreStorage.FLAG_PERF_INITIALIZED != 0) {
            revert PerfAlreadyInitialized();
        }

        // Validate
        if (rateX > _maxPerfRate()) revert PerfRateTooHigh();

        // Set perf params directly (no timelock for initial setup)
        f.perfRateX = rateX;
        f.minCrystallizeInterval = minInterval;

        // Mark as initialized (one-shot)
        core.packedFlags |= CoreStorage.FLAG_PERF_INITIALIZED;

        emit Events.PerfParamsAccepted(rateX, minInterval);
    }

    /// @notice Check if initial perf params have been set
    function isPerfInitialized() external view returns (bool) {
        return CoreStorage.layout().packedFlags & CoreStorage.FLAG_PERF_INITIALIZED != 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // COMPONENT TIMELOCK (BufferManager & Router)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Enable timelock for component changes (BufferManager, Router)
    /// @dev After calling this, setBufferManager/setRouter will revert. Use submit/accept instead.
    function enableComponentsTimelock() external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        core.packedFlags |= CoreStorage.FLAG_COMPONENTS_TIMELOCKED;
        emit Events.ComponentsTimelockEnabled();
    }

    /// @notice Check if component changes are timelocked
    function isComponentsTimelocked() external view returns (bool) {
        return CoreStorage.layout().packedFlags & CoreStorage.FLAG_COMPONENTS_TIMELOCKED != 0;
    }

    // --- BufferManager Timelock ---

    /// @notice Submit new buffer manager (requires timelock to be enabled)
    function submitBufferManager(address newBuffer) external {
        _requireNotFrozen();
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_COMPONENTS_TIMELOCKED == 0) {
            revert ComponentsNotTimelocked();
        }

        FeeStorage.Layout storage f = FeeStorage.layout();
        uint64 eta = uint64(block.timestamp) + core.paramMinDelay;
        f.pendingBuffer.newBuffer = newBuffer;
        f.pendingBuffer.eta = eta;
        f.pendingBuffer.exists = true;

        emit Events.BufferManagerSubmitted(newBuffer, eta);
    }

    /// @notice Accept pending buffer manager after timelock
    function acceptBufferManager() external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();
        _validateEta(f.pendingBuffer.eta, f.pendingBuffer.exists);

        address assetAddr = _asset();
        address oldBuffer = address(core.bufferManager);
        address newBuffer = f.pendingBuffer.newBuffer;

        // Revoke allowance from old buffer (if set and has allowance)
        if (oldBuffer != address(0)) {
            uint256 oldAllowance = IERC20(assetAddr).allowance(address(this), oldBuffer);
            if (oldAllowance > 0) {
                IERC20(assetAddr).forceApprove(oldBuffer, 0);
            }
        }

        // Set new buffer manager (NO MAX allowance - approve-if-needed in _routeDeposit)
        core.bufferManager = IBufferManager(newBuffer);

        emit Events.BufferManagerUpdated(newBuffer);
        emit Events.BufferManagerAccepted(newBuffer);

        // Clear pending
        delete f.pendingBuffer.newBuffer;
        delete f.pendingBuffer.eta;
        f.pendingBuffer.exists = false;
    }

    /// @notice Revoke pending buffer manager (callable by owner or vetoer)
    function revokeBufferManager() external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (msg.sender != core.owner && msg.sender != core.vetoer) revert NotOwnerOrVetoer();

        FeeStorage.Layout storage f = FeeStorage.layout();
        if (!f.pendingBuffer.exists) revert NotPending();

        delete f.pendingBuffer.newBuffer;
        delete f.pendingBuffer.eta;
        f.pendingBuffer.exists = false;

        emit Events.BufferManagerRevoked();
    }

    // --- Router Timelock ---

    /// @notice Submit new strategy router (requires timelock to be enabled)
    function submitRouter(address newRouter) external {
        _requireNotFrozen();
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_COMPONENTS_TIMELOCKED == 0) {
            revert ComponentsNotTimelocked();
        }

        FeeStorage.Layout storage f = FeeStorage.layout();
        uint64 eta = uint64(block.timestamp) + core.paramMinDelay;
        f.pendingRouter.newRouter = newRouter;
        f.pendingRouter.eta = eta;
        f.pendingRouter.exists = true;

        emit Events.RouterSubmitted(newRouter, eta);
    }

    /// @notice Accept pending strategy router after timelock
    function acceptRouter() external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();
        _validateEta(f.pendingRouter.eta, f.pendingRouter.exists);

        address newRouter = f.pendingRouter.newRouter;
        core.router = IStrategyRouter(newRouter);

        emit Events.StrategyRouterUpdated(newRouter);
        emit Events.RouterAccepted(newRouter);

        // Clear pending
        delete f.pendingRouter.newRouter;
        delete f.pendingRouter.eta;
        f.pendingRouter.exists = false;
    }

    /// @notice Revoke pending strategy router (callable by owner or vetoer)
    function revokeRouter() external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (msg.sender != core.owner && msg.sender != core.vetoer) revert NotOwnerOrVetoer();

        FeeStorage.Layout storage f = FeeStorage.layout();
        if (!f.pendingRouter.exists) revert NotPending();

        delete f.pendingRouter.newRouter;
        delete f.pendingRouter.eta;
        f.pendingRouter.exists = false;

        emit Events.RouterRevoked();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    function getPendingFeeParams()
        external
        view
        returns (uint16 dep, uint16 wit, address treasury, uint64 eta, bool exists)
    {
        FeeStorage.Layout storage f = FeeStorage.layout();
        return (
            f.pendingFee.dep,
            f.pendingFee.wit,
            f.pendingFee.treasury,
            f.pendingFee.eta,
            f.pendingFee.exists
        );
    }

    function getPendingPerfParams()
        external
        view
        returns (uint256 rateX, uint64 minInterval, uint64 eta, bool exists)
    {
        FeeStorage.Layout storage f = FeeStorage.layout();
        return
            (
                f.pendingPerf.rateX,
                f.pendingPerf.minInterval,
                f.pendingPerf.eta,
                f.pendingPerf.exists
            );
    }

    function getPendingMinDelay() external view returns (uint64 newDelay, uint64 eta, bool exists) {
        FeeStorage.Layout storage f = FeeStorage.layout();
        return (f.pendingDelay.newDelay, f.pendingDelay.eta, f.pendingDelay.exists);
    }

    function getFeeParams() external view returns (uint16 depBps, uint16 witBps, address treasury) {
        FeeStorage.Layout storage f = FeeStorage.layout();
        return (f.fee.depBps, f.fee.witBps, f.fee.treasury);
    }

    /// @notice Get the immediate exit penalty for direct ERC4626 withdrawals
    function getImmediateExitPenalty() external view returns (uint16 penaltyBps) {
        return FeeStorage.layout().fee.immediateExitPenaltyBps;
    }

    /// @notice Get the force exit penalty for forceWithdraw operations
    function getForceExitPenalty() external view returns (uint16 penaltyBps) {
        return FeeStorage.layout().fee.forceExitPenaltyBps;
    }

    function getPerfParams()
        external
        view
        returns (uint256 rateX, uint64 minInterval, uint256 hwm, uint64 lastCryst)
    {
        FeeStorage.Layout storage f = FeeStorage.layout();
        return (f.perfRateX, f.minCrystallizeInterval, f.highWaterMark, f.lastCrystallize);
    }

    function getMinDelay() external view returns (uint64) {
        return CoreStorage.layout().paramMinDelay;
    }

    function isParamsFrozen() external view returns (bool) {
        return CoreStorage.layout().packedFlags & CoreStorage.FLAG_PARAMS_FROZEN != 0;
    }

    function getPendingBufferManager()
        external
        view
        returns (address newBuffer, uint64 eta, bool exists)
    {
        FeeStorage.Layout storage f = FeeStorage.layout();
        return (f.pendingBuffer.newBuffer, f.pendingBuffer.eta, f.pendingBuffer.exists);
    }

    function getPendingRouter() external view returns (address newRouter, uint64 eta, bool exists) {
        FeeStorage.Layout storage f = FeeStorage.layout();
        return (f.pendingRouter.newRouter, f.pendingRouter.eta, f.pendingRouter.exists);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════════

    function _validateEta(uint64 eta, bool exists) internal view {
        if (!exists) revert NotPending();
        if (block.timestamp < eta) revert EtaNotReached();
        if (block.timestamp > eta + MAX_WINDOW) revert EtaExpired();
    }

    function _requireNotFrozen() internal view {
        if (CoreStorage.layout().packedFlags & CoreStorage.FLAG_PARAMS_FROZEN != 0) {
            revert ParamsFrozen();
        }
    }

    /// @dev Get asset address via staticcall (works in delegatecall context)
    function _asset() internal view returns (address) {
        (bool success, bytes memory data) =
            address(this).staticcall(abi.encodeWithSignature("asset()"));
        require(success, "asset call failed");
        return abi.decode(data, (address));
    }

    /// @dev Raw asset-to-share conversion via staticcall (works in delegatecall context)
    ///      Uses convertToShares (no deposit fee) for dead deposit seeding.
    function _previewDeposit(uint256 assets) internal view returns (uint256) {
        (bool success, bytes memory data) =
            address(this).staticcall(abi.encodeWithSignature("convertToShares(uint256)", assets));
        require(success, "convertToShares call failed");
        return abi.decode(data, (uint256));
    }

    /// @dev Call processorMint via call (works in delegatecall context)
    function _processorMint(address to, uint256 amount) internal {
        (bool success,) = address(this)
            .call(abi.encodeWithSignature("processorMint(address,uint256)", to, amount));
        require(success, "processorMint call failed");
    }
}
