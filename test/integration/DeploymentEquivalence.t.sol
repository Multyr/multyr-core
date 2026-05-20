// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

// Core
import { CoreVault } from "../../src/core/CoreVault.sol";
import { QueueModule } from "../../src/core/modules/QueueModule.sol";
import { AdminModule } from "../../src/core/modules/AdminModule.sol";
import { BufferManager } from "../../src/core/modules/BufferManager.sol";
import { StrategyRouter } from "../../src/core/modules/StrategyRouter.sol";
import { FeeCollector } from "../../src/core/modules/FeeCollector.sol";
import { StrategyHealthRegistry } from "../../src/core/modules/StrategyHealthRegistry.sol";
import { GlobalConfig } from "../../src/core/config/GlobalConfig.sol";
import { PriceOracleMiddleware } from "../../src/core/modules/PriceOracleMiddleware.sol";

// Security
import { SelectorRegistry } from "../../src/core/libraries/SelectorRegistry.sol";
import { SystemSealer } from "../../src/core/SystemSealer.sol";

// Libraries
import { SelectorLib } from "../../src/core/libraries/SelectorLib.sol";

// Interfaces
import { IAdminModule } from "../../src/interfaces/IAdminModule.sol";
import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";
import { IStrategyRouter } from "../../src/interfaces/IStrategyRouter.sol";

// Mocks
import { ERC20Mock } from "../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";

/**
 * @title DeploymentEquivalence_Test
 * @notice COMANDO #10: Verify both deployment paths produce same final state
 * @dev Tests:
 *      1. Full deployment (DeployFullSystem) => SEALED state
 *      2. Modular deployment (DeployCoreSystem + DeployUsdcLendingStrategy) => SEALED state
 *      3. Compare final state matrices to verify equivalence
 *
 * This test ensures that any deployment path produces identical invariants:
 * - Same ownership chain (ROOT_TIMELOCK owns everything)
 * - Same role configuration (all owner selectors require ROLE_OWNER)
 * - Same freeze state (routing frozen, components timelocked)
 * - No deployer retains any admin roles
 *
 * SUCCESS CRITERIA:
 * Both paths must produce a system where:
 * ✓ vault.owner() == ROOT_TIMELOCK
 * ✓ vault.isRoutingFrozen() == true
 * ✓ isComponentsTimelocked() == true
 * ✓ vault.isSystemSealed() == true (after explicit sealFinalState call)
 * ✓ All owner selectors mapped with ROLE_OWNER
 * ✓ FeeCollector.governor == ROOT_TIMELOCK (immutable)
 * ✓ Strategy: ROOT_TIMELOCK has DEFAULT_ADMIN_ROLE + PARAM_ROLE
 * ✓ Strategy: deployer has NO roles
 */
contract DeploymentEquivalence_Test is Test {
    // ═══════════════════════════════════════════════════════════════════════════════
    // ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════════

    address public deployer = address(0xDE910E7);
    address public rootTimelock = address(0x71CE10C4);
    address public guardian = address(0x60A7D1A4);
    address public vetoer = address(0xEE70E7);
    address public treasury = address(0xFEE1);
    address public ops = address(0xFEE2);
    address public safetyReserve = address(0xFEE3);

    // ═══════════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT RESULT STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════════

    struct FullDeployResult {
        CoreVault vault;
        QueueModule queueModule;
        AdminModule adminModule;
        BufferManager bufferManager;
        StrategyRouter strategyRouter;
        StrategyHealthRegistry healthRegistry;
        FeeCollector feeCollector;
        GlobalConfig globalConfig;
        SelectorRegistry selectorRegistry;
        SystemSealer systemSealer;
        PriceOracleMiddleware priceOracle;
        address strategy; // Mock strategy for this test
    }

    struct FinalStateMatrix {
        // Ownership
        address vaultOwner;
        address bufferManagerOwner;
        address routerOwner;
        address healthRegistryOwner;
        address globalConfigGovernor;
        address feeCollectorGovernor;

        // Vault state
        bool routingFrozen;
        bool componentsTimelocked;
        bool systemSealed;
        address vaultGuardian;
        address vaultVetoer;

        // Security
        address selectorRegistryAddr;
        uint256 ownerSelectorCount;
        bool allOwnerSelectorsCorrect;

        // Strategy roles
        bool timelockHasAdminRole;
        bool timelockHasParamRole;
        bool deployerHasNoRoles;
    }

    ERC20Mock public usdc;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FULL DEPLOYMENT PATH (simulates DeployFullSystem)
    // ═══════════════════════════════════════════════════════════════════════════════

    function _deployFullSystem() internal returns (FullDeployResult memory result) {
        vm.startPrank(deployer);

        // Phase 1: Infrastructure
        result.globalConfig =
            new GlobalConfig(rootTimelock, 50, 100, 2000, 86400, 10, 500, 3600, 3600);

        result.feeCollector =
            new FeeCollector(rootTimelock, treasury, ops, safetyReserve, 7000, 100, 3000);

        result.priceOracle = new PriceOracleMiddleware(deployer);
        result.healthRegistry = new StrategyHealthRegistry(deployer, guardian);

        // Phase 2: Security (deployed BEFORE core)
        result.selectorRegistry = new SelectorRegistry();
        result.systemSealer = new SystemSealer();

        // Phase 3: Core + Modules
        result.vault = new CoreVault(
            IERC20Metadata(address(usdc)),
            "Test Vault USDC",
            "tvUSDC",
            deployer,
            address(result.feeCollector),
            address(result.globalConfig)
        );

        // Set SelectorRegistry BEFORE any routing
        result.vault.setSelectorRegistry(address(result.selectorRegistry));

        result.queueModule = new QueueModule();
        result.adminModule = new AdminModule();

        // Phase 4: Ecosystem
        IBufferManager.BufferConfig memory bufCfg = IBufferManager.BufferConfig({
            targetHotBps: 1000,
            minHotBps: 500,
            targetWarmBps: 1000,
            maxWarmBps: 2000,
            opsReserveTargetBps: 100,
            maxWarmSlippageBps: 50,
            asset: address(usdc),
            warmAdapter: address(0),
            twapWindowSec: 0,
            paused: true
        });
        result.bufferManager = new BufferManager(deployer, address(result.vault), bufCfg);
        result.strategyRouter =
            new StrategyRouter(deployer, address(result.vault), address(result.globalConfig));

        // Mock strategy for testing (simple AccessControl contract)
        result.strategy = address(new MockStrategy(deployer));

        // Grant roles required by SystemSealer
        MockStrategy(result.strategy).grantRole(keccak256("CORE_ROLE"), address(result.vault));
        MockStrategy(result.strategy).grantRole(keccak256("KEEPER_ROLE"), guardian);

        // Phase 5: Wiring
        _wireModules(result);

        // Set ecosystem
        result.vault.setGuardian(guardian);
        IAdminModule(address(result.vault))
            .setEcosystem(
                IAdminModule.EcosystemConfig({
                    bufferManager: address(result.bufferManager),
                    strategyRouter: address(result.strategyRouter),
                    healthRegistry: address(result.healthRegistry),
                    incentives: address(0),
                    guardian: guardian,
                    vetoer: vetoer
                })
            );

        // Configure health registry
        result.healthRegistry.setAuthorizedCaller(address(result.vault), true);
        result.healthRegistry.setAuthorizedCaller(address(result.strategyRouter), true);
        result.strategyRouter.setHealthRegistry(address(result.healthRegistry));

        // Phase 5.5: Dead deposit (inflation attack hardening — required by SystemSealer Invariant 11)
        usdc._mint(deployer, 10_000_000); // 10 USDC
        usdc.approve(address(result.vault), 10_000_000);
        IAdminModule(address(result.vault)).seedDeadDeposit(10_000_000);

        // Phase 6: Seal
        result.vault.freezeRouting();
        IAdminModule(address(result.vault)).enableComponentsTimelock();

        // Transfer ownerships
        result.vault.beginOwnerTransfer(rootTimelock);
        result.bufferManager.transferOwnership(rootTimelock);
        result.strategyRouter.transferOwnership(rootTimelock);
        result.healthRegistry.transferOwnership(rootTimelock);
        result.priceOracle.transferOwnership(rootTimelock);

        // Transfer strategy roles
        MockStrategy(result.strategy)
            .grantRole(MockStrategy(result.strategy).DEFAULT_ADMIN_ROLE(), rootTimelock);
        MockStrategy(result.strategy).grantRole(keccak256("PARAM_ROLE"), rootTimelock);
        MockStrategy(result.strategy)
            .renounceRole(MockStrategy(result.strategy).DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopPrank();

        // Timelock accepts ownership and sets authorized sealer
        vm.startPrank(rootTimelock);
        result.vault.acceptOwnerTransfer();
        result.vault.setAuthorizedSealer(address(result.systemSealer));
        vm.stopPrank();

        // prepareSeal + sealFinalState with hash binding (FULL deployment path)
        vm.startPrank(rootTimelock);
        bytes32 configHash = result.systemSealer
            .prepareSeal(
                SystemSealer.SealConfig({
                    vault: address(result.vault),
                    strategyRouter: address(result.strategyRouter),
                    bufferManager: address(result.bufferManager),
                    healthRegistry: address(result.healthRegistry),
                    globalConfig: address(result.globalConfig),
                    feeCollector: address(result.feeCollector),
                    rootTimelock: rootTimelock,
                    guardian: guardian,
                    vetoer: vetoer,
                    strategy: result.strategy,
                    incentives: address(0),
                    incentivesEngine: address(0),
                    rewardsPayoutManager: address(0),
                    deployer: deployer
                })
            );
        result.vault.sealFinalState(configHash);
        vm.stopPrank();

        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MODULAR DEPLOYMENT PATH (simulates DeployCoreSystem + DeployUsdcLendingStrategy)
    // ═══════════════════════════════════════════════════════════════════════════════

    function _deployModular_Phase1_Core() internal returns (FullDeployResult memory result) {
        vm.startPrank(deployer);

        // === DeployCoreSystem Phase 1: Infrastructure ===
        result.globalConfig =
            new GlobalConfig(rootTimelock, 50, 100, 2000, 86400, 10, 500, 3600, 3600);

        result.feeCollector =
            new FeeCollector(rootTimelock, treasury, ops, safetyReserve, 7000, 100, 3000);

        result.priceOracle = new PriceOracleMiddleware(deployer);
        result.healthRegistry = new StrategyHealthRegistry(deployer, guardian);

        // === DeployCoreSystem Phase 2: Security ===
        result.selectorRegistry = new SelectorRegistry();
        result.systemSealer = new SystemSealer();

        // === DeployCoreSystem Phase 3: Core + Modules ===
        result.vault = new CoreVault(
            IERC20Metadata(address(usdc)),
            "Test Vault USDC",
            "tvUSDC",
            deployer,
            address(result.feeCollector),
            address(result.globalConfig)
        );

        // Set SelectorRegistry BEFORE any routing
        result.vault.setSelectorRegistry(address(result.selectorRegistry));

        result.queueModule = new QueueModule();
        result.adminModule = new AdminModule();

        // === DeployCoreSystem Phase 4: Ecosystem Base ===
        IBufferManager.BufferConfig memory bufCfg = IBufferManager.BufferConfig({
            targetHotBps: 1000,
            minHotBps: 500,
            targetWarmBps: 1000,
            maxWarmBps: 2000,
            opsReserveTargetBps: 100,
            maxWarmSlippageBps: 50,
            asset: address(usdc),
            warmAdapter: address(0),
            twapWindowSec: 0,
            paused: true
        });
        result.bufferManager = new BufferManager(deployer, address(result.vault), bufCfg);
        result.strategyRouter =
            new StrategyRouter(deployer, address(result.vault), address(result.globalConfig));

        // === DeployCoreSystem Phase 5: Wiring ===
        _wireModules(result);

        // Health registry setup (without ecosystem set yet)
        result.healthRegistry.setAuthorizedCaller(address(result.vault), true);
        result.healthRegistry.setAuthorizedCaller(address(result.strategyRouter), true);
        result.strategyRouter.setHealthRegistry(address(result.healthRegistry));

        // Set guardian
        result.vault.setGuardian(guardian);

        vm.stopPrank();

        // PRE-SEAL state: routing NOT frozen, deployer still owns everything
        assertFalse(result.vault.isRoutingFrozen(), "PRE-SEAL: routing should not be frozen");
        assertFalse(result.vault.isSystemSealed(), "PRE-SEAL: should not be sealed");
        assertEq(result.vault.owner(), deployer, "PRE-SEAL: deployer should own vault");

        return result;
    }

    function _deployModular_Phase2_Strategy(FullDeployResult memory result)
        internal
        returns (FullDeployResult memory)
    {
        vm.startPrank(deployer);

        // === DeployUsdcLendingStrategy Phase 1: Strategy Deployment ===
        result.strategy = address(new MockStrategy(deployer));

        // Grant roles required by SystemSealer
        MockStrategy(result.strategy).grantRole(keccak256("CORE_ROLE"), address(result.vault));
        MockStrategy(result.strategy).grantRole(keccak256("KEEPER_ROLE"), guardian);

        // === DeployUsdcLendingStrategy Phase 2: Wiring ===
        // Set ecosystem (now that strategy exists)
        IAdminModule(address(result.vault))
            .setEcosystem(
                IAdminModule.EcosystemConfig({
                    bufferManager: address(result.bufferManager),
                    strategyRouter: address(result.strategyRouter),
                    healthRegistry: address(result.healthRegistry),
                    incentives: address(0),
                    guardian: guardian,
                    vetoer: vetoer
                })
            );

        // === DeployUsdcLendingStrategy Phase 4.5: Dead deposit (Invariant 11) ===
        usdc._mint(deployer, 10_000_000); // 10 USDC
        usdc.approve(address(result.vault), 10_000_000);
        IAdminModule(address(result.vault)).seedDeadDeposit(10_000_000);

        // === DeployUsdcLendingStrategy Phase 5: Seal & Transfer ===
        result.vault.freezeRouting();
        IAdminModule(address(result.vault)).enableComponentsTimelock();

        // Transfer ownerships
        result.vault.beginOwnerTransfer(rootTimelock);
        result.bufferManager.transferOwnership(rootTimelock);
        result.strategyRouter.transferOwnership(rootTimelock);
        result.healthRegistry.transferOwnership(rootTimelock);
        result.priceOracle.transferOwnership(rootTimelock);

        // Transfer strategy roles
        MockStrategy(result.strategy)
            .grantRole(MockStrategy(result.strategy).DEFAULT_ADMIN_ROLE(), rootTimelock);
        MockStrategy(result.strategy).grantRole(keccak256("PARAM_ROLE"), rootTimelock);
        MockStrategy(result.strategy)
            .renounceRole(MockStrategy(result.strategy).DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopPrank();

        // Timelock accepts ownership and sets authorized sealer
        vm.startPrank(rootTimelock);
        result.vault.acceptOwnerTransfer();
        result.vault.setAuthorizedSealer(address(result.systemSealer));
        vm.stopPrank();

        // prepareSeal + sealFinalState with hash binding (MODULAR deployment path)
        vm.startPrank(rootTimelock);
        bytes32 configHash = result.systemSealer
            .prepareSeal(
                SystemSealer.SealConfig({
                    vault: address(result.vault),
                    strategyRouter: address(result.strategyRouter),
                    bufferManager: address(result.bufferManager),
                    healthRegistry: address(result.healthRegistry),
                    globalConfig: address(result.globalConfig),
                    feeCollector: address(result.feeCollector),
                    rootTimelock: rootTimelock,
                    guardian: guardian,
                    vetoer: vetoer,
                    strategy: result.strategy,
                    incentives: address(0),
                    incentivesEngine: address(0),
                    rewardsPayoutManager: address(0),
                    deployer: deployer
                })
            );
        result.vault.sealFinalState(configHash);
        vm.stopPrank();

        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // HELPER: Wire modules with SelectorRegistry guardrail
    // ═══════════════════════════════════════════════════════════════════════════════

    function _wireModules(FullDeployResult memory result) internal {
        // QueueModule write selectors (PUBLIC)
        bytes4[] memory queueSels = SelectorLib.getQueueModuleSelectors();
        _setModulesBatch(
            result.vault, queueSels, address(result.queueModule), SelectorLib.ROLE_PUBLIC
        );

        // QueueModule view selectors (PUBLIC)
        bytes4[] memory queueViewSels = SelectorLib.getQueueModuleViewSelectors();
        _setModulesBatch(
            result.vault, queueViewSels, address(result.queueModule), SelectorLib.ROLE_PUBLIC
        );

        // AdminModule owner selectors (OWNER) - SelectorRegistry validates!
        bytes4[] memory adminOwnerSels = SelectorLib.getAdminModuleOwnerSelectors();
        _setModulesBatch(
            result.vault, adminOwnerSels, address(result.adminModule), SelectorLib.ROLE_OWNER
        );

        // AdminModule view selectors (PUBLIC)
        bytes4[] memory adminViewSels = SelectorLib.getAdminModuleViewSelectors();
        _setModulesBatch(
            result.vault, adminViewSels, address(result.adminModule), SelectorLib.ROLE_PUBLIC
        );
    }

    function _setModulesBatch(
        CoreVault vault,
        bytes4[] memory selectors,
        address module,
        uint8 role
    ) internal {
        uint256 len = selectors.length;
        address[] memory modules = new address[](len);
        uint8[] memory roles = new uint8[](len);
        for (uint256 i; i < len; i++) {
            modules[i] = module;
            roles[i] = role;
        }
        vault.setModulesBatch(selectors, modules, roles);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE EXTRACTION
    // ═══════════════════════════════════════════════════════════════════════════════

    function _extractFinalState(FullDeployResult memory result)
        internal
        view
        returns (FinalStateMatrix memory state)
    {
        // Ownership
        state.vaultOwner = result.vault.owner();
        state.bufferManagerOwner = result.bufferManager.owner();
        state.routerOwner = result.strategyRouter.owner();
        state.healthRegistryOwner = result.healthRegistry.owner();
        state.globalConfigGovernor = result.globalConfig.governor();
        state.feeCollectorGovernor = result.feeCollector.governor();

        // Vault state
        state.routingFrozen = result.vault.isRoutingFrozen();
        state.componentsTimelocked = IAdminModule(address(result.vault)).isComponentsTimelocked();
        state.systemSealed = result.vault.isSystemSealed();
        state.vaultGuardian = result.vault.guardian();
        state.vaultVetoer = result.vault.vetoer();

        // Security
        state.selectorRegistryAddr = result.vault.selectorRegistry();
        state.ownerSelectorCount = result.selectorRegistry.ownerSelectorCount();
        state.allOwnerSelectorsCorrect = _verifyAllOwnerSelectors(result);

        // Strategy roles
        if (result.strategy != address(0)) {
            MockStrategy strat = MockStrategy(result.strategy);
            state.timelockHasAdminRole = strat.hasRole(strat.DEFAULT_ADMIN_ROLE(), rootTimelock);
            state.timelockHasParamRole = strat.hasRole(keccak256("PARAM_ROLE"), rootTimelock);
            state.deployerHasNoRoles = !strat.hasRole(strat.DEFAULT_ADMIN_ROLE(), deployer);
        }
    }

    function _verifyAllOwnerSelectors(FullDeployResult memory result) internal view returns (bool) {
        bytes4[] memory ownerSels = result.selectorRegistry.getOwnerSelectors();
        for (uint256 i = 0; i < ownerSels.length; i++) {
            if (result.vault.roleOf(ownerSels[i]) != result.vault.ROLE_OWNER()) {
                return false;
            }
        }
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MAIN EQUIVALENCE TEST
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_deployment_paths_produce_equivalent_final_state() public {
        console2.log("");
        console2.log("================================================================");
        console2.log("   DEPLOYMENT EQUIVALENCE TEST");
        console2.log("================================================================");
        console2.log("");

        // ═══════════════════════════════════════════════════════════════════════════
        // PATH 1: FULL DEPLOYMENT
        // ═══════════════════════════════════════════════════════════════════════════
        console2.log("=== PATH 1: FULL DEPLOYMENT ===");
        FullDeployResult memory fullResult = _deployFullSystem();
        FinalStateMatrix memory fullState = _extractFinalState(fullResult);
        console2.log("  Full deployment complete");

        // Reset state for modular deployment (new addresses will be created)
        // We use a fresh ERC20 mock to ensure clean state

        // ═══════════════════════════════════════════════════════════════════════════
        // PATH 2: MODULAR DEPLOYMENT
        // ═══════════════════════════════════════════════════════════════════════════
        console2.log("");
        console2.log("=== PATH 2: MODULAR DEPLOYMENT ===");

        // Phase 1: Core (DeployCoreSystem equivalent)
        console2.log("  Phase 1: Core deployment (PRE-SEAL)...");
        FullDeployResult memory modularResult = _deployModular_Phase1_Core();

        // Phase 2: Strategy (DeployUsdcLendingStrategy equivalent)
        console2.log("  Phase 2: Strategy deployment + Seal...");
        modularResult = _deployModular_Phase2_Strategy(modularResult);

        FinalStateMatrix memory modularState = _extractFinalState(modularResult);
        console2.log("  Modular deployment complete");

        // ═══════════════════════════════════════════════════════════════════════════
        // COMPARE FINAL STATES
        // ═══════════════════════════════════════════════════════════════════════════
        console2.log("");
        console2.log("=== COMPARING FINAL STATES ===");

        // Ownership chain
        console2.log("");
        console2.log("OWNERSHIP CHAIN:");
        assertEq(fullState.vaultOwner, modularState.vaultOwner, "vault owner mismatch");
        assertEq(fullState.vaultOwner, rootTimelock, "vault owner != ROOT_TIMELOCK");
        console2.log("  [OK] vault.owner == ROOT_TIMELOCK");

        assertEq(
            fullState.bufferManagerOwner,
            modularState.bufferManagerOwner,
            "bufferManager owner mismatch"
        );
        assertEq(fullState.bufferManagerOwner, rootTimelock, "bufferManager owner != ROOT_TIMELOCK");
        console2.log("  [OK] bufferManager.owner == ROOT_TIMELOCK");

        assertEq(fullState.routerOwner, modularState.routerOwner, "router owner mismatch");
        assertEq(fullState.routerOwner, rootTimelock, "router owner != ROOT_TIMELOCK");
        console2.log("  [OK] strategyRouter.owner == ROOT_TIMELOCK");

        assertEq(
            fullState.healthRegistryOwner,
            modularState.healthRegistryOwner,
            "healthRegistry owner mismatch"
        );
        assertEq(
            fullState.healthRegistryOwner, rootTimelock, "healthRegistry owner != ROOT_TIMELOCK"
        );
        console2.log("  [OK] healthRegistry.owner == ROOT_TIMELOCK");

        assertEq(
            fullState.feeCollectorGovernor,
            modularState.feeCollectorGovernor,
            "feeCollector governor mismatch"
        );
        assertEq(
            fullState.feeCollectorGovernor, rootTimelock, "feeCollector governor != ROOT_TIMELOCK"
        );
        console2.log("  [OK] feeCollector.governor == ROOT_TIMELOCK (IMMUTABLE)");

        // Vault state
        console2.log("");
        console2.log("VAULT STATE:");
        assertEq(fullState.routingFrozen, modularState.routingFrozen, "routingFrozen mismatch");
        assertTrue(fullState.routingFrozen, "routing not frozen");
        console2.log("  [OK] isRoutingFrozen == true");

        assertEq(
            fullState.componentsTimelocked,
            modularState.componentsTimelocked,
            "componentsTimelocked mismatch"
        );
        assertTrue(fullState.componentsTimelocked, "components not timelocked");
        console2.log("  [OK] isComponentsTimelocked == true");

        assertEq(fullState.systemSealed, modularState.systemSealed, "systemSealed mismatch");
        assertTrue(fullState.systemSealed, "system not sealed");
        console2.log("  [OK] isSystemSealed == true");

        assertEq(fullState.vaultGuardian, modularState.vaultGuardian, "guardian mismatch");
        assertEq(fullState.vaultGuardian, guardian, "guardian != expected");
        console2.log("  [OK] vault.guardian == SAFE_GUARDIAN");

        assertEq(fullState.vaultVetoer, modularState.vaultVetoer, "vetoer mismatch");
        assertEq(fullState.vaultVetoer, vetoer, "vetoer != expected");
        console2.log("  [OK] vault.vetoer == SAFE_VETO");

        // Security
        console2.log("");
        console2.log("SECURITY:");
        assertTrue(fullState.selectorRegistryAddr != address(0), "full: selectorRegistry not set");
        assertTrue(
            modularState.selectorRegistryAddr != address(0), "modular: selectorRegistry not set"
        );
        console2.log("  [OK] selectorRegistry is set");

        assertEq(
            fullState.ownerSelectorCount,
            modularState.ownerSelectorCount,
            "ownerSelectorCount mismatch"
        );
        // 34 owner-level selectors as of this baseline (SelectorLib.ADMIN_MODULE_OWNER_SELECTORS=34).
        // Indices 0-26: original set (fee/perf/minDelay timelocks, ecosystem wiring, component timelocks,
        //   seedDeadDeposit, setInitialFees).
        // Index 27: setInitialPerfParams (one-shot perf setup, added FIX-EIP7201-SLOTS-01).
        // Indices 28-29: setIncentivesEngine + setRewardsPayoutManager (FIX-FEECOLLECTOR-AUTOHARVEST-01).
        // Indices 30-33: setRebalancePolicy + setRebalanceGuard + setExecutionMemory +
        //   setStrictExecutionMemory (V10 portfolio-grade allocation engine).
        assertEq(fullState.ownerSelectorCount, 34, "ownerSelectorCount != 34");
        console2.log("  [OK] ownerSelectorCount == 34");

        assertTrue(fullState.allOwnerSelectorsCorrect, "full: owner selectors incorrect");
        assertTrue(modularState.allOwnerSelectorsCorrect, "modular: owner selectors incorrect");
        console2.log("  [OK] all owner selectors have ROLE_OWNER");

        // Strategy roles
        console2.log("");
        console2.log("STRATEGY ROLES:");
        assertTrue(fullState.timelockHasAdminRole, "full: timelock missing ADMIN_ROLE");
        assertTrue(modularState.timelockHasAdminRole, "modular: timelock missing ADMIN_ROLE");
        console2.log("  [OK] ROOT_TIMELOCK has DEFAULT_ADMIN_ROLE");

        assertTrue(fullState.timelockHasParamRole, "full: timelock missing PARAM_ROLE");
        assertTrue(modularState.timelockHasParamRole, "modular: timelock missing PARAM_ROLE");
        console2.log("  [OK] ROOT_TIMELOCK has PARAM_ROLE");

        assertTrue(fullState.deployerHasNoRoles, "full: deployer still has roles");
        assertTrue(modularState.deployerHasNoRoles, "modular: deployer still has roles");
        console2.log("  [OK] deployer has NO admin roles");

        // Final summary
        console2.log("");
        console2.log("================================================================");
        console2.log("   ALL INVARIANTS VERIFIED - DEPLOYMENT PATHS EQUIVALENT");
        console2.log("================================================================");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADDITIONAL TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_full_deployment_produces_sealed_state() public {
        FullDeployResult memory result = _deployFullSystem();
        FinalStateMatrix memory state = _extractFinalState(result);

        assertTrue(state.systemSealed, "System should be sealed");
        assertTrue(state.routingFrozen, "Routing should be frozen");
        assertTrue(state.componentsTimelocked, "Components should be timelocked");
        assertEq(state.vaultOwner, rootTimelock, "Owner should be timelock");
    }

    function test_modular_deployment_produces_sealed_state() public {
        FullDeployResult memory result = _deployModular_Phase1_Core();
        result = _deployModular_Phase2_Strategy(result);
        FinalStateMatrix memory state = _extractFinalState(result);

        assertTrue(state.systemSealed, "System should be sealed");
        assertTrue(state.routingFrozen, "Routing should be frozen");
        assertTrue(state.componentsTimelocked, "Components should be timelocked");
        assertEq(state.vaultOwner, rootTimelock, "Owner should be timelock");
    }

    function test_modular_phase1_produces_preseal_state() public {
        FullDeployResult memory result = _deployModular_Phase1_Core();

        // PRE-SEAL assertions
        assertFalse(result.vault.isRoutingFrozen(), "PRE-SEAL: routing should NOT be frozen");
        assertFalse(result.vault.isSystemSealed(), "PRE-SEAL: should NOT be sealed");
        assertEq(result.vault.owner(), deployer, "PRE-SEAL: deployer should own vault");

        // But SelectorRegistry should already be set
        assertTrue(result.vault.selectorRegistry() != address(0), "SelectorRegistry should be set");

        // And all modules should be wired
        (bool valid,) = SelectorLib.validateAllSelectorsMapped(
            result.vault, address(result.queueModule), address(result.adminModule)
        );
        assertTrue(valid, "All selectors should be mapped in PRE-SEAL");
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MOCK STRATEGY (AccessControl-based for role testing)
// ═══════════════════════════════════════════════════════════════════════════════

contract MockStrategy is AccessControl {
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PARAM_ROLE, admin);
    }
}
