// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Core
import { CoreVault } from "@multyr-core/core/CoreVault.sol";
import { QueueModule } from "@multyr-core/core/modules/QueueModule.sol";
import { AdminModule } from "@multyr-core/core/modules/AdminModule.sol";
import { ERC4626Module } from "@multyr-core/core/modules/ERC4626Module.sol";
import { LiquidityOpsModule } from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import { FixedMaturityModule } from "@multyr-core/core/modules/FixedMaturityModule.sol";
import { BufferManager } from "@multyr-core/core/modules/BufferManager.sol";
import { StrategyRouter } from "@multyr-core/core/modules/StrategyRouter.sol";
import { FeeCollector } from "@multyr-core/core/modules/FeeCollector.sol";
import { StrategyHealthRegistry } from "@multyr-core/core/modules/StrategyHealthRegistry.sol";
import { PriceOracleMiddleware } from "@multyr-core/core/modules/PriceOracleMiddleware.sol";
import { GlobalConfig } from "@multyr-core/core/config/GlobalConfig.sol";

// Libraries
import { SelectorLib } from "@multyr-core/core/libraries/SelectorLib.sol";
import { SelectorRegistry } from "@multyr-core/core/libraries/SelectorRegistry.sol";

// Interfaces
import { IFixedMaturityModule } from "@multyr-core/interfaces/IFixedMaturityModule.sol";
import { VaultMode, VaultState } from "@multyr-core/core/storage/FixedMaturityStorage.sol";
import { IAdminModule } from "@multyr-core/interfaces/IAdminModule.sol";
import { IBufferManager } from "@multyr-core/interfaces/IBufferManager.sol";

// Periphery (cross-repo -- available via @multyr-periphery/ alias)
import { Permit2DepositHelper } from "@multyr-periphery/Permit2DepositHelper.sol";

/// @title DeployFixedMaturityVaultIntegrated -- FM core + Permit2 (out-of-the-box deploy)
/// @notice Deploys a full FM vault with Permit2DepositHelper for one-click deposits.
///         Use DeployFixedMaturityVault.s.sol for pure-core deploy (no periphery).
///         Upkeep deployed separately via DeployFixedMaturityVaultUpkeep.s.sol.
/// @dev Follows the same 9-phase order as DeployFixedMaturityVault with Phase 3 adding Permit2.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, GOVERNOR_ADDRESS, GUARDIAN_ADDRESS, TREASURY_ADDRESS,
///                  OPS_ADDRESS, SAFETY_RESERVE_ADDRESS, FIXED_TERM_STRATEGY, FM_MATURITY_TS,
///                  FM_FUNDING_DEADLINE_TS, FM_MIN_FUNDING_ASSETS, FM_TARGET_FUNDING_ASSETS,
///                  TIMELOCK_ADDRESS (opt), CHAINLINK_USDC_FEED (opt), FM_AUTO_CLOSE (opt),
///                  FM_INSTANT_EXIT (opt), FM_FORCE_PENALTY_BPS (opt), VAULT_NAME (opt), VAULT_SYMBOL (opt)
/// @custom:post-deploy 1) Deploy upkeep: DeployFixedMaturityVaultUpkeep.s.sol FM_VAULT_ADDRESS=<vault>
///                     2) Register FixedMaturityVaultUpkeep on Chainlink Automation
///                     3) Unpause vault after final safety check
///                     4) Transfer vault ownership to timelock
contract DeployFixedMaturityVaultIntegrated is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;

    address constant USDC               = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant PERMIT2            = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant CHAINLINK_USDC_ARB = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

    // =========================================================================
    // RESULT STRUCT
    // =========================================================================

    struct FMIntegratedResult {
        CoreVault              vault;
        QueueModule            queueModule;
        AdminModule            adminModule;
        ERC4626Module          erc4626Module;
        LiquidityOpsModule     liquidityOpsModule;
        FixedMaturityModule    fixedMaturityModule;
        BufferManager          bufferManager;
        StrategyRouter         strategyRouter;
        FeeCollector           feeCollector;
        StrategyHealthRegistry healthRegistry;
        PriceOracleMiddleware  priceOracle;
        GlobalConfig           globalConfig;
        SelectorRegistry       selectorRegistry;
        Permit2DepositHelper   permit2Helper;
    }

    // =========================================================================
    // CONFIG STRUCT
    // =========================================================================

    struct FMConfig {
        uint256 deployerPk;
        address deployer;
        address governor;
        address guardian;
        address treasury;
        address ops;
        address safetyReserve;
        address timelock;
        address chainlinkFeed;
        string  vaultName;
        string  vaultSymbol;
        address fixedTermStrategy;
        uint64  maturityTs;
        uint64  fundingDeadlineTs;
        uint256 minFundingAssets;
        uint256 targetFundingAssets;
        bool    autoClose;
        bool    instantExit;
        uint256 forcePenaltyBps;
    }

    // =========================================================================
    // MAIN ENTRY POINT
    // =========================================================================

    function run() external returns (FMIntegratedResult memory result) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployFixedMaturityVaultIntegrated is Arbitrum One only (chainId 42161)"
        );

        FMConfig memory cfg = _loadConfig();
        _printConfig(cfg);

        vm.startBroadcast(cfg.deployerPk);

        console.log("=== PHASE 1: INFRASTRUCTURE ===");
        result = _deployPhase1(cfg, result);

        console.log("=== PHASE 2: CORE + MODULES ===");
        result = _deployPhase2(cfg, result);

        console.log("=== PHASE 3: ECOSYSTEM + PERIPHERY ===");
        result = _deployPhase3(cfg, result);

        console.log("=== PHASE 4: MODULE ROUTING (no guardrail yet) ===");
        _wireModules(result);

        console.log("=== PHASE 5: FM CONFIGURATION ===");
        _configureFM(cfg, result);

        console.log("=== PHASE 6: ECOSYSTEM WIRING ===");
        _wireEcosystem(cfg, result);

        console.log("=== PHASE 7: SELECTOR REGISTRY (guardrail active) ===");
        result.vault.setSelectorRegistry(address(result.selectorRegistry));
        console.log("  [OK] SelectorRegistry active");

        console.log("=== PHASE 8: SEED DEAD DEPOSIT (MANDATORY) ===");
        IAdminModule(address(result.vault)).seedDeadDeposit(1e6);
        require(IAdminModule(address(result.vault)).isDeadDepositDone(), "SEED: dead deposit failed");
        console.log("  [OK] Dead deposit seeded");

        console.log("=== PHASE 9: FINAL ASSERTIONS ===");
        _assertFinalState(cfg, result);

        vm.stopBroadcast();

        _printSummary(result);
        return result;
    }

    // =========================================================================
    // PHASE 1: INFRASTRUCTURE
    // =========================================================================

    function _deployPhase1(FMConfig memory cfg, FMIntegratedResult memory result)
        internal returns (FMIntegratedResult memory)
    {
        result.globalConfig = new GlobalConfig(cfg.deployer, 25, 25, 1000, 86400, 25, 500, 3600, 86400);
        console.log("[1.1] GlobalConfig:", address(result.globalConfig));

        result.feeCollector = new FeeCollector(cfg.timelock, cfg.treasury, cfg.ops, cfg.safetyReserve, 7000, 100, 3000);
        console.log("[1.2] FeeCollector:", address(result.feeCollector));

        result.priceOracle = new PriceOracleMiddleware(cfg.deployer);
        console.log("[1.3] PriceOracleMiddleware:", address(result.priceOracle));

        result.healthRegistry = new StrategyHealthRegistry(cfg.deployer, cfg.guardian);
        console.log("[1.4] StrategyHealthRegistry:", address(result.healthRegistry));

        result.selectorRegistry = new SelectorRegistry();
        console.log("[1.5] SelectorRegistry:", address(result.selectorRegistry));

        return result;
    }

    // =========================================================================
    // PHASE 2: CORE + MODULES
    // =========================================================================

    function _deployPhase2(FMConfig memory cfg, FMIntegratedResult memory result)
        internal returns (FMIntegratedResult memory)
    {
        result.vault = new CoreVault(IERC20Metadata(USDC), cfg.vaultName, cfg.vaultSymbol, cfg.deployer, address(result.feeCollector), address(result.globalConfig));
        console.log("[2.1] CoreVault:", address(result.vault));
        require(result.vault.paused(), "GATE: vault must start PAUSED");

        result.queueModule         = new QueueModule();
        result.adminModule         = new AdminModule();
        result.erc4626Module       = new ERC4626Module();
        result.liquidityOpsModule  = new LiquidityOpsModule();
        result.fixedMaturityModule = new FixedMaturityModule();
        console.log("[2.2-2.6] Modules deployed");

        return result;
    }

    // =========================================================================
    // PHASE 3: ECOSYSTEM + PERIPHERY
    // =========================================================================

    function _deployPhase3(FMConfig memory cfg, FMIntegratedResult memory result)
        internal returns (FMIntegratedResult memory)
    {
        IBufferManager.BufferConfig memory bufCfg = IBufferManager.BufferConfig({
            targetHotBps: 400, minHotBps: 200, targetWarmBps: 600, maxWarmBps: 800,
            opsReserveTargetBps: 400, maxWarmSlippageBps: 50, asset: USDC,
            warmAdapter: address(0), twapWindowSec: 0, paused: false
        });
        result.bufferManager = new BufferManager(cfg.deployer, address(result.vault), bufCfg);
        console.log("[3.1] BufferManager:", address(result.bufferManager));

        IBufferManager.BufferConfig memory v = result.bufferManager.getConfig();
        require(v.targetHotBps + v.targetWarmBps == 1000, "DEPLOY_BUG: hot+warm != 1000");
        require(v.maxWarmBps == 1000 - v.minHotBps, "DEPLOY_BUG: maxWarm != 1000-minHot");
        require(v.opsReserveTargetBps == v.targetHotBps, "DEPLOY_BUG: opsReserve != targetHot");

        result.strategyRouter = new StrategyRouter(cfg.deployer, address(result.vault), address(result.globalConfig));
        console.log("[3.2] StrategyRouter:", address(result.strategyRouter));

        result.permit2Helper = new Permit2DepositHelper(PERMIT2, address(result.vault), USDC);
        console.log("[3.3] Permit2DepositHelper:", address(result.permit2Helper));

        return result;
    }

    // =========================================================================
    // PHASE 4: MODULE ROUTING
    // =========================================================================

    function _wireModules(FMIntegratedResult memory result) internal {
        _setModulesBatch(result.vault, SelectorLib.getQueueModuleSelectors(), address(result.queueModule), SelectorLib.ROLE_PUBLIC);
        _setModulesBatch(result.vault, SelectorLib.getQueueModuleViewSelectors(), address(result.queueModule), SelectorLib.ROLE_PUBLIC);
        _setModulesBatch(result.vault, SelectorLib.getAdminModuleOwnerSelectors(), address(result.adminModule), SelectorLib.ROLE_OWNER);
        _setModulesBatch(result.vault, SelectorLib.getAdminModuleViewSelectors(), address(result.adminModule), SelectorLib.ROLE_PUBLIC);
        _setModulesBatch(result.vault, SelectorLib.getERC4626ModuleSelectors(), address(result.erc4626Module), SelectorLib.ROLE_PUBLIC);
        _setModulesBatch(result.vault, SelectorLib.getLiquidityOpsModuleSelectors(), address(result.liquidityOpsModule), SelectorLib.ROLE_PUBLIC);
        _setModulesBatch(result.vault, SelectorLib.getFixedMaturityModuleSelectors(), address(result.fixedMaturityModule), SelectorLib.ROLE_PUBLIC);

        result.vault.authorizeModule(address(result.erc4626Module), true);
        result.vault.authorizeModule(address(result.fixedMaturityModule), true);

        require(result.vault.moduleOf(bytes4(keccak256("withdraw(uint256,address,address)"))) == address(result.erc4626Module), "GATE: withdraw routing");
        require(result.vault.moduleOf(IFixedMaturityModule.setVaultModeFixedMaturity.selector) == address(result.fixedMaturityModule), "GATE: FM routing");
        console.log("  [OK] Critical routing verified");
    }

    // =========================================================================
    // PHASE 5: FM CONFIGURATION
    // =========================================================================

    function _configureFM(FMConfig memory cfg, FMIntegratedResult memory result) internal {
        IFixedMaturityModule fm = IFixedMaturityModule(address(result.vault));
        fm.setVaultModeFixedMaturity();
        fm.configureFixedMaturity(cfg.maturityTs, cfg.minFundingAssets, cfg.targetFundingAssets, cfg.fundingDeadlineTs, cfg.autoClose, cfg.instantExit, cfg.forcePenaltyBps, cfg.fixedTermStrategy);

        (VaultMode mode_, VaultState state_) = fm.currentVaultModeAndState();
        require(uint8(mode_) == 1, "ASSERT: not FixedMaturity mode");
        require(uint8(state_) == 0, "ASSERT: not Funding state");
        console.log("  [OK] FM State: FixedMaturity/Funding");
    }

    // =========================================================================
    // PHASE 6: ECOSYSTEM WIRING
    // =========================================================================

    function _wireEcosystem(FMConfig memory cfg, FMIntegratedResult memory result) internal {
        IAdminModule(address(result.vault)).setEcosystem(
            IAdminModule.EcosystemConfig({
                bufferManager: address(result.bufferManager), strategyRouter: address(result.strategyRouter),
                healthRegistry: address(result.healthRegistry), incentives: address(0),
                guardian: cfg.guardian, vetoer: address(0)
            })
        );

        result.strategyRouter.setHealthRegistry(address(result.healthRegistry));
        result.healthRegistry.setAuthorizedCaller(address(result.vault), true);
        result.healthRegistry.setAuthorizedCaller(address(result.strategyRouter), true);
        result.bufferManager.refreshWarmNav();

        if (cfg.chainlinkFeed != address(0)) {
            result.priceOracle.setOracleFeed(USDC, cfg.chainlinkFeed, 86400);
            result.globalConfig.setDefaultOracleConfig(address(result.priceOracle), 86400);
            result.globalConfig.setAssetOracleConfig(USDC, address(result.priceOracle), 86400);
        }

        result.globalConfig.setGovernor(cfg.governor);

        if (!IAdminModule(address(result.vault)).isFeesInitialized()) {
            IAdminModule(address(result.vault)).setInitialFees(25, 25, 100, 150, address(result.feeCollector));
        }

        IAdminModule(address(result.vault)).submitPerfParams(1000, 0);
        IAdminModule(address(result.vault)).acceptPerfParams();
        console.log("  [OK] Ecosystem wired");
    }

    // =========================================================================
    // PHASE 9: FINAL ASSERTIONS
    // =========================================================================

    function _assertFinalState(FMConfig memory cfg, FMIntegratedResult memory result) internal view {
        IFixedMaturityModule fm = IFixedMaturityModule(address(result.vault));
        IAdminModule admin = IAdminModule(address(result.vault));

        (VaultMode mode_, VaultState state_) = fm.currentVaultModeAndState();
        require(uint8(mode_) == 1 && uint8(state_) == 0, "ASSERT: not FixedMaturity/Funding");
        require(fm.maturityTs() == cfg.maturityTs, "ASSERT: maturityTs");
        require(fm.fixedTermStrategy() == cfg.fixedTermStrategy, "ASSERT: fixedTermStrategy");
        require(fm.isDepositOpen(), "ASSERT: deposits must be open");
        require(admin.isFeesInitialized(), "ASSERT: fees not initialized");
        require(admin.isDeadDepositDone(), "ASSERT: dead deposit not done");
        require(result.vault.paused(), "ASSERT: vault must still be paused");
        require(address(result.permit2Helper) != address(0), "ASSERT: Permit2DepositHelper missing");
        console.log("  [OK] All final assertions passed");
    }

    // =========================================================================
    // CONFIG LOADING
    // =========================================================================

    function _loadConfig() internal view returns (FMConfig memory cfg) {
        cfg.deployerPk       = vm.envUint("DEPLOYER_PRIVATE_KEY");
        cfg.deployer         = vm.addr(cfg.deployerPk);
        cfg.governor         = vm.envAddress("GOVERNOR_ADDRESS");
        cfg.guardian         = vm.envAddress("GUARDIAN_ADDRESS");
        cfg.treasury         = vm.envAddress("TREASURY_ADDRESS");
        cfg.ops              = vm.envAddress("OPS_ADDRESS");
        cfg.safetyReserve    = vm.envAddress("SAFETY_RESERVE_ADDRESS");
        cfg.timelock         = vm.envOr("TIMELOCK_ADDRESS", cfg.governor);
        cfg.chainlinkFeed    = vm.envOr("CHAINLINK_USDC_FEED", CHAINLINK_USDC_ARB);
        cfg.vaultName        = vm.envOr("VAULT_NAME",   string("Multyr Fixed Maturity USDC"));
        cfg.vaultSymbol      = vm.envOr("VAULT_SYMBOL", string("mFM-USDC"));

        cfg.fixedTermStrategy   = vm.envAddress("FIXED_TERM_STRATEGY");
        cfg.maturityTs          = uint64(vm.envUint("FM_MATURITY_TS"));
        cfg.fundingDeadlineTs   = uint64(vm.envUint("FM_FUNDING_DEADLINE_TS"));
        cfg.minFundingAssets    = vm.envUint("FM_MIN_FUNDING_ASSETS");
        cfg.targetFundingAssets = vm.envUint("FM_TARGET_FUNDING_ASSETS");
        cfg.autoClose           = vm.envOr("FM_AUTO_CLOSE",         true);
        cfg.instantExit         = vm.envOr("FM_INSTANT_EXIT",       true);
        cfg.forcePenaltyBps     = vm.envOr("FM_FORCE_PENALTY_BPS", uint256(500));

        require(cfg.fixedTermStrategy != address(0), "FIXED_TERM_STRATEGY required");
        require(cfg.maturityTs > block.timestamp, "FM_MATURITY_TS must be future");
        require(cfg.fundingDeadlineTs > block.timestamp, "FM_FUNDING_DEADLINE_TS must be future");
        require(cfg.fundingDeadlineTs < cfg.maturityTs, "deadline must be before maturity");
        require(cfg.minFundingAssets > 0, "FM_MIN_FUNDING_ASSETS must be > 0");
        require(cfg.targetFundingAssets >= cfg.minFundingAssets, "target must be >= min");
        require(cfg.forcePenaltyBps <= 5000, "FM_FORCE_PENALTY_BPS must be <= 5000");
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    function _setModulesBatch(CoreVault vault_, bytes4[] memory selectors, address module, uint8 role) internal {
        uint256 len = selectors.length;
        address[] memory modules = new address[](len);
        uint8[] memory roles = new uint8[](len);
        for (uint256 i; i < len; i++) { modules[i] = module; roles[i] = role; }
        vault_.setModulesBatch(selectors, modules, roles);
    }

    function _printConfig(FMConfig memory cfg) internal pure {
        console.log("================================================================");
        console.log("   FIXED MATURITY VAULT INTEGRATED DEPLOYMENT");
        console.log("================================================================");
        console.log("Deployer:", cfg.deployer);
        console.log("Vault:", cfg.vaultName, cfg.vaultSymbol);
        console.log("Strategy:", cfg.fixedTermStrategy);
        console.log("MaturityTs:", cfg.maturityTs);
        console.log("FundingDeadlineTs:", cfg.fundingDeadlineTs);
        console.log("================================================================");
    }

    function _printSummary(FMIntegratedResult memory r) internal pure {
        console.log("================================================================");
        console.log("   FM INTEGRATED DEPLOYMENT COMPLETE -- ADDRESS BOOK");
        console.log("================================================================");
        console.log("CoreVault:               ", address(r.vault));
        console.log("FixedMaturityModule:     ", address(r.fixedMaturityModule));
        console.log("BufferManager:           ", address(r.bufferManager));
        console.log("StrategyRouter:          ", address(r.strategyRouter));
        console.log("SelectorRegistry:        ", address(r.selectorRegistry));
        console.log("Permit2DepositHelper:    ", address(r.permit2Helper));
        console.log("================================================================");
        console.log("NEXT: Deploy upkeep: forge script DeployFixedMaturityVaultUpkeep.s.sol");
        console.log("================================================================");
    }
}
