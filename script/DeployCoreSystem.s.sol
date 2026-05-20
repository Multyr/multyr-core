// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Core
import { CoreVault } from "@multyr-core/core/CoreVault.sol";
import { QueueModule } from "@multyr-core/core/modules/QueueModule.sol";
import { AdminModule } from "@multyr-core/core/modules/AdminModule.sol";
import { ERC4626Module } from "@multyr-core/core/modules/ERC4626Module.sol";
import { LiquidityOpsModule } from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import { BufferManager } from "@multyr-core/core/modules/BufferManager.sol";
import { StrategyRouter } from "@multyr-core/core/modules/StrategyRouter.sol";
import { FeeCollector } from "@multyr-core/core/modules/FeeCollector.sol";
import { StrategyHealthRegistry } from "@multyr-core/core/modules/StrategyHealthRegistry.sol";
import { PriceOracleMiddleware } from "@multyr-core/core/modules/PriceOracleMiddleware.sol";
import { Incentives } from "@multyr-core/core/modules/Incentives.sol";

// Automation
import { VaultUpkeep } from "@multyr-core/automation/VaultUpkeep.sol";

// Warm adapters
import { AaveV3WarmAdapter_USDC } from "@multyr-core/adapters/warm/AaveV3WarmAdapter_USDC.sol";
import { MorphoVaultWarmAdapter_USDC } from "@multyr-core/adapters/warm/MorphoBlueWarmAdapter_USDC.sol";

// Config & Libraries
import { GlobalConfig } from "@multyr-core/core/config/GlobalConfig.sol";
import { SelectorLib } from "@multyr-core/core/libraries/SelectorLib.sol";
import { IBufferManager } from "@multyr-core/interfaces/IBufferManager.sol";
import { IAdminModule } from "@multyr-core/interfaces/IAdminModule.sol";
import { IQueueModule } from "@multyr-core/interfaces/IQueueModule.sol";
import { IIncentives } from "@multyr-core/interfaces/IIncentives.sol";

// Security
import { SelectorRegistry } from "@multyr-core/core/libraries/SelectorRegistry.sol";
import { SystemSealer } from "@multyr-core/core/SystemSealer.sol";

// Factory
import { VaultFactory } from "@multyr-core/factory/VaultFactory.sol";
import { DeployTypes } from "@multyr-core/libs/DeployTypes.sol";

/// @title DeployCoreSystem -- OE pure core deploy (Modular Path B Step 2)
/// @notice Deploys the Multyr Open-Ended vault core system (infrastructure + modules + ecosystem base).
///         Produces a PRE-SEAL state: all module routing configured, dead deposit seeded,
///         components timelock enabled, ownership transfer initiated to ROOT_TIMELOCK.
///         Does NOT deploy periphery (Permit2, rewards, referral) -- use DeployCoreIntegrated for UX.
///         Does NOT deploy strategy -- run DeployUsdcLendingStrategy.s.sol next.
/// @dev Modular Path B Step 2. Order: infra → security → core+modules → ecosystem base → wiring → seal-prep.
///      Warm adapters (optional, deployWarmAdapters=true) and upkeep (optional, deployUpkeep=true)
///      have dedicated standalone scripts: DeployWarmAdapters.s.sol, DeployVaultUpkeep.s.sol.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, GOVERNOR_ADDRESS, GUARDIAN_ADDRESS, TREASURY_ADDRESS,
///                  OPS_ADDRESS, SAFETY_RESERVE_ADDRESS, TIMELOCK_ADDRESS (opt), VETOER_ADDRESS (opt),
///                  DEPLOY_INCENTIVES (opt), DEPLOY_UPKEEP (opt), DEPLOY_WARM_ADAPTERS (opt),
///                  CHAINLINK_USDC_FEED (opt), OUTPUT_JSON (opt)
/// @custom:post-deploy 1) Run DeployUsdcLendingStrategy.s.sol with vault+ecosystem addresses
///                     2) Timelock: acceptOwnerTransfer + setAuthorizedSealer + sealFinalState
///                     3) Verify all contracts on Arbiscan
/// @custom:replaces script/DeployCoreSystem.s.sol (legacy monorepo path)
contract DeployCoreSystem is Script {
    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS - Arbitrum One
    // ═══════════════════════════════════════════════════════════════════════════════

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant MORPHO_GAUNTLET_CORE = 0x7e97fa6893871A2751B5fE961978DCCb2c201E65;

    // ═══════════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT RESULT
    // ═══════════════════════════════════════════════════════════════════════════════

    struct CoreDeploymentResult {
        // Phase 1: Infrastructure
        VaultFactory vaultFactory;
        GlobalConfig globalConfig;
        FeeCollector feeCollector;
        PriceOracleMiddleware priceOracle;
        StrategyHealthRegistry healthRegistry;

        // Phase 2: Security
        SelectorRegistry selectorRegistry;
        SystemSealer systemSealer;

        // Phase 3: Core + Modules
        CoreVault vault;
        QueueModule queueModule;
        AdminModule adminModule;
        ERC4626Module erc4626Module;
        LiquidityOpsModule liquidityOpsModule;

        // Phase 4: Ecosystem Base
        BufferManager bufferManager;
        StrategyRouter strategyRouter;
        AaveV3WarmAdapter_USDC aaveWarmAdapter;
        MorphoVaultWarmAdapter_USDC morphoWarmAdapter;

        // Optional core modules
        Incentives incentives;
        VaultUpkeep upkeep;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════════

    struct CoreConfig {
        uint256 deployerPk;
        address deployer;
        address governor; // ROOT_TIMELOCK
        address guardian; // SAFE_GUARDIAN
        address treasury;
        address ops;
        address safetyReserve;
        address timelock; // Final owner (usually same as governor)
        address vetoer; // SAFE_VETO
        address chainlinkUsdcFeed;
        bool deployIncentives;
        bool deployUpkeep;
        bool deployWarmAdapters;
        bool configureOracle;
        string outputJsonPath;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MAIN ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════════

    function run() external returns (CoreDeploymentResult memory result) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployCoreSystem is Arbitrum-only (chainId 42161)"
        );

        CoreConfig memory cfg = _loadConfig();

        console.log("");
        console.log("================================================================");
        console.log("   CORE SYSTEM DEPLOYMENT -- OE PURE CORE (Modular Path B)");
        console.log("================================================================");
        console.log("");
        console.log("Chain ID:", block.chainid);
        console.log("Block Number:", block.number);
        console.log("Timestamp:", block.timestamp);
        console.log("");
        console.log("Deployer:", cfg.deployer);
        console.log("Governor (ROOT_TIMELOCK):", cfg.governor);
        console.log("Guardian (SAFE_GUARDIAN):", cfg.guardian);
        console.log("Vetoer (SAFE_VETO):", cfg.vetoer);
        console.log("Timelock:", cfg.timelock);
        console.log("");
        console.log("Feature Flags:");
        console.log("  Deploy Warm Adapters:", cfg.deployWarmAdapters);
        console.log("  Deploy Incentives:", cfg.deployIncentives);
        console.log("  Deploy Upkeep:", cfg.deployUpkeep);
        console.log("  Configure Oracle:", cfg.configureOracle);
        console.log("");

        vm.startBroadcast(cfg.deployerPk);

        // Phase 1: Infrastructure
        console.log("=== PHASE 1: INFRASTRUCTURE ===");
        result = _deployPhase1(cfg, result);

        // Phase 2: Security
        console.log("");
        console.log("=== PHASE 2: SECURITY CONTRACTS ===");
        result = _deploySecurityPhase2(cfg, result);

        // Phase 3: Core + Modules
        console.log("");
        console.log("=== PHASE 3: CORE + MODULES ===");
        result = _deployPhase3(cfg, result);

        // Phase 4: Ecosystem Base
        console.log("");
        console.log("=== PHASE 4: ECOSYSTEM BASE ===");
        result = _deployPhase4(cfg, result);

        // Phase 5: Wiring
        console.log("");
        console.log("=== PHASE 5: WIRING (GUARDRAIL ACTIVE) ===");
        _wirePhase5(cfg, result);

        // Phase 6: Inline assertions
        console.log("");
        console.log("=== PHASE 6: INLINE ASSERTIONS ===");
        require(result.vault.moduleOf(bytes4(keccak256("withdraw(uint256,address,address)"))) == address(result.erc4626Module), "FINAL: withdraw routing");
        require(result.vault.moduleOf(bytes4(keccak256("redeem(uint256,address,address)"))) == address(result.erc4626Module), "FINAL: redeem routing");
        require(IAdminModule(address(result.vault)).isFeesInitialized(), "FINAL: fees not initialized");
        require(IAdminModule(address(result.vault)).isDeadDepositDone(), "FINAL: dead deposit not done");
        require(IAdminModule(address(result.vault)).isPerfInitialized(), "FINAL: perf not initialized");
        require(IAdminModule(address(result.vault)).getImmediateExitPenalty() == 100, "FINAL: immediateExitPenalty != 100");
        require(!result.vault.isRoutingFrozen(), "FINAL: routing should NOT be frozen yet");
        require(result.vault.paused(), "FINAL: vault must still be paused");
        console.log("  [OK] All critical assertions passed");

        vm.stopBroadcast();

        // Write JSON address book
        console.log("");
        console.log("=== WRITING ADDRESS BOOK ===");
        _writeAddressBook(cfg, result);

        // Print summary
        console.log("");
        console.log("================================================================");
        console.log("   CORE SYSTEM DEPLOYMENT COMPLETE (PRE-SEAL)");
        console.log("================================================================");
        _printSummary(result);
        _printNextSteps(cfg, result);

        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 1: INFRASTRUCTURE
    // ═══════════════════════════════════════════════════════════════════════════════

    function _deployPhase1(CoreConfig memory cfg, CoreDeploymentResult memory result)
        internal
        returns (CoreDeploymentResult memory)
    {
        // 1.1 VaultFactory
        result.vaultFactory = new VaultFactory();
        console.log("[1.1] VaultFactory:", address(result.vaultFactory));

        // 1.2 GlobalConfig - Deploy with DEPLOYER as temporary governor
        // Governor transferred to ROOT_TIMELOCK after oracle config in Phase 5
        result.globalConfig = new GlobalConfig(
            cfg.deployer, // temporary governor (transferred to timelock later)
            25, // depositFeeBps = 0.25%
            25, // withdrawFeeBps = 0.25%
            1000, // perfFeeBps = 10%
            86400, // lockPeriod = 1 day
            25, // maxActions = 25
            500, // maxNavDeltaBps = 5%
            3600, // minCooldown = 1 hour
            86400 // maxStaleness = 24h (Chainlink USDC/USD heartbeat)
        );
        console.log("[1.2] GlobalConfig:", address(result.globalConfig));
        console.log("      Governor (temp):", cfg.deployer);
        console.log("      Will transfer to:", cfg.governor);

        // 1.3 FeeCollector - governor is IMMUTABLE = ROOT_TIMELOCK
        // SystemSealer.prepareSeal() verifies fc.governor() == config.rootTimelock
        result.feeCollector = new FeeCollector(
            cfg.timelock, // IMMUTABLE governor = ROOT_TIMELOCK
            cfg.treasury,
            cfg.ops,
            cfg.safetyReserve,
            7000, // treasuryBps = 70%
            100, // safetyReserveBps = 1%
            3000 // opsMaxBps = 30% cap
        );
        console.log("[1.3] FeeCollector:", address(result.feeCollector));
        console.log("      Governor (IMMUTABLE):", cfg.timelock);

        // 1.4 PriceOracleMiddleware
        result.priceOracle = new PriceOracleMiddleware(cfg.deployer);
        console.log("[1.4] PriceOracleMiddleware:", address(result.priceOracle));

        // 1.5 StrategyHealthRegistry
        result.healthRegistry = new StrategyHealthRegistry(cfg.deployer, cfg.guardian);
        console.log("[1.5] StrategyHealthRegistry:", address(result.healthRegistry));
        console.log("      Guardian:", cfg.guardian);

        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 2: SECURITY CONTRACTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function _deploySecurityPhase2(CoreConfig memory, CoreDeploymentResult memory result)
        internal
        returns (CoreDeploymentResult memory)
    {
        // 2.1 SelectorRegistry (immutable source of truth for selector-role mappings)
        result.selectorRegistry = new SelectorRegistry();
        console.log("[2.1] SelectorRegistry:", address(result.selectorRegistry));
        console.log("      Owner selectors:", result.selectorRegistry.ownerSelectorCount());
        console.log("      Total registered:", result.selectorRegistry.totalRegisteredSelectors());

        // 2.2 SystemSealer (verification contract for final state)
        result.systemSealer = new SystemSealer();
        console.log("[2.2] SystemSealer:", address(result.systemSealer));

        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 3: CORE + MODULES
    // ═══════════════════════════════════════════════════════════════════════════════

    function _deployPhase3(CoreConfig memory cfg, CoreDeploymentResult memory result)
        internal
        returns (CoreDeploymentResult memory)
    {
        // 3.1 CoreVault (starts PAUSED)
        result.vault = new CoreVault(
            IERC20Metadata(USDC),
            "Multyr Earn USDC",
            "meUSDC",
            cfg.deployer,
            address(result.feeCollector),
            address(result.globalConfig)
        );
        console.log("[3.1] CoreVault:", address(result.vault));
        require(result.vault.paused(), "GATE: vault must start PAUSED");

        // 3.1b CRITICAL: Register vault in factory IMMEDIATELY (subgraph event ordering)
        {
            DeployTypes.DeployConfig memory regCfg = DeployTypes.DeployConfig({
                asset: IERC20Metadata(USDC),
                name: "Multyr Earn USDC",
                symbol: "meUSDC",
                owner: cfg.governor,
                feeCollector: address(result.feeCollector),
                paramsProvider: address(result.globalConfig),
                ecosystem: IAdminModule.EcosystemConfig(address(0), address(0), address(0), address(0), address(0), address(0)),
                freezeRouting: false,
                selectorRegistry: address(result.selectorRegistry)
            });
            result.vaultFactory.registerVault(address(result.vault), abi.encode(regCfg));
            require(result.vaultFactory.isDeployedVault(address(result.vault)), "GATE: vault not in factory");
            console.log("[3.1b] Vault registered in factory (subgraph template active)");
        }

        // 3.2 QueueModule (stateless - no constructor)
        result.queueModule = new QueueModule();
        console.log("[3.2] QueueModule:", address(result.queueModule));

        // 3.3 AdminModule (stateless)
        result.adminModule = new AdminModule();
        console.log("[3.3] AdminModule:", address(result.adminModule));

        // 3.4 ERC4626Module -- must use _ensureFreshWarmNav() (self-healing on deposit/mint)
        result.erc4626Module = new ERC4626Module();
        console.log("[3.4] ERC4626Module:", address(result.erc4626Module));

        // 3.5 LiquidityOpsModule (stateless)
        result.liquidityOpsModule = new LiquidityOpsModule();
        console.log("[3.5] LiquidityOpsModule:", address(result.liquidityOpsModule));

        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 4: ECOSYSTEM BASE
    // ═══════════════════════════════════════════════════════════════════════════════

    function _deployPhase4(CoreConfig memory cfg, CoreDeploymentResult memory result)
        internal
        returns (CoreDeploymentResult memory)
    {
        // 4.1 BufferManager
        // Liquidity policy: Hot(4%) + Warm(6%) = 10% TVL reserve; Cold(90%) → strategy
        IBufferManager.BufferConfig memory bufferCfg = IBufferManager.BufferConfig({
            targetHotBps: 400, // 4% idle in CoreVault
            minHotBps: 200, // 2% trigger for warm refill
            targetWarmBps: 600, // 6% in warm adapters (Aave/Morpho)
            maxWarmBps: 800, // 8% = 1000 - minHotBps (invariant)
            opsReserveTargetBps: 400, // 4% = targetHotBps (routing target)
            maxWarmSlippageBps: 50, // 0.5% slippage cap on warm ops
            asset: USDC,
            warmAdapter: address(0), // deprecated field
            twapWindowSec: 0,
            paused: false
        });
        result.bufferManager = new BufferManager(cfg.deployer, address(result.vault), bufferCfg);
        console.log("[4.1] BufferManager:", address(result.bufferManager));

        // Invariant assertions (audit-grade)
        IBufferManager.BufferConfig memory verifyCfg = result.bufferManager.getConfig();
        require(verifyCfg.targetHotBps + verifyCfg.targetWarmBps == 1000, "DEPLOY_BUG: targetHotBps + targetWarmBps != 1000");
        require(verifyCfg.maxWarmBps == 1000 - verifyCfg.minHotBps, "DEPLOY_BUG: maxWarmBps != 1000 - minHotBps");
        require(verifyCfg.opsReserveTargetBps == verifyCfg.targetHotBps, "DEPLOY_BUG: opsReserveTargetBps != targetHotBps");
        require(verifyCfg.targetHotBps == 400, "DEPLOY_BUG: targetHotBps != 400");
        require(verifyCfg.minHotBps == 200, "DEPLOY_BUG: minHotBps != 200");
        require(verifyCfg.targetWarmBps == 600, "DEPLOY_BUG: targetWarmBps != 600");
        require(verifyCfg.maxWarmBps == 800, "DEPLOY_BUG: maxWarmBps != 800");
        require(verifyCfg.opsReserveTargetBps == 400, "DEPLOY_BUG: opsReserveTargetBps != 400");
        console.log("  [OK] BufferManager: targetHot(4%) + targetWarm(6%) = 10% reserve");

        // 4.2 StrategyRouter
        result.strategyRouter = new StrategyRouter(cfg.deployer, address(result.vault), address(result.globalConfig));
        console.log("[4.2] StrategyRouter:", address(result.strategyRouter));

        // 4.3 Warm adapters (optional -- standalone: DeployWarmAdapters.s.sol)
        if (cfg.deployWarmAdapters) {
            result.aaveWarmAdapter = new AaveV3WarmAdapter_USDC(
                address(result.bufferManager),
                address(result.vault),
                address(0), // use default AAVE_POOL
                address(0) // use default AAVE_DATA_PROVIDER
            );
            console.log("[4.3] AaveV3WarmAdapter:", address(result.aaveWarmAdapter));

            result.morphoWarmAdapter = new MorphoVaultWarmAdapter_USDC(
                address(result.bufferManager),
                address(result.vault),
                MORPHO_GAUNTLET_CORE,
                5 // 0.05% slippage
            );
            console.log("[4.4] MorphoWarmAdapter:", address(result.morphoWarmAdapter));
        }

        // 4.5 Incentives (optional core module -- standalone in DeployCoreIntegrated)
        if (cfg.deployIncentives) {
            IIncentives.Params memory incentiveParams = IIncentives.Params({
                cliffDays: 30,
                fullDays: 180,
                bmaxWad: 3e16, // 3%
                vestingDays: 180
            });
            result.incentives = new Incentives(
                cfg.deployer, address(result.vault), cfg.treasury, incentiveParams
            );
            console.log("[4.5] Incentives:", address(result.incentives));
        }

        // 4.6 VaultUpkeep (optional -- standalone: DeployVaultUpkeep.s.sol)
        if (cfg.deployUpkeep) {
            result.upkeep = new VaultUpkeep(
                address(result.vault),
                address(result.bufferManager),
                address(result.strategyRouter),
                address(result.globalConfig),
                25, // defaultMaxClaims
                100, // hardMaxClaims
                1000000e6, // defaultMaxRealize (1M USDC)
                1000000e6, // defaultMaxDeploy (1M USDC)
                10, // minRealizeGapBps (0.1%)
                10000 // minRealizeFloor (0.01 USDC)
            );
            console.log("[4.6] VaultUpkeep:", address(result.upkeep));
        }

        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 5: WIRING (WITH GUARDRAIL)
    // ═══════════════════════════════════════════════════════════════════════════════

    function _wirePhase5(CoreConfig memory cfg, CoreDeploymentResult memory result) internal {
        // 5.1 Module routing
        console.log("[5.1] Configuring module routing...");
        _configureModuleRouting(result);

        // 5.1b Ecosystem config
        console.log("[5.1b] Setting ecosystem on vault...");
        IAdminModule(address(result.vault)).setEcosystem(
            IAdminModule.EcosystemConfig({
                bufferManager: address(result.bufferManager),
                strategyRouter: address(result.strategyRouter),
                healthRegistry: address(result.healthRegistry),
                incentives: address(0),
                guardian: cfg.guardian,
                vetoer: cfg.vetoer
            })
        );
        console.log("  [OK] Ecosystem configured");

        // 5.2 StrategyRouter: health registry + warm NAV refresh
        console.log("[5.2] Configuring StrategyRouter...");
        result.strategyRouter.setHealthRegistry(address(result.healthRegistry));
        result.bufferManager.refreshWarmNav();
        console.log("[5.2a] BM warm NAV refreshed");

        if (cfg.deployUpkeep) {
            result.bufferManager.setKeeper(address(result.upkeep));
            console.log("[5.2b] BM keeper set to VaultUpkeep:", address(result.upkeep));
        }
        result.bufferManager.setRebalanceParams(600, 1_000_000, 21600);
        console.log("[5.2c] BM rebalanceParams: cooldown=600s, minMove=1M, interval=21600s");

        // 5.3 Warm adapters
        if (cfg.deployWarmAdapters) {
            console.log("[5.3] Configuring BufferManager warm adapters...");
            result.bufferManager.addWarmAdapter(address(result.aaveWarmAdapter));
            result.bufferManager.addWarmAdapter(address(result.morphoWarmAdapter));

            console.log("[5.4] Approving warm adapters for pull pattern...");
            address[] memory warmAdapters = new address[](2);
            warmAdapters[0] = address(result.aaveWarmAdapter);
            warmAdapters[1] = address(result.morphoWarmAdapter);
            result.vault.approveWarmAdapters(warmAdapters);
        }

        // 5.5 HealthRegistry
        console.log("[5.5] Configuring HealthRegistry...");
        result.healthRegistry.setAuthorizedCaller(address(result.vault), true);
        result.healthRegistry.setAuthorizedCaller(address(result.strategyRouter), true);

        // 5.6 Oracle
        if (cfg.configureOracle && cfg.chainlinkUsdcFeed != address(0)) {
            console.log("[5.6] Configuring price oracle feed...");
            result.priceOracle.setOracleFeed(USDC, cfg.chainlinkUsdcFeed, 86400);
            result.globalConfig.setDefaultOracleConfig(address(result.priceOracle), 86400);
            result.globalConfig.setAssetOracleConfig(USDC, address(result.priceOracle), 86400);
            (address o, uint256 s) = result.globalConfig.oracleConfigFor(USDC, address(result.vault));
            require(o == address(result.priceOracle) && s == 86400, "DEPLOY_BUG: oracle registry mismatch");
            console.log("  [OK] Oracle registered in GlobalConfig");
        } else {
            console.log("  WARNING: Oracle not configured (CHAINLINK_USDC_FEED not set)");
            console.log("  StrategyRouter hard-fails without oracle. Configure before deposit ops.");
        }

        // 5.6.2 Transfer GlobalConfig governor to ROOT_TIMELOCK (after oracle config)
        console.log("[5.6.2] Transferring GlobalConfig governor to ROOT_TIMELOCK...");
        result.globalConfig.setGovernor(cfg.governor);
        require(result.globalConfig.governor() == cfg.governor, "DEPLOY_BUG: GlobalConfig governor transfer failed");
        console.log("  [OK] GlobalConfig governor:", cfg.governor);

        // 5.7 Guardian
        console.log("[5.7] Setting guardian on vault...");
        result.vault.setGuardian(cfg.guardian);

        // 5.8 SelectorRegistry (activates guardrail)
        console.log("[5.8] Setting SelectorRegistry (activating guardrail)...");
        result.vault.setSelectorRegistry(address(result.selectorRegistry));
        console.log("  SelectorRegistry set (guardrail NOW active)");

        // 5.9 Initial fees
        console.log("[5.9] Setting initial fees...");
        if (!IAdminModule(address(result.vault)).isFeesInitialized()) {
            IAdminModule(address(result.vault)).setInitialFees(
                25, // depositFeeBps 0.25%
                25, // withdrawFeeBps 0.25%
                100, // immediateExitPenaltyBps 1%
                150, // forceExitPenaltyBps 1.5%
                address(result.feeCollector)
            );
            require(IAdminModule(address(result.vault)).isFeesInitialized(), "DEPLOY_BUG: fees not initialized");
            require(IAdminModule(address(result.vault)).getImmediateExitPenalty() == 100, "DEPLOY_BUG: immediateExitPenaltyBps != 100");
            require(IAdminModule(address(result.vault)).getForceExitPenalty() == 150, "DEPLOY_BUG: forceExitPenaltyBps != 150");
            console.log("  [OK] Fees initialized: deposit=0.25%, withdraw=0.25%, immediate=1%, force=1.5%");
        } else {
            console.log("  [SKIP] Fees already initialized");
        }

        // 5.9b Initial performance fee params
        console.log("[5.9b] Setting initial performance fee params...");
        if (!IAdminModule(address(result.vault)).isPerfInitialized()) {
            IAdminModule(address(result.vault)).setInitialPerfParams(
                6e16, // perfRateX 6% (WAD-scaled)
                43200 // minCrystallizeInterval 12h
            );
            require(IAdminModule(address(result.vault)).isPerfInitialized(), "DEPLOY_BUG: perf not initialized");
            (uint256 rateCheck, uint64 intervalCheck,,) = IAdminModule(address(result.vault)).getPerfParams();
            require(rateCheck == 6e16, "DEPLOY_BUG: perfRateX != 6e16");
            require(intervalCheck == 43200, "DEPLOY_BUG: minCrystallizeInterval != 43200");
            console.log("  [OK] Perf params: rate=6%, interval=12h");
        } else {
            console.log("  [SKIP] Perf params already initialized");
        }

        // 5.10 Seed dead deposit (MANDATORY - inflation attack hardening)
        console.log("[5.10] Seeding dead deposit...");
        if (!IAdminModule(address(result.vault)).isDeadDepositDone()) {
            uint256 deadDepositAmount = 1_000_000; // 1 USDC (6 decimals)
            IERC20(USDC).approve(address(result.vault), deadDepositAmount);
            IAdminModule(address(result.vault)).seedDeadDeposit(deadDepositAmount);
            require(IAdminModule(address(result.vault)).isDeadDepositDone(), "DEPLOY_BUG: dead deposit not done");
            console.log("  [OK] Dead deposit seeded: 1 USDC");
        } else {
            console.log("  [SKIP] Dead deposit already seeded");
        }

        // 5.11 DO NOT freeze routing (per mandate -- freeze after smoke test)
        console.log("[5.11] Routing NOT frozen (freeze after smoke test + strategy wiring)");

        // 5.12 Components timelock
        console.log("[5.12] Enabling components timelock...");
        IAdminModule(address(result.vault)).enableComponentsTimelock();
        console.log("  Components timelock ENABLED");

        // 5.13 Transfer component ownership to ROOT_TIMELOCK
        console.log("[5.13] Transferring component ownerships to ROOT_TIMELOCK...");
        result.bufferManager.transferOwnership(cfg.timelock);
        result.strategyRouter.transferOwnership(cfg.timelock);
        result.healthRegistry.transferOwnership(cfg.timelock);
        result.priceOracle.transferOwnership(cfg.timelock);
        if (cfg.deployUpkeep) {
            result.upkeep.transferOwnership(cfg.timelock);
        }
        result.vault.beginOwnerTransfer(cfg.timelock);
        console.log("  [OK] All ownerships transferred/pending to Timelock:", cfg.timelock);
    }

    function _configureModuleRouting(CoreDeploymentResult memory result) internal {
        bytes4[] memory queueSels = SelectorLib.getQueueModuleSelectors();
        _setModulesBatch(result.vault, queueSels, address(result.queueModule), SelectorLib.ROLE_PUBLIC);
        console.log("  QueueModule write selectors:", queueSels.length);

        bytes4[] memory queueViewSels = SelectorLib.getQueueModuleViewSelectors();
        _setModulesBatch(result.vault, queueViewSels, address(result.queueModule), SelectorLib.ROLE_PUBLIC);
        console.log("  QueueModule view selectors:", queueViewSels.length);

        bytes4[] memory adminOwnerSels = SelectorLib.getAdminModuleOwnerSelectors();
        _setModulesBatch(result.vault, adminOwnerSels, address(result.adminModule), SelectorLib.ROLE_OWNER);
        console.log("  AdminModule owner selectors:", adminOwnerSels.length);

        bytes4[] memory adminViewSels = SelectorLib.getAdminModuleViewSelectors();
        _setModulesBatch(result.vault, adminViewSels, address(result.adminModule), SelectorLib.ROLE_PUBLIC);
        console.log("  AdminModule view selectors:", adminViewSels.length);

        bytes4[] memory erc4626Sels = SelectorLib.getERC4626ModuleSelectors();
        _setModulesBatch(result.vault, erc4626Sels, address(result.erc4626Module), SelectorLib.ROLE_PUBLIC);
        console.log("  ERC4626Module selectors:", erc4626Sels.length);

        bytes4[] memory liquidityOpsSels = SelectorLib.getLiquidityOpsModuleSelectors();
        _setModulesBatch(result.vault, liquidityOpsSels, address(result.liquidityOpsModule), SelectorLib.ROLE_PUBLIC);
        console.log("  LiquidityOpsModule selectors:", liquidityOpsSels.length);

        result.vault.authorizeModule(address(result.erc4626Module), true);
        console.log("  ERC4626Module authorized for processor calls");

        require(result.vault.moduleOf(bytes4(keccak256("withdraw(uint256,address,address)"))) == address(result.erc4626Module), "GATE: withdraw routing");
        require(result.vault.moduleOf(bytes4(keccak256("redeem(uint256,address,address)"))) == address(result.erc4626Module), "GATE: redeem routing");
        require(result.vault.moduleOf(IQueueModule.requestClaim.selector) == address(result.queueModule), "GATE: requestClaim routing");
        require(result.vault.moduleOf(IQueueModule.settleFeesAndProcessQueue.selector) == address(result.queueModule), "GATE: settle routing");
        console.log("  [OK] Critical selector routing verified");
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
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════

    function _loadConfig() internal view returns (CoreConfig memory cfg) {
        cfg.deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        cfg.deployer = vm.addr(cfg.deployerPk);

        cfg.governor = vm.envAddress("GOVERNOR_ADDRESS");
        cfg.guardian = vm.envAddress("GUARDIAN_ADDRESS");
        cfg.treasury = vm.envAddress("TREASURY_ADDRESS");
        cfg.ops = vm.envAddress("OPS_ADDRESS");
        cfg.safetyReserve = vm.envAddress("SAFETY_RESERVE_ADDRESS");

        try vm.envAddress("TIMELOCK_ADDRESS") returns (address t) { cfg.timelock = t; }
        catch { cfg.timelock = cfg.governor; }

        try vm.envAddress("VETOER_ADDRESS") returns (address v) { cfg.vetoer = v; }
        catch { cfg.vetoer = address(0); }

        try vm.envAddress("CHAINLINK_USDC_FEED") returns (address feed) {
            cfg.chainlinkUsdcFeed = feed;
            cfg.configureOracle = true;
        } catch {
            cfg.chainlinkUsdcFeed = address(0);
            cfg.configureOracle = false;
        }

        try vm.envBool("DEPLOY_INCENTIVES") returns (bool b) { cfg.deployIncentives = b; }
        catch { cfg.deployIncentives = false; }

        try vm.envBool("DEPLOY_UPKEEP") returns (bool b) { cfg.deployUpkeep = b; }
        catch { cfg.deployUpkeep = false; }

        try vm.envBool("DEPLOY_WARM_ADAPTERS") returns (bool b) { cfg.deployWarmAdapters = b; }
        catch { cfg.deployWarmAdapters = true; }

        try vm.envString("OUTPUT_JSON") returns (string memory p) { cfg.outputJsonPath = p; }
        catch { cfg.outputJsonPath = "broadcast/core-addresses.json"; }
    }

    function _writeAddressBook(CoreConfig memory cfg, CoreDeploymentResult memory result) internal {
        string memory json = "addresses";

        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "blockNumber", block.number);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeAddress(json, "deployer", cfg.deployer);
        vm.serializeString(json, "state", "PRE-SEAL");

        vm.serializeAddress(json, "vaultFactory", address(result.vaultFactory));
        vm.serializeAddress(json, "globalConfig", address(result.globalConfig));
        vm.serializeAddress(json, "feeCollector", address(result.feeCollector));
        vm.serializeAddress(json, "priceOracle", address(result.priceOracle));
        vm.serializeAddress(json, "healthRegistry", address(result.healthRegistry));

        vm.serializeAddress(json, "selectorRegistry", address(result.selectorRegistry));
        vm.serializeAddress(json, "systemSealer", address(result.systemSealer));

        vm.serializeAddress(json, "vault", address(result.vault));
        vm.serializeAddress(json, "queueModule", address(result.queueModule));
        vm.serializeAddress(json, "adminModule", address(result.adminModule));
        vm.serializeAddress(json, "erc4626Module", address(result.erc4626Module));
        vm.serializeAddress(json, "liquidityOpsModule", address(result.liquidityOpsModule));

        vm.serializeAddress(json, "bufferManager", address(result.bufferManager));
        vm.serializeAddress(json, "strategyRouter", address(result.strategyRouter));
        vm.serializeAddress(json, "aaveWarmAdapter", address(result.aaveWarmAdapter));
        vm.serializeAddress(json, "morphoWarmAdapter", address(result.morphoWarmAdapter));
        vm.serializeAddress(json, "incentives", address(result.incentives));
        vm.serializeAddress(json, "upkeep", address(result.upkeep));

        vm.serializeAddress(json, "governor", cfg.governor);
        vm.serializeAddress(json, "guardian", cfg.guardian);
        vm.serializeAddress(json, "treasury", cfg.treasury);
        vm.serializeAddress(json, "ops", cfg.ops);
        vm.serializeAddress(json, "safetyReserve", cfg.safetyReserve);
        vm.serializeAddress(json, "timelock", cfg.timelock);
        string memory finalJson = vm.serializeAddress(json, "vetoer", cfg.vetoer);

        vm.writeJson(finalJson, cfg.outputJsonPath);
        console.log("Address book written to:", cfg.outputJsonPath);
    }

    function _printSummary(CoreDeploymentResult memory result) internal pure {
        console.log("");
        console.log("=== DEPLOYED CONTRACTS ===");
        console.log("Infrastructure:");
        console.log("  VaultFactory:        ", address(result.vaultFactory));
        console.log("  GlobalConfig:        ", address(result.globalConfig));
        console.log("  FeeCollector:        ", address(result.feeCollector));
        console.log("  PriceOracle:         ", address(result.priceOracle));
        console.log("  HealthRegistry:      ", address(result.healthRegistry));
        console.log("Security:");
        console.log("  SelectorRegistry:    ", address(result.selectorRegistry));
        console.log("  SystemSealer:        ", address(result.systemSealer));
        console.log("Core:");
        console.log("  CoreVault:           ", address(result.vault));
        console.log("  QueueModule:         ", address(result.queueModule));
        console.log("  AdminModule:         ", address(result.adminModule));
        console.log("  ERC4626Module:       ", address(result.erc4626Module));
        console.log("  LiquidityOpsModule:  ", address(result.liquidityOpsModule));
        console.log("Ecosystem Base:");
        console.log("  BufferManager:       ", address(result.bufferManager));
        console.log("  StrategyRouter:      ", address(result.strategyRouter));
        if (address(result.aaveWarmAdapter) != address(0)) {
            console.log("  AaveWarmAdapter:     ", address(result.aaveWarmAdapter));
            console.log("  MorphoWarmAdapter:   ", address(result.morphoWarmAdapter));
        }
        if (address(result.incentives) != address(0)) {
            console.log("  Incentives:          ", address(result.incentives));
        }
        if (address(result.upkeep) != address(0)) {
            console.log("  VaultUpkeep:         ", address(result.upkeep));
        }
    }

    function _printNextSteps(CoreConfig memory cfg, CoreDeploymentResult memory result)
        internal
        view
    {
        console.log("");
        console.log("=== NEXT STEPS ===");
        console.log("State: PRE-SEAL (routing not frozen, ownership transfer pending)");
        console.log("");
        console.log("1. Deploy strategy:");
        console.log("   VAULT_ADDRESS=", address(result.vault));
        console.log("   STRATEGY_ROUTER_ADDRESS=", address(result.strategyRouter));
        console.log("   BUFFER_MANAGER_ADDRESS=", address(result.bufferManager));
        console.log("   HEALTH_REGISTRY_ADDRESS=", address(result.healthRegistry));
        console.log("   GLOBAL_CONFIG_ADDRESS=", address(result.globalConfig));
        console.log("   PRICE_ORACLE_ADDRESS=", address(result.priceOracle));
        console.log("   FEE_COLLECTOR_ADDRESS=", address(result.feeCollector));
        console.log("   SELECTOR_REGISTRY_ADDRESS=", address(result.selectorRegistry));
        console.log("   SYSTEM_SEALER_ADDRESS=", address(result.systemSealer));
        console.log("   GUARDIAN_ADDRESS=", cfg.guardian);
        console.log("   TIMELOCK_ADDRESS=", cfg.timelock);
        console.log("2. Timelock: acceptOwnerTransfer + setAuthorizedSealer + sealFinalState");
        console.log("3. Verify all contracts on Arbiscan");
        console.log("4. See docs/09-audit/deployment-flow.md for full Modular Path B sequence");
    }
}
