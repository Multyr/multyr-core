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
import { RecoveryGate } from "../governance/RecoveryGate.sol";

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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
 * SINGLE VERIFICATION ENGINE (review §25):
 *      canSeal() and verifyAndSeal() both derive their result from the same
 *      internal _verifyLiveState(). Before this, the two functions maintained
 *      independent invariant lists that had drifted apart: canSeal() never
 *      checked strategy role assignments or the deployer-retains-no-roles
 *      invariant, so it could return (true, "") for a config verifyAndSeal()
 *      would still revert on. verifyAndSeal() now adds only the authorization
 *      check, the state transition, and seal-digest storage on top of the
 *      shared verifier — it does not maintain a second independent list.
 *
 * PRE-SEAL CHECKLIST (verified by _verifyLiveState(), shared by both entry points):
 * [x] CoreVault.owner == ROOT_TIMELOCK
 * [x] CoreVault.guardian == SAFE_GUARDIAN
 * [x] CoreVault.vetoer == SAFE_VETO
 * [x] CoreVault.isRoutingFrozen == true
 * [x] CoreVault.isComponentsTimelocked == true
 * [x] CoreVault.selectorRegistry is set
 * [x] All AdminModule owner selectors have roleOf == ROLE_OWNER
 * [x] CoreVault.feeCollector == config.feeCollector (live-wiring bind — a
 *     correctly governed FeeCollector the vault does not read from must not
 *     satisfy the seal)
 * [x] FeeCollector.governor == ROOT_TIMELOCK (immutable)
 * [x] GlobalConfig.governor == ROOT_TIMELOCK
 * [x] CoreVault.router() == config.strategyRouter (live-wiring bind)
 * [x] StrategyRouter.owner == ROOT_TIMELOCK
 * [x] CoreVault.bufferManager() == config.bufferManager (live-wiring bind)
 * [x] BufferManager.owner == ROOT_TIMELOCK
 * [x] CoreVault.healthRegistry() == config.healthRegistry (live-wiring bind)
 * [x] StrategyHealthRegistry.owner == ROOT_TIMELOCK
 * [x] StrategyHealthRegistry.guardian == SAFE_GUARDIAN
 * [x] Incentives.owner == ROOT_TIMELOCK (if deployed)
 * [x] CoreVault.recoveryGate == config.recoveryGate (if deployed) and its
 *     MANIFEST_VERSION matches config.recoveryManifestVersion
 * [x] Strategy: DEFAULT_ADMIN_ROLE -> ROOT_TIMELOCK
 * [x] Strategy: PARAM_ROLE -> ROOT_TIMELOCK
 * [x] Strategy: CORE_ROLE -> CoreVault
 * [x] No deployer retains any admin roles
 * [x] Dead deposit seeded (inflation attack hardening)
 * [x] config.globalConfig == vault.params() (the override check must read the
 *     provider the vault actually resolves at runtime)
 * [x] Non-6dp vault asset has VAULT_CAP/WITHDRAWAL/GOV_CAPS overrides set
 *     (GlobalConfig defaults are 6dp/USDC-shaped and would brick the vault)
 * [x] config.chainId == block.chainid (review §24/§42 — a manifest built for
 *     one chain must not be sealable against a vault on another)
 */
contract SystemSealer {
    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════
    error NotRootTimelock();
    error InvariantViolation(string reason);

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
        // Chain binding — the manifest identity this config was authored for.
        uint256 chainId;

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

        // Emergency Module Recovery gate (optional — address(0) if this
        // deployment does not wire recovery). If set, must match
        // vault.recoveryGate() exactly and its MANIFEST_VERSION must match
        // recoveryManifestVersion below, so sealing also commits to the
        // identity of the recovery policy, not just its address.
        address recoveryGate;
        uint256 recoveryManifestVersion;

        // RewardsTreasury: NOT validated — recorded in configHash for audit purposes
        // only. The actual invariant (non-zero if rewardsPayoutManager is deployed)
        // is checked against vault.rewardsTreasury() (see INVARIANT 8d), never
        // against this caller-supplied field, so a mismatched value here is silently
        // ignored rather than rejected.
        address rewardsTreasury;

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

        (bool ok, string memory reason) = _verifyLiveState(config);
        if (!ok) revert InvariantViolation(reason);

        CoreVault vault = CoreVault(payable(config.vault));

        // block.timestamp is intentionally excluded. Including it would make the
        // hash non-deterministic between scheduleBatch() and executeBatch() (they
        // run at different blocks separated by the full timelock delay). The TOCTOU
        // protection comes from the address binding alone — every field here is a
        // deploy-time constant that cannot change between schedule and execute.
        bytes32 configHash = keccak256(
            abi.encode(
                config.chainId,
                config.vault,
                config.rootTimelock,
                config.guardian,
                config.vetoer,
                config.feeCollector,
                config.strategy,
                config.incentives,
                config.incentivesEngine,
                config.rewardsPayoutManager,
                config.rewardsTreasury,
                config.recoveryGate,
                config.recoveryManifestVersion
            )
        );

        vault.sealBySealer(configHash);

        emit SystemSealedEvent(config.vault, msg.sender, configHash, block.timestamp);
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
        return _verifyLiveState(config);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SINGLE VERIFICATION ENGINE (review §25)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev The sole source of truth for every pre-seal invariant. Both
    ///      canSeal() and verifyAndSeal() call this and only this — there is
    ///      no second, independently-maintained invariant list. A positive
    ///      result here must imply verifyAndSeal() succeeds against unchanged
    ///      state (review §42).
    function _verifyLiveState(SealConfig calldata config)
        internal
        view
        returns (bool ok, string memory reason)
    {
        CoreVault vault = CoreVault(payable(config.vault));

        // ─────────────────────────────────────────────────────────────────────────
        // Chain binding
        // ─────────────────────────────────────────────────────────────────────────
        if (config.chainId != block.chainid) {
            return (false, "chainId mismatch");
        }

        if (vault.isSystemSealed()) return (false, "Already sealed");

        // This specific SystemSealer instance must be the one CoreVault will
        // actually accept a seal from — otherwise canSeal() can return
        // (true, "") for a config where verifyAndSeal() would still revert
        // with NotAuthorizedSealer inside vault.sealBySealer(), reintroducing
        // exactly the canSeal()/verifyAndSeal() divergence this file exists
        // to eliminate (review §25/§42).
        if (vault.authorizedSealer() != address(this)) {
            return (false, "SystemSealer not authorized on vault");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 1: CoreVault ownership and state
        // ─────────────────────────────────────────────────────────────────────────
        if (vault.owner() != config.rootTimelock) {
            return (false, "CoreVault.owner != ROOT_TIMELOCK");
        }
        if (vault.guardian() != config.guardian) {
            return (false, "CoreVault.guardian != SAFE_GUARDIAN");
        }
        if (vault.vetoer() != config.vetoer) {
            return (false, "CoreVault.vetoer != SAFE_VETO");
        }
        if (!vault.isRoutingFrozen()) {
            return (false, "CoreVault.isRoutingFrozen != true");
        }
        if (!IAdminModule(config.vault).isComponentsTimelocked()) {
            return (false, "CoreVault.isComponentsTimelocked != true");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 2: SelectorRegistry is set and role mappings are correct
        // ─────────────────────────────────────────────────────────────────────────
        address registryAddr = vault.selectorRegistry();
        if (registryAddr == address(0)) {
            return (false, "SelectorRegistry not set");
        }

        SelectorRegistry registry = SelectorRegistry(registryAddr);
        bytes4[] memory ownerSelectors = registry.getOwnerSelectors();
        for (uint256 i = 0; i < ownerSelectors.length; i++) {
            if (vault.roleOf(ownerSelectors[i]) != ROLE_OWNER) {
                return (false, "Selector role mismatch");
            }
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 3: FeeCollector is bound to the vault, and its governor
        // ─────────────────────────────────────────────────────────────────────────
        // Live-wiring bind (review §24) — same narrow-fix pattern already
        // applied to GlobalConfig on PR #11: without this, a correctly
        // governed FeeCollector that the vault does NOT actually read from
        // still satisfies the governance check below, so a decoy address
        // passes the seal even though CoreVault.feeCollector() points
        // somewhere else entirely.
        if (vault.feeCollector() != config.feeCollector) {
            return (false, "FeeCollector not bound to vault");
        }
        FeeCollector fc = FeeCollector(config.feeCollector);
        if (fc.governor() != config.rootTimelock) {
            return (false, "FeeCollector.governor != ROOT_TIMELOCK (IMMUTABLE!)");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 4: GlobalConfig governor
        // ─────────────────────────────────────────────────────────────────────────
        GlobalConfig gc = GlobalConfig(config.globalConfig);
        if (gc.governor() != config.rootTimelock) {
            return (false, "GlobalConfig.governor != ROOT_TIMELOCK");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 5: StrategyRouter is bound to the vault, and its ownership
        // ─────────────────────────────────────────────────────────────────────────
        if (address(vault.router()) != config.strategyRouter) {
            return (false, "StrategyRouter not bound to vault");
        }
        if (StrategyRouter(config.strategyRouter).owner() != config.rootTimelock) {
            return (false, "StrategyRouter.owner != ROOT_TIMELOCK");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 6: BufferManager is bound to the vault, and its ownership
        // ─────────────────────────────────────────────────────────────────────────
        if (address(vault.bufferManager()) != config.bufferManager) {
            return (false, "BufferManager not bound to vault");
        }
        if (BufferManager(config.bufferManager).owner() != config.rootTimelock) {
            return (false, "BufferManager.owner != ROOT_TIMELOCK");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 7: StrategyHealthRegistry is bound to the vault, its
        // ownership, and its guardian
        // ─────────────────────────────────────────────────────────────────────────
        if (address(vault.healthRegistry()) != config.healthRegistry) {
            return (false, "HealthRegistry not bound to vault");
        }
        StrategyHealthRegistry hr = StrategyHealthRegistry(config.healthRegistry);
        if (hr.owner() != config.rootTimelock) {
            return (false, "HealthRegistry.owner != ROOT_TIMELOCK");
        }
        if (hr.guardian() != config.guardian) {
            return (false, "HealthRegistry.guardian != SAFE_GUARDIAN");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 8: Incentives ownership (if deployed)
        // ─────────────────────────────────────────────────────────────────────────
        if (config.incentives != address(0)) {
            if (Incentives(config.incentives).owner() != config.rootTimelock) {
                return (false, "Incentives.owner != ROOT_TIMELOCK");
            }
        }

        // INVARIANT 8b: IncentivesEngine v2 governance (if deployed)
        if (config.incentivesEngine != address(0)) {
            if (IncentivesEngine(config.incentivesEngine).governance() != config.rootTimelock) {
                return (false, "IncentivesEngine.governance != ROOT_TIMELOCK");
            }
        }

        // INVARIANT 8c: RewardsPayoutManager governance (if deployed)
        if (config.rewardsPayoutManager != address(0)) {
            if (
                IRewardsPayoutManager(config.rewardsPayoutManager).governance()
                    != config.rootTimelock
            ) {
                return (false, "RewardsPayoutManager.governance != ROOT_TIMELOCK");
            }
        }

        // INVARIANT 8d: RewardsTreasury must be funded before a live RewardsPayoutManager
        // is sealed in — payRewardShares() reverts on treasury=0 and setRewardsTreasury()
        // is blocked post-seal, so an unset treasury here would be permanently unfixable.
        // Reads the vault's actual on-chain value rather than trusting config.rewardsTreasury
        // (a caller-supplied field) — otherwise a proposer could pass a plausible non-zero
        // address here while storage is still address(0), sealing in a permanently broken
        // payout path.
        if (config.rewardsPayoutManager != address(0) && vault.rewardsTreasury() == address(0)) {
            return (false, "RewardsTreasury not set but RewardsPayoutManager is deployed");
        }

        // INVARIANT 8e: Emergency Module Recovery gate binding (optional — a
        // deployment may seal without wiring recovery at all). Reads the
        // vault's actual on-chain value, exactly like every other component
        // check above, so a caller cannot claim a recovery gate is wired
        // when it is not (or vice versa). When set, the manifest's declared
        // version must match the gate's own MANIFEST_VERSION — sealing
        // commits to the identity of the recovery policy, not just its
        // address (review §23 full seal manifest).
        if (vault.recoveryGate() != config.recoveryGate) {
            return (false, "CoreVault.recoveryGate != config.recoveryGate");
        }
        if (config.recoveryGate != address(0)) {
            if (RecoveryGate(config.recoveryGate).MANIFEST_VERSION() != config.recoveryManifestVersion) {
                return (false, "RecoveryGate.MANIFEST_VERSION != config.recoveryManifestVersion");
            }
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 9: Strategy roles (if strategy is deployed)
        // ─────────────────────────────────────────────────────────────────────────
        if (config.strategy != address(0)) {
            (bool strategyOk, string memory strategyReason) = _verifyStrategyRoles(config);
            if (!strategyOk) return (false, strategyReason);
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 10: Deployer has no remaining roles
        // ─────────────────────────────────────────────────────────────────────────
        if (config.deployer != address(0) && config.deployer != config.rootTimelock) {
            // Vault owner should not be deployer
            if (vault.owner() == config.deployer) {
                return (false, "Deployer still owns CoreVault");
            }
            // Strategy admin should not be deployer
            if (config.strategy != address(0)) {
                AccessControl strategy = AccessControl(config.strategy);
                bytes32 adminRole = strategy.DEFAULT_ADMIN_ROLE();
                if (strategy.hasRole(adminRole, config.deployer)) {
                    return (false, "Deployer still has strategy DEFAULT_ADMIN_ROLE");
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 11: Dead deposit seeded (inflation attack hardening)
        // ─────────────────────────────────────────────────────────────────────────
        if (!IAdminModule(config.vault).isDeadDepositDone()) {
            return (false, "Dead deposit not seeded - inflation attack risk");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 12: config.globalConfig IS the vault's live params provider
        // ─────────────────────────────────────────────────────────────────────────
        // config.globalConfig is caller-supplied. The vault resolves its own params
        // from CoreStorage (see CoreVault.params()), so without this equality the
        // override check below proves nothing about the configuration the vault
        // actually reads at runtime.
        if (address(vault.params()) != config.globalConfig) {
            return (false, "GlobalConfig not bound to vault");
        }

        // ─────────────────────────────────────────────────────────────────────────
        // INVARIANT 13: Non-6dp vault asset has required GlobalConfig overrides
        // ─────────────────────────────────────────────────────────────────────────
        // GlobalConfig's defaults (defaultVaultDepositCap, defaultMinDeployAmount, etc.)
        // are 6dp/USDC-shaped. An 18dp vault (e.g. WETH) sealed without the per-vault
        // overrides gets a deposit cap of ~0.00001 WETH and a near-zero minDeployAmount —
        // a bricked configuration. The override setters exist but nothing else enforces
        // their use, so require them here before the vault becomes unconfigurable.
        return _verifyDecimalsOverrides(vault, gc, config.vault);
    }

    /// @dev Verify strategy role assignments. Non-reverting so both canSeal()
    ///      and verifyAndSeal() can share it via _verifyLiveState().
    function _verifyStrategyRoles(SealConfig calldata config)
        internal
        view
        returns (bool ok, string memory reason)
    {
        AccessControl strategy = AccessControl(config.strategy);

        bytes32 adminRole = strategy.DEFAULT_ADMIN_ROLE();
        bytes32 paramRole = keccak256("PARAM_ROLE");
        bytes32 coreRole = keccak256("CORE_ROLE");
        bytes32 keeperRole = keccak256("KEEPER_ROLE");

        // ROOT_TIMELOCK must have DEFAULT_ADMIN_ROLE
        if (!strategy.hasRole(adminRole, config.rootTimelock)) {
            return (false, "Strategy: ROOT_TIMELOCK missing DEFAULT_ADMIN_ROLE");
        }

        // ROOT_TIMELOCK must have PARAM_ROLE
        if (!strategy.hasRole(paramRole, config.rootTimelock)) {
            return (false, "Strategy: ROOT_TIMELOCK missing PARAM_ROLE");
        }

        // CoreVault must have CORE_ROLE
        if (!strategy.hasRole(coreRole, config.vault)) {
            return (false, "Strategy: CoreVault missing CORE_ROLE");
        }

        // Guardian should have KEEPER_ROLE (backup)
        if (!strategy.hasRole(keeperRole, config.guardian)) {
            return (false, "Strategy: Guardian missing KEEPER_ROLE (backup)");
        }

        return (true, "");
    }

    /// @dev True unless a non-6dp vault is missing any of the three
    ///      decimals-sensitive GlobalConfig overrides (VAULT_CAP, WITHDRAWAL,
    ///      GOV_CAPS). 6dp vaults match the GlobalConfig defaults and are
    ///      exempt. Non-reverting so both canSeal() and verifyAndSeal() can
    ///      share it via _verifyLiveState().
    function _verifyDecimalsOverrides(CoreVault vault, GlobalConfig gc, address vaultAddr)
        internal
        view
        returns (bool ok, string memory reason)
    {
        uint8 assetDecimals = IERC20Metadata(vault.asset()).decimals();
        if (assetDecimals == 6) return (true, "");

        if (!gc.hasOverride(vaultAddr, GlobalConfig.ParamType.VAULT_CAP)) {
            return (false, "Non-6dp vault missing VAULT_CAP override");
        }
        if (!gc.hasOverride(vaultAddr, GlobalConfig.ParamType.WITHDRAWAL)) {
            return (false, "Non-6dp vault missing WITHDRAWAL override");
        }
        if (!gc.hasOverride(vaultAddr, GlobalConfig.ParamType.GOV_CAPS)) {
            return (false, "Non-6dp vault missing GOV_CAPS override");
        }

        return (true, "");
    }
}
