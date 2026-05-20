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

// IncentivesEngine is in core (src/core/modules/IncentivesEngine.sol)
import { IncentivesEngine } from "@multyr-core/core/modules/IncentivesEngine.sol";
import { IIncentivesEngine } from "@multyr-core/interfaces/IIncentivesEngine.sol";

// Periphery (cross-repo -- monorepo phase: @multyr-periphery/=../src/periphery/)
import { RewardsPayoutManager } from "@multyr-periphery/rewards/RewardsPayoutManager.sol";
import { Permit2DepositHelper } from "@multyr-periphery/Permit2DepositHelper.sol";

/// @title DeployCoreIntegrated -- OE core + periphery rewards + Permit2 (out-of-the-box deploy)
/// @notice Deploys the full integrated OE stack: core system + IncentivesEngine + RewardsPayoutManager
///         + Permit2DepositHelper. Vault is functional out of the box without additional periphery steps.
///         Use DeployCoreSystem.s.sol for pure-core deploy (no periphery).
/// @dev Extends DeployCoreSystem with Phase 4.5 (periphery integration).
///      Cross-repo imports: multyr-periphery -- requires multyr-periphery deployed or symlinked.
///      Warm adapters (DEPLOY_WARM_ADAPTERS=true) and upkeep (DEPLOY_UPKEEP=true) optional.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, GOVERNOR_ADDRESS, GUARDIAN_ADDRESS, TREASURY_ADDRESS,
///                  OPS_ADDRESS, SAFETY_RESERVE_ADDRESS, REWARDS_TREASURY_ADDRESS,
///                  TIMELOCK_ADDRESS (opt), VETOER_ADDRESS (opt), CHAINLINK_USDC_FEED (opt),
///                  DEPLOY_WARM_ADAPTERS (opt, default true), DEPLOY_UPKEEP (opt),
///                  OUTPUT_JSON (opt)
/// @custom:post-deploy 1) Run DeployUsdcLendingStrategy.s.sol with vault+ecosystem addresses
///                     2) Timelock: acceptOwnerTransfer + setAuthorizedSealer + sealFinalState
///                     3) Register RewardsPayoutManager distribution schedule
///                     4) Verify all contracts on Arbiscan
contract DeployCoreIntegrated is Script {
    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant MORPHO_GAUNTLET_CORE = 0x7e97fa6893871A2751B5fE961978DCCb2c201E65;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ═══════════════════════════════════════════════════════════════════════════════
    // RESULT STRUCT
    // ═══════════════════════════════════════════════════════════════════════════════

    struct IntegratedDeploymentResult {
        // Core
        VaultFactory vaultFactory;
        GlobalConfig globalConfig;
        FeeCollector feeCollector;
        PriceOracleMiddleware priceOracle;
        StrategyHealthRegistry healthRegistry;
        SelectorRegistry selectorRegistry;
        SystemSealer systemSealer;
        CoreVault vault;
        QueueModule queueModule;
        AdminModule adminModule;
        ERC4626Module erc4626Module;
        LiquidityOpsModule liquidityOpsModule;
        BufferManager bufferManager;
        StrategyRouter strategyRouter;
        AaveV3WarmAdapter_USDC aaveWarmAdapter;
        MorphoVaultWarmAdapter_USDC morphoWarmAdapter;
        Incentives incentives;
        // Periphery
        IncentivesEngine incentivesEngine;
        RewardsPayoutManager rewardsPayoutManager;
        Permit2DepositHelper permit2Helper;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════════

    struct IntegratedConfig {
        uint256 deployerPk;
        address deployer;
        address governor;
        address guardian;
        address treasury;
        address rewardsTreasury;
        address ops;
        address safetyReserve;
        address timelock;
        address vetoer;
        address chainlinkUsdcFeed;
        bool deployWarmAdapters;
        bool deployUpkeep;
        bool configureOracle;
        string outputJsonPath;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MAIN ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════════

    function run() external returns (IntegratedDeploymentResult memory result) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployCoreIntegrated is Arbitrum-only (chainId 42161)"
        );

        IntegratedConfig memory cfg = _loadConfig();

        console.log("");
        console.log("================================================================");
        console.log("   CORE INTEGRATED DEPLOYMENT (OE + Periphery Rewards + Permit2)");
        console.log("================================================================");
        console.log("Deployer:", cfg.deployer);
        console.log("Governor:", cfg.governor);
        console.log("Guardian:", cfg.guardian);
        console.log("RewardsTreasury:", cfg.rewardsTreasury);
        console.log("");

        vm.startBroadcast(cfg.deployerPk);

        console.log("=== PHASE 1: INFRASTRUCTURE ===");
        result = _deployInfra(cfg, result);

        console.log("=== PHASE 2: SECURITY ===");
        result = _deploySecurity(result);

        console.log("=== PHASE 3: CORE + MODULES ===");
        result = _deployCore(cfg, result);

        console.log("=== PHASE 4: ECOSYSTEM BASE ===");
        result = _deployEcosystem(cfg, result);

        console.log("=== PHASE 4.5: PERIPHERY INTEGRATION ===");
        result = _deployPeriphery(cfg, result);

        console.log("=== PHASE 5: WIRING ===");
        _wire(cfg, result);

        console.log("=== PHASE 6: INLINE ASSERTIONS ===");
        require(result.vault.moduleOf(bytes4(keccak256("withdraw(uint256,address,address)"))) == address(result.erc4626Module), "FINAL: withdraw routing");
        require(IAdminModule(address(result.vault)).isFeesInitialized(), "FINAL: fees not initialized");
        require(IAdminModule(address(result.vault)).isDeadDepositDone(), "FINAL: dead deposit not done");
        require(!result.vault.isRoutingFrozen(), "FINAL: routing should NOT be frozen yet");
        require(result.vault.paused(), "FINAL: vault must still be paused");
        require(address(result.incentivesEngine) != address(0), "FINAL: IncentivesEngine not deployed");
        require(address(result.rewardsPayoutManager) != address(0), "FINAL: RewardsPayoutManager not deployed");
        require(address(result.permit2Helper) != address(0), "FINAL: Permit2DepositHelper not deployed");
        console.log("  [OK] All critical assertions passed");

        vm.stopBroadcast();

        console.log("");
        console.log("=== WRITING ADDRESS BOOK ===");
        _writeAddressBook(cfg, result);

        _printSummary(result);
        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 1: INFRASTRUCTURE
    // ═══════════════════════════════════════════════════════════════════════════════

    function _deployInfra(IntegratedConfig memory cfg, IntegratedDeploymentResult memory result)
        internal returns (IntegratedDeploymentResult memory)
    {
        result.vaultFactory = new VaultFactory();
        console.log("[1.1] VaultFactory:", address(result.vaultFactory));

        result.globalConfig = new GlobalConfig(
            cfg.deployer, 25, 25, 1000, 86400, 25, 500, 3600, 86400
        );
        console.log("[1.2] GlobalConfig:", address(result.globalConfig));

        result.feeCollector = new FeeCollector(cfg.timelock, cfg.treasury, cfg.ops, cfg.safetyReserve, 7000, 100, 3000);
        console.log("[1.3] FeeCollector:", address(result.feeCollector));

        result.priceOracle = new PriceOracleMiddleware(cfg.deployer);
        console.log("[1.4] PriceOracleMiddleware:", address(result.priceOracle));

        result.healthRegistry = new StrategyHealthRegistry(cfg.deployer, cfg.guardian);
        console.log("[1.5] StrategyHealthRegistry:", address(result.healthRegistry));

        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 2: SECURITY
    // ═══════════════════════════════════════════════════════════════════════════════

    function _deploySecurity(IntegratedDeploymentResult memory result)
        internal returns (IntegratedDeploymentResult memory)
    {
        result.selectorRegistry = new SelectorRegistry();
        console.log("[2.1] SelectorRegistry:", address(result.selectorRegistry));

        result.systemSealer = new SystemSealer();
        console.log("[2.2] SystemSealer:", address(result.systemSealer));

        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 3: CORE + MODULES
    // ═══════════════════════════════════════════════════════════════════════════════

    function _deployCore(IntegratedConfig memory cfg, IntegratedDeploymentResult memory result)
        internal returns (IntegratedDeploymentResult memory)
    {
        result.vault = new CoreVault(IERC20Metadata(USDC), "Multyr Earn USDC", "meUSDC", cfg.deployer, address(result.feeCollector), address(result.globalConfig));
        console.log("[3.1] CoreVault:", address(result.vault));
        require(result.vault.paused(), "GATE: vault must start PAUSED");

        // Register vault in factory immediately (subgraph event ordering)
        {
            DeployTypes.DeployConfig memory regCfg = DeployTypes.DeployConfig({
                asset: IERC20Metadata(USDC), name: "Multyr Earn USDC", symbol: "meUSDC",
                owner: cfg.governor, feeCollector: address(result.feeCollector),
                paramsProvider: address(result.globalConfig),
                ecosystem: IAdminModule.EcosystemConfig(address(0), address(0), address(0), address(0), address(0), address(0)),
                freezeRouting: false, selectorRegistry: address(result.selectorRegistry)
            });
            result.vaultFactory.registerVault(address(result.vault), abi.encode(regCfg));
            console.log("[3.1b] Vault registered in factory");
        }

        result.queueModule        = new QueueModule();
        result.adminModule        = new AdminModule();
        result.erc4626Module      = new ERC4626Module();
        result.liquidityOpsModule = new LiquidityOpsModule();
        console.log("[3.2-3.5] Modules deployed");

        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 4: ECOSYSTEM BASE
    // ═══════════════════════════════════════════════════════════════════════════════

    function _deployEcosystem(IntegratedConfig memory cfg, IntegratedDeploymentResult memory result)
        internal returns (IntegratedDeploymentResult memory)
    {
        IBufferManager.BufferConfig memory bufCfg = IBufferManager.BufferConfig({
            targetHotBps: 400, minHotBps: 200, targetWarmBps: 600, maxWarmBps: 800,
            opsReserveTargetBps: 400, maxWarmSlippageBps: 50, asset: USDC,
            warmAdapter: address(0), twapWindowSec: 0, paused: false
        });
        result.bufferManager = new BufferManager(cfg.deployer, address(result.vault), bufCfg);
        console.log("[4.1] BufferManager:", address(result.bufferManager));

        IBufferManager.BufferConfig memory v = result.bufferManager.getConfig();
        require(v.targetHotBps + v.targetWarmBps == 1000, "DEPLOY_BUG: hot+warm != 1000");
        require(v.maxWarmBps == 1000 - v.minHotBps, "DEPLOY_BUG: maxWarm != 1000-minHot");
        require(v.opsReserveTargetBps == v.targetHotBps, "DEPLOY_BUG: opsReserve != targetHot");

        result.strategyRouter = new StrategyRouter(cfg.deployer, address(result.vault), address(result.globalConfig));
        console.log("[4.2] StrategyRouter:", address(result.strategyRouter));

        if (cfg.deployWarmAdapters) {
            result.aaveWarmAdapter = new AaveV3WarmAdapter_USDC(address(result.bufferManager), address(result.vault), address(0), address(0));
            result.morphoWarmAdapter = new MorphoVaultWarmAdapter_USDC(address(result.bufferManager), address(result.vault), MORPHO_GAUNTLET_CORE, 5);
            console.log("[4.3] AaveWarmAdapter:", address(result.aaveWarmAdapter));
            console.log("[4.4] MorphoWarmAdapter:", address(result.morphoWarmAdapter));
        }

        // Core Incentives module (optional -- rewarded deposit logic in core)
        IIncentives.Params memory ip = IIncentives.Params({ cliffDays: 30, fullDays: 180, bmaxWad: 3e16, vestingDays: 180 });
        result.incentives = new Incentives(cfg.deployer, address(result.vault), cfg.treasury, ip);
        console.log("[4.5] Incentives:", address(result.incentives));

        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 4.5: PERIPHERY INTEGRATION
    // ═══════════════════════════════════════════════════════════════════════════════

    function _deployPeriphery(IntegratedConfig memory cfg, IntegratedDeploymentResult memory result)
        internal returns (IntegratedDeploymentResult memory)
    {
        // IncentivesEngine: deploy with default params (no-reward mode until governance activates)
        IIncentivesEngine.IncentiveParams memory ieParams = IIncentivesEngine.IncentiveParams({
            cliffDays: 30,
            fullDays: 180,
            vestingDays: 180,
            bmaxWad: 3e16, // 3% max reward rate
            rewardMode: IIncentivesEngine.RewardMode.VaultShares, // default mode; governance activates
            active: false,
            effectiveFrom: 0
        });
        result.incentivesEngine = new IncentivesEngine(address(result.vault), cfg.rewardsTreasury, cfg.timelock, ieParams);
        console.log("[4.5a] IncentivesEngine:", address(result.incentivesEngine));

        // RewardsPayoutManager -- linked to IncentivesEngine
        result.rewardsPayoutManager = new RewardsPayoutManager(
            address(result.incentivesEngine),
            USDC,
            cfg.timelock, // governance
            cfg.rewardsTreasury
        );
        console.log("[4.5b] RewardsPayoutManager:", address(result.rewardsPayoutManager));

        // Permit2DepositHelper -- single-tx deposit via Permit2 signature
        result.permit2Helper = new Permit2DepositHelper(PERMIT2, address(result.vault), USDC);
        console.log("[4.5c] Permit2DepositHelper:", address(result.permit2Helper));

        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PHASE 5: WIRING
    // ═══════════════════════════════════════════════════════════════════════════════

    function _wire(IntegratedConfig memory cfg, IntegratedDeploymentResult memory result) internal {
        // Module routing
        _configureModuleRouting(result);

        // Ecosystem config
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

        result.strategyRouter.setHealthRegistry(address(result.healthRegistry));
        result.bufferManager.refreshWarmNav();
        result.bufferManager.setRebalanceParams(600, 1_000_000, 21600);

        if (cfg.deployWarmAdapters) {
            result.bufferManager.addWarmAdapter(address(result.aaveWarmAdapter));
            result.bufferManager.addWarmAdapter(address(result.morphoWarmAdapter));
            address[] memory warmAdapters = new address[](2);
            warmAdapters[0] = address(result.aaveWarmAdapter);
            warmAdapters[1] = address(result.morphoWarmAdapter);
            result.vault.approveWarmAdapters(warmAdapters);
        }

        result.healthRegistry.setAuthorizedCaller(address(result.vault), true);
        result.healthRegistry.setAuthorizedCaller(address(result.strategyRouter), true);

        if (cfg.configureOracle && cfg.chainlinkUsdcFeed != address(0)) {
            result.priceOracle.setOracleFeed(USDC, cfg.chainlinkUsdcFeed, 86400);
            result.globalConfig.setDefaultOracleConfig(address(result.priceOracle), 86400);
            result.globalConfig.setAssetOracleConfig(USDC, address(result.priceOracle), 86400);
        }

        result.globalConfig.setGovernor(cfg.governor);
        result.vault.setGuardian(cfg.guardian);
        result.vault.setSelectorRegistry(address(result.selectorRegistry));

        if (!IAdminModule(address(result.vault)).isFeesInitialized()) {
            IAdminModule(address(result.vault)).setInitialFees(25, 25, 100, 150, address(result.feeCollector));
        }
        if (!IAdminModule(address(result.vault)).isPerfInitialized()) {
            IAdminModule(address(result.vault)).setInitialPerfParams(6e16, 43200);
        }

        if (!IAdminModule(address(result.vault)).isDeadDepositDone()) {
            IERC20(USDC).approve(address(result.vault), 1_000_000);
            IAdminModule(address(result.vault)).seedDeadDeposit(1_000_000);
        }

        IAdminModule(address(result.vault)).enableComponentsTimelock();

        result.bufferManager.transferOwnership(cfg.timelock);
        result.strategyRouter.transferOwnership(cfg.timelock);
        result.healthRegistry.transferOwnership(cfg.timelock);
        result.priceOracle.transferOwnership(cfg.timelock);
        result.vault.beginOwnerTransfer(cfg.timelock);
        console.log("  [OK] All ownerships transferred/pending to Timelock:", cfg.timelock);
    }

    function _configureModuleRouting(IntegratedDeploymentResult memory result) internal {
        bytes4[] memory queueSels = SelectorLib.getQueueModuleSelectors();
        _setModulesBatch(result.vault, queueSels, address(result.queueModule), SelectorLib.ROLE_PUBLIC);
        bytes4[] memory queueViewSels = SelectorLib.getQueueModuleViewSelectors();
        _setModulesBatch(result.vault, queueViewSels, address(result.queueModule), SelectorLib.ROLE_PUBLIC);
        bytes4[] memory adminOwnerSels = SelectorLib.getAdminModuleOwnerSelectors();
        _setModulesBatch(result.vault, adminOwnerSels, address(result.adminModule), SelectorLib.ROLE_OWNER);
        bytes4[] memory adminViewSels = SelectorLib.getAdminModuleViewSelectors();
        _setModulesBatch(result.vault, adminViewSels, address(result.adminModule), SelectorLib.ROLE_PUBLIC);
        bytes4[] memory erc4626Sels = SelectorLib.getERC4626ModuleSelectors();
        _setModulesBatch(result.vault, erc4626Sels, address(result.erc4626Module), SelectorLib.ROLE_PUBLIC);
        bytes4[] memory liquidityOpsSels = SelectorLib.getLiquidityOpsModuleSelectors();
        _setModulesBatch(result.vault, liquidityOpsSels, address(result.liquidityOpsModule), SelectorLib.ROLE_PUBLIC);
        result.vault.authorizeModule(address(result.erc4626Module), true);

        require(result.vault.moduleOf(bytes4(keccak256("withdraw(uint256,address,address)"))) == address(result.erc4626Module), "GATE: withdraw routing");
        require(result.vault.moduleOf(IQueueModule.requestClaim.selector) == address(result.queueModule), "GATE: requestClaim routing");
        console.log("  [OK] Module routing configured");
    }

    function _setModulesBatch(CoreVault vault, bytes4[] memory selectors, address module, uint8 role) internal {
        uint256 len = selectors.length;
        address[] memory modules = new address[](len);
        uint8[] memory roles = new uint8[](len);
        for (uint256 i; i < len; i++) { modules[i] = module; roles[i] = role; }
        vault.setModulesBatch(selectors, modules, roles);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════

    function _loadConfig() internal view returns (IntegratedConfig memory cfg) {
        cfg.deployerPk     = vm.envUint("DEPLOYER_PRIVATE_KEY");
        cfg.deployer       = vm.addr(cfg.deployerPk);
        cfg.governor       = vm.envAddress("GOVERNOR_ADDRESS");
        cfg.guardian       = vm.envAddress("GUARDIAN_ADDRESS");
        cfg.treasury       = vm.envAddress("TREASURY_ADDRESS");
        cfg.rewardsTreasury = vm.envAddress("REWARDS_TREASURY_ADDRESS");
        cfg.ops            = vm.envAddress("OPS_ADDRESS");
        cfg.safetyReserve  = vm.envAddress("SAFETY_RESERVE_ADDRESS");

        try vm.envAddress("TIMELOCK_ADDRESS") returns (address t) { cfg.timelock = t; }
        catch { cfg.timelock = cfg.governor; }
        try vm.envAddress("VETOER_ADDRESS") returns (address v) { cfg.vetoer = v; }
        catch { cfg.vetoer = address(0); }
        try vm.envAddress("CHAINLINK_USDC_FEED") returns (address feed) {
            cfg.chainlinkUsdcFeed = feed; cfg.configureOracle = true;
        } catch { cfg.chainlinkUsdcFeed = address(0); cfg.configureOracle = false; }
        try vm.envBool("DEPLOY_WARM_ADAPTERS") returns (bool b) { cfg.deployWarmAdapters = b; }
        catch { cfg.deployWarmAdapters = true; }
        try vm.envBool("DEPLOY_UPKEEP") returns (bool b) { cfg.deployUpkeep = b; }
        catch { cfg.deployUpkeep = false; }
        try vm.envString("OUTPUT_JSON") returns (string memory p) { cfg.outputJsonPath = p; }
        catch { cfg.outputJsonPath = "broadcast/core-integrated-addresses.json"; }
    }

    function _writeAddressBook(IntegratedConfig memory cfg, IntegratedDeploymentResult memory result) internal {
        string memory json = "addresses";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "vault", address(result.vault));
        vm.serializeAddress(json, "bufferManager", address(result.bufferManager));
        vm.serializeAddress(json, "strategyRouter", address(result.strategyRouter));
        vm.serializeAddress(json, "feeCollector", address(result.feeCollector));
        vm.serializeAddress(json, "globalConfig", address(result.globalConfig));
        vm.serializeAddress(json, "selectorRegistry", address(result.selectorRegistry));
        vm.serializeAddress(json, "systemSealer", address(result.systemSealer));
        vm.serializeAddress(json, "incentivesEngine", address(result.incentivesEngine));
        vm.serializeAddress(json, "rewardsPayoutManager", address(result.rewardsPayoutManager));
        vm.serializeAddress(json, "permit2Helper", address(result.permit2Helper));
        vm.serializeAddress(json, "timelock", cfg.timelock);
        string memory finalJson = vm.serializeAddress(json, "guardian", cfg.guardian);
        vm.writeJson(finalJson, cfg.outputJsonPath);
        console.log("Address book written to:", cfg.outputJsonPath);
    }

    function _printSummary(IntegratedDeploymentResult memory result) internal pure {
        console.log("================================================================");
        console.log("   CORE INTEGRATED DEPLOYMENT COMPLETE (PRE-SEAL)");
        console.log("================================================================");
        console.log("CoreVault:            ", address(result.vault));
        console.log("BufferManager:        ", address(result.bufferManager));
        console.log("StrategyRouter:       ", address(result.strategyRouter));
        console.log("SelectorRegistry:     ", address(result.selectorRegistry));
        console.log("SystemSealer:         ", address(result.systemSealer));
        console.log("IncentivesEngine:     ", address(result.incentivesEngine));
        console.log("RewardsPayoutManager: ", address(result.rewardsPayoutManager));
        console.log("Permit2DepositHelper: ", address(result.permit2Helper));
        if (address(result.aaveWarmAdapter) != address(0)) {
            console.log("AaveWarmAdapter:      ", address(result.aaveWarmAdapter));
            console.log("MorphoWarmAdapter:    ", address(result.morphoWarmAdapter));
        }
        console.log("================================================================");
        console.log("NEXT: Run DeployUsdcLendingStrategy.s.sol with vault+ecosystem addresses");
        console.log("================================================================");
    }
}
