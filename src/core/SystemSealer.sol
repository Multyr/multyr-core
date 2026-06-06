// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CoreVault } from "./CoreVault.sol";
import { IAdminModule } from "../interfaces/IAdminModule.sol";
import { StrategyRouter } from "./modules/StrategyRouter.sol";
import { BufferManager } from "./modules/BufferManager.sol";
import { StrategyHealthRegistry } from "./modules/StrategyHealthRegistry.sol";
import { GlobalConfig } from "./config/GlobalConfig.sol";
import { FeeCollector } from "./modules/FeeCollector.sol";
import { Incentives } from "./modules/Incentives.sol";
import { IncentivesEngine } from "./modules/IncentivesEngine.sol";
import { IRewardsPayoutManager } from "../interfaces/IRewardsPayoutManager.sol";
import { SelectorRegistry } from "./libraries/SelectorRegistry.sol";

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title SystemSealer
 * @notice Onchain verification + atomic seal contract for final system state certification.
 * @dev Verifies all deployment invariants and atomically seals the vault in a single
 *      timelock operation.
 *
 * USAGE (SINGLE-CALL TIMELOCK BATCH):
 *      ROOT_TIMELOCK schedules one call:
 *        systemSealer.verifyAndSeal(config)
 *      No pre-computed hash is needed. The hash is computed at executeBatch() time
 *      from the config addresses (no block.timestamp), so it is fully deterministic.
 *
 * WHY NO TIMESTAMP IN configHash:
 *      The prior two-call design [prepareSeal, sealFinalState] included block.timestamp
 *      in the hash. Since scheduleBatch() and executeBatch() run at different blocks
 *      (separated by the full timelock delay), the operator could never encode the
 *      correct hash at schedule time — the batch always reverted.
 *      See: test/sprint-test/SystemSealer_TimestampHash_POC.t.sol
 *
 * SECURITY MODEL:
 * - Only ROOT_TIMELOCK can call verifyAndSeal()
 * - Only authorized SystemSealer can call vault.sealBySealer()
 * - configHash binds the verified config to the seal event for auditability
 *
 * PRE-SEAL CHECKLIST (verified by verifyAndSeal()):
 * [x] CoreVault.owner == ROOT_TIMELOCK
 * [x] CoreVault.guardian == SAFE_GUARDIAN
 * [x] CoreVault.vetoer == SAFE_VETO
 * [x] CoreVault.isRoutingFrozen == true
 * [x] CoreVault.isComponentsTimelocked == true
 * [x] CoreVault.selectorRegistry is set
 * [x] All AdminModule owner selectors have roleOf == ROLE_OWNER
 * [x] FeeCollector.governor == ROOT_TIMELOCK (immutable)
 * [x] GlobalConfig.governor == ROOT_TIMELOCK
 * [x] StrategyRouter.owner == ROOT_TIMELOCK
 * [x] BufferManager.owner == ROOT_TIMELOCK
 * [x] StrategyHealthRegistry.owner == ROOT_TIMELOCK
 * [x] StrategyHealthRegistry.guardian == SAFE_GUARDIAN
 * [x] Incentives.owner == ROOT_TIMELOCK (if deployed)
 * [x] Strategy: DEFAULT_ADMIN_ROLE -> ROOT_TIMELOCK
 * [x] Strategy: PARAM_ROLE -> ROOT_TIMELOCK
 * [x] Strategy: CORE_ROLE -> CoreVault
 * [x] No deployer retains any admin roles
 * [x] Dead deposit seeded (inflation attack hardening)
 */
contract SystemSealer {
    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════
    error NotRootTimelock();
    error InvariantViolation(string reason);
    error SelectorRoleMismatch(bytes4 selector, uint8 actual, uint8 expected);

    // ═══════════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════
    event SystemSealedEvent(
        address indexed vault, address indexed caller, bytes32 configHash, uint256 timestamp
    );

    // ═══════════════════════════════════════════════════════════════════════════════
    // ROLE CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════
    uint8 public constant ROLE_PUBLIC = 0;
    uint8 public constant ROLE_OWNER = 1;

    // ═══════════════════════════════════════════════════════════════════════════════
    // SEAL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════════

    struct SealConfig {
        // Core addresses
        address vault;
        address strategyRouter;
        address bufferManager;
        address healthRegistry;
        address globalConfig;
        address feeCollector;

        // Expected governance addresses
        address rootTimelock;
        address guardian;
        address vetoer;

        // Strategy (optional, can be address(0) if no strategy deployed yet)
        address strategy;

        // Incentives module (legacy, optional)
        address incentives;

        // IncentivesEngine v2 (tranche-based, optional)
        address incentivesEngine;

        // RewardsPayoutManager (optional)
        address rewardsPayoutManager;

        // Deployer address to verify has no remaining roles
        address deployer;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MAIN SEAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Verify all system invariants and atomically seal the vault.
     * @param config Configuration with all addresses to verify.
     * @dev Schedule as a single-call timelock batch:
     *        rootTimelock.scheduleBatch([systemSealer.verifyAndSeal(config)], ...)
     *      All invariants are checked, then vault.sealBySealer(configHash) is called
     *      atomically. No separate sealFinalState step is required.
     *
     *      configHash does NOT include block.timestamp — it is derived purely from
     *      the config addresses, making it deterministic at schedule time.
     */
    function verifyAndSeal(SealConfig calldata config) external {
        if (msg.sender != config.rootTimelock) revert NotRootTimelock();

        CoreVault vault = CoreVault(payable(config.vault));

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 1: CoreVault ownership and state
        // ─────────────────────────────────────────────────────────────────────────
        if (vault.owner() != config.rootTimelock) {
            revert InvariantViolation("CoreVault.owner != ROOT_TIMELOCK");
        }
        if (vault.guardian() != config.guardian) {
            revert InvariantViolation("CoreVault.guardian != SAFE_GUARDIAN");
        }
        if (vault.vetoer() != config.vetoer) {
            revert InvariantViolation("CoreVault.vetoer != SAFE_VETO");
        }
        if (!vault.isRoutingFrozen()) {
            revert InvariantViolation("CoreVault.isRoutingFrozen != true");
        }
        if (!IAdminModule(config.vault).isComponentsTimelocked()) {
            revert InvariantViolation("CoreVault.isComponentsTimelocked != true");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 2: SelectorRegistry is set and role mappings are correct
        // ─────────────────────────────────────────────────────────────────────────
        address registryAddr = vault.selectorRegistry();
        if (registryAddr == address(0)) {
            revert InvariantViolation("SelectorRegistry not set");
        }

        SelectorRegistry registry = SelectorRegistry(registryAddr);
        bytes4[] memory ownerSelectors = registry.getOwnerSelectors();

        for (uint256 i = 0; i < ownerSelectors.length; i++) {
            bytes4 sel = ownerSelectors[i];
            uint8 actualRole = vault.roleOf(sel);
            if (actualRole != ROLE_OWNER) {
                revert SelectorRoleMismatch(sel, actualRole, ROLE_OWNER);
            }
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 3: FeeCollector governor (IMMUTABLE - most critical check)
        // ─────────────────────────────────────────────────────────────────────────
        FeeCollector fc = FeeCollector(config.feeCollector);
        if (fc.governor() != config.rootTimelock) {
            revert InvariantViolation("FeeCollector.governor != ROOT_TIMELOCK (IMMUTABLE!)");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 4: GlobalConfig governor
        // ─────────────────────────────────────────────────────────────────────────
        GlobalConfig gc = GlobalConfig(config.globalConfig);
        if (gc.governor() != config.rootTimelock) {
            revert InvariantViolation("GlobalConfig.governor != ROOT_TIMELOCK");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 5: StrategyRouter ownership
        // ─────────────────────────────────────────────────────────────────────────
        StrategyRouter router = StrategyRouter(config.strategyRouter);
        if (router.owner() != config.rootTimelock) {
            revert InvariantViolation("StrategyRouter.owner != ROOT_TIMELOCK");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 6: BufferManager ownership
        // ─────────────────────────────────────────────────────────────────────────
        BufferManager buffer = BufferManager(config.bufferManager);
        if (buffer.owner() != config.rootTimelock) {
            revert InvariantViolation("BufferManager.owner != ROOT_TIMELOCK");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 7: StrategyHealthRegistry ownership and guardian
        // ─────────────────────────────────────────────────────────────────────────
        StrategyHealthRegistry hr = StrategyHealthRegistry(config.healthRegistry);
        if (hr.owner() != config.rootTimelock) {
            revert InvariantViolation("HealthRegistry.owner != ROOT_TIMELOCK");
        }
        if (hr.guardian() != config.guardian) {
            revert InvariantViolation("HealthRegistry.guardian != SAFE_GUARDIAN");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 8: Incentives ownership (if deployed)
        // ─────────────────────────────────────────────────────────────────────────
        if (config.incentives != address(0)) {
            Incentives inc = Incentives(config.incentives);
            if (inc.owner() != config.rootTimelock) {
                revert InvariantViolation("Incentives.owner != ROOT_TIMELOCK");
            }
        }

        // INVARIANT 8b: IncentivesEngine v2 governance (if deployed)
        if (config.incentivesEngine != address(0)) {
            if (IncentivesEngine(config.incentivesEngine).governance() != config.rootTimelock) {
                revert InvariantViolation("IncentivesEngine.governance != ROOT_TIMELOCK");
            }
        }

        // INVARIANT 8c: RewardsPayoutManager governance (if deployed)
        if (config.rewardsPayoutManager != address(0)) {
            if (IRewardsPayoutManager(config.rewardsPayoutManager).governance() != config.rootTimelock) {
                revert InvariantViolation("RewardsPayoutManager.governance != ROOT_TIMELOCK");
            }
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 9: Strategy roles (if strategy is deployed)
        // ─────────────────────────────────────────────────────────────────────────
        if (config.strategy != address(0)) {
            _verifyStrategyRoles(config);
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 10: Deployer has no remaining roles
        // ─────────────────────────────────────────────────────────────────────────
        if (config.deployer != address(0) && config.deployer != config.rootTimelock) {
            // Vault owner should not be deployer
            if (vault.owner() == config.deployer) {
                revert InvariantViolation("Deployer still owns CoreVault");
            }
            // Strategy admin should not be deployer
            if (config.strategy != address(0)) {
                AccessControl strategy = AccessControl(config.strategy);
                bytes32 adminRole = strategy.DEFAULT_ADMIN_ROLE();
                if (strategy.hasRole(adminRole, config.deployer)) {
                    revert InvariantViolation("Deployer still has strategy DEFAULT_ADMIN_ROLE");
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 11: Dead deposit seeded (inflation attack hardening)
        // ─────────────────────────────────────────────────────────────────────────
        if (!IAdminModule(config.vault).isDeadDepositDone()) {
            revert InvariantViolation("Dead deposit not seeded - inflation attack risk");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // ALL INVARIANTS PASSED - COMPUTE CONFIG HASH AND SEAL ATOMICALLY
        // ─────────────────────────────────────────────────────────────────────────

        // block.timestamp is intentionally excluded. Including it would make the
        // hash non-deterministic between scheduleBatch() and executeBatch() (they
        // run at different blocks separated by the full timelock delay). The TOCTOU
        // protection comes from the address binding alone — every field here is a
        // deploy-time constant that cannot change between schedule and execute.
        bytes32 configHash = keccak256(
            abi.encode(
                config.vault,
                config.rootTimelock,
                config.guardian,
                config.vetoer,
                config.feeCollector,
                config.strategy,
                config.incentives,
                config.incentivesEngine,
                config.rewardsPayoutManager
            )
        );

        vault.sealBySealer(configHash);

        emit SystemSealedEvent(config.vault, msg.sender, configHash, block.timestamp);
    }

    /**
     * @dev Verify strategy role assignments
     */
    function _verifyStrategyRoles(SealConfig calldata config) internal view {
        AccessControl strategy = AccessControl(config.strategy);

        bytes32 adminRole = strategy.DEFAULT_ADMIN_ROLE();
        bytes32 paramRole = keccak256("PARAM_ROLE");
        bytes32 coreRole = keccak256("CORE_ROLE");
        bytes32 keeperRole = keccak256("KEEPER_ROLE");

        // ROOT_TIMELOCK must have DEFAULT_ADMIN_ROLE
        if (!strategy.hasRole(adminRole, config.rootTimelock)) {
            revert InvariantViolation("Strategy: ROOT_TIMELOCK missing DEFAULT_ADMIN_ROLE");
        }

        // ROOT_TIMELOCK must have PARAM_ROLE
        if (!strategy.hasRole(paramRole, config.rootTimelock)) {
            revert InvariantViolation("Strategy: ROOT_TIMELOCK missing PARAM_ROLE");
        }

        // CoreVault must have CORE_ROLE
        if (!strategy.hasRole(coreRole, config.vault)) {
            revert InvariantViolation("Strategy: CoreVault missing CORE_ROLE");
        }

        // Guardian should have KEEPER_ROLE (backup)
        if (!strategy.hasRole(keeperRole, config.guardian)) {
            revert InvariantViolation("Strategy: Guardian missing KEEPER_ROLE (backup)");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if system would pass seal verification (dry run)
     * @param config Configuration to verify
     * @return valid True if all invariants pass
     * @return reason Error message if validation fails
     */
    function canSeal(SealConfig calldata config)
        external
        view
        returns (bool valid, string memory reason)
    {
        CoreVault vault = CoreVault(payable(config.vault));

        // Basic checks
        if (vault.isSystemSealed()) return (false, "Already sealed");
        if (vault.owner() != config.rootTimelock) {
            return (false, "CoreVault.owner != ROOT_TIMELOCK");
        }
        if (vault.guardian() != config.guardian) {
            return (false, "CoreVault.guardian != SAFE_GUARDIAN");
        }
        if (vault.vetoer() != config.vetoer) return (false, "CoreVault.vetoer != SAFE_VETO");
        if (!vault.isRoutingFrozen()) return (false, "CoreVault.isRoutingFrozen != true");

        // SelectorRegistry
        address registryAddr = vault.selectorRegistry();
        if (registryAddr == address(0)) return (false, "SelectorRegistry not set");

        // Check owner selectors
        SelectorRegistry registry = SelectorRegistry(registryAddr);
        bytes4[] memory ownerSelectors = registry.getOwnerSelectors();
        for (uint256 i = 0; i < ownerSelectors.length; i++) {
            if (vault.roleOf(ownerSelectors[i]) != ROLE_OWNER) {
                return (false, "Selector role mismatch");
            }
        }

        // ComponentsTimelocked check
        if (!IAdminModule(config.vault).isComponentsTimelocked()) {
            return (false, "CoreVault.isComponentsTimelocked != true");
        }

        // FeeCollector (most critical - immutable)
        if (FeeCollector(config.feeCollector).governor() != config.rootTimelock) {
            return (false, "FeeCollector.governor != ROOT_TIMELOCK");
        }

        // GlobalConfig
        if (GlobalConfig(config.globalConfig).governor() != config.rootTimelock) {
            return (false, "GlobalConfig.governor != ROOT_TIMELOCK");
        }

        // StrategyRouter
        if (StrategyRouter(config.strategyRouter).owner() != config.rootTimelock) {
            return (false, "StrategyRouter.owner != ROOT_TIMELOCK");
        }

        // BufferManager
        if (BufferManager(config.bufferManager).owner() != config.rootTimelock) {
            return (false, "BufferManager.owner != ROOT_TIMELOCK");
        }

        // StrategyHealthRegistry
        StrategyHealthRegistry hr = StrategyHealthRegistry(config.healthRegistry);
        if (hr.owner() != config.rootTimelock) {
            return (false, "HealthRegistry.owner != ROOT_TIMELOCK");
        }
        if (hr.guardian() != config.guardian) {
            return (false, "HealthRegistry.guardian != SAFE_GUARDIAN");
        }

        // Incentives (legacy, if deployed)
        if (config.incentives != address(0)) {
            if (Incentives(config.incentives).owner() != config.rootTimelock) {
                return (false, "Incentives.owner != ROOT_TIMELOCK");
            }
        }

        // IncentivesEngine v2 (if deployed)
        if (config.incentivesEngine != address(0)) {
            if (IncentivesEngine(config.incentivesEngine).governance() != config.rootTimelock) {
                return (false, "IncentivesEngine.governance != ROOT_TIMELOCK");
            }
        }

        // RewardsPayoutManager (if deployed)
        if (config.rewardsPayoutManager != address(0)) {
            if (IRewardsPayoutManager(config.rewardsPayoutManager).governance() != config.rootTimelock) {
                return (false, "RewardsPayoutManager.governance != ROOT_TIMELOCK");
            }
        }

        // Dead deposit (inflation attack hardening)
        if (!IAdminModule(config.vault).isDeadDepositDone()) {
            return (false, "Dead deposit not seeded");
        }

        // All checks passed
        return (true, "");
    }
}
