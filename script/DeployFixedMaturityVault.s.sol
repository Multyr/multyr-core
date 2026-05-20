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

/// @title DeployFixedMaturityVault -- FM pure core deploy (10-phase standalone)
/// @notice Deploys a CoreVault pre-configured for FixedMaturity mode.
///         Pure core: no periphery (Permit2, referral) -- use DeployFixedMaturityVaultIntegrated for UX.
///         No upkeep -- deploy separately via DeployFixedMaturityVaultUpkeep.s.sol.
/// @dev Phase order is critical and must not be reordered (see phases 1-9 below).
///      FM vault does not include warm adapters in V1 -- BufferManager is hot-only.
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
/// @custom:replaces script/DeployFixedMaturityVault.s.sol (legacy monorepo path -- periphery extracted)
contract DeployFixedMaturityVault is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;

    // Arbitrum One canonical addresses
    address constant USDC               = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant CHAINLINK_USDC_ARB = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

    // =========================================================================
    // RESULT STRUCT
    // =========================================================================

    struct FMDeploymentResult {
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
        // FM lifecycle
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

    function run() external returns (FMDeploymentResult memory result) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployFixedMaturityVault is Arbitrum One only (chainId 42161)"
        );

        FMConfig memory cfg = _loadConfig();
        _printConfig(cfg);

        vm.startBroadcast(cfg.deployerPk);

        console.log("=== PHASE 1: INFRASTRUCTURE ===");
        result = _deployPhase1(cfg, result);

        console.log("=== PHASE 2: CORE + MODULES ===");
        result = _deployPhase2(cfg, result);

        console.log("=== PHASE 3: ECOSYSTEM ===");
        result = _deployPhase3(cfg, result);

        console.log("=== PHASE 4: MODULE ROUTING (no guardrail yet) ===");
        _wireModules(result);

        console.log("=== PHASE 5: FM CONFIGURATION ===");
        _configureFM(cfg, result);

        console.log("=== PHASE 6: ECOSYSTEM WIRING ===");
        _wireEcosystem(cfg, result);

        console.log("=== PHASE 7: SELECTOR REGISTRY (guardrail active) ===");
        _activateSelectorRegistry(result);

        console.log("=== PHASE 8: SEED DEAD DEPOSIT (MANDATORY) ===");
        _seedDeadDeposit(result);

        console.log("=== PHASE 9: FINAL ASSERTIONS ===");
        _assertFinalState(cfg, result);

        vm.stopBroadcast();

        _printSummary(result);
        return result;
    }

    // =========================================================================
    // PHASE 1: INFRASTRUCTURE
    // =========================================================================

    function _deployPhase1(FMConfig memory cfg, FMDeploymentResult memory result)
        internal returns (FMDeploymentResult memory)
    {
        // GlobalConfig -- deployer as temp governor (transferred to timelock after oracle config)
        result.globalConfig = new GlobalConfig(
            cfg.deployer,
            25,     // depositFeeBps = 0.25%
            25,     // withdrawFeeBps = 0.25%
            1000,   // perfFeeBps = 10%
            86400,  // lockPeriod = 1 day
            25,     // maxActions = 25
            500,    // maxNavDeltaBps = 5%
            3600,   // minCooldown = 1h
            86400   // maxStaleness = 24h (Chainlink heartbeat)
        );
        console.log("[1.1] GlobalConfig:", address(result.globalConfig));

        // FeeCollector -- governor IMMUTABLE = timelock
        // SystemSealer.prepareSeal() verifies fc.governor() == config.rootTimelock
        result.feeCollector = new FeeCollector(
            cfg.timelock, // IMMUTABLE
            cfg.treasury,
            cfg.ops,
            cfg.safetyReserve,
            7000, // treasuryBps = 70%
            100,  // safetyReserveBps = 1%
            3000  // opsMaxBps = 30%
        );
        console.log("[1.2] FeeCollector:", address(result.feeCollector));

        result.priceOracle = new PriceOracleMiddleware(cfg.deployer);
        console.log("[1.3] PriceOracleMiddleware:", address(result.priceOracle));

        result.healthRegistry = new StrategyHealthRegistry(cfg.deployer, cfg.guardian);
        console.log("[1.4] StrategyHealthRegistry:", address(result.healthRegistry));

        // SelectorRegistry deployed early but NOT set on vault yet (activated in Phase 7)
        result.selectorRegistry = new SelectorRegistry();
        console.log("[1.5] SelectorRegistry:", address(result.selectorRegistry));
        console.log("      Total registered selectors:", result.selectorRegistry.totalRegisteredSelectors());

        return result;
    }

    // =========================================================================
    // PHASE 2: CORE + MODULES
    // =========================================================================

    function _deployPhase2(FMConfig memory cfg, FMDeploymentResult memory result)
        internal returns (FMDeploymentResult memory)
    {
        result.vault = new CoreVault(
            IERC20Metadata(USDC),
            cfg.vaultName,
            cfg.vaultSymbol,
            cfg.deployer,
            address(result.feeCollector),
            address(result.globalConfig)
        );
        console.log("[2.1] CoreVault:", address(result.vault));
        require(result.vault.paused(), "GATE: vault must start PAUSED");

        result.queueModule         = new QueueModule();
        result.adminModule         = new AdminModule();
        result.erc4626Module       = new ERC4626Module();
        result.liquidityOpsModule  = new LiquidityOpsModule();
        result.fixedMaturityModule = new FixedMaturityModule();

        console.log("[2.2] QueueModule:", address(result.queueModule));
        console.log("[2.3] AdminModule:", address(result.adminModule));
        console.log("[2.4] ERC4626Module:", address(result.erc4626Module));
        console.log("[2.5] LiquidityOpsModule:", address(result.liquidityOpsModule));
        console.log("[2.6] FixedMaturityModule:", address(result.fixedMaturityModule));

        return result;
    }

    // =========================================================================
    // PHASE 3: ECOSYSTEM
    // =========================================================================

    function _deployPhase3(FMConfig memory cfg, FMDeploymentResult memory result)
        internal returns (FMDeploymentResult memory)
    {
        // FM vaults use conservative hot-only buffer in V1 (no warm adapters)
        IBufferManager.BufferConfig memory bufCfg = IBufferManager.BufferConfig({
            targetHotBps:        400, // 4% hot
            minHotBps:           200, // 2% trigger
            targetWarmBps:       600, // 6% warm (optional in FM V1)
            maxWarmBps:          800, // 8% cap = 1000 - minHot
            opsReserveTargetBps: 400, // MUST equal targetHotBps
            maxWarmSlippageBps:   50, // 0.5%
            asset:              USDC,
            warmAdapter:        address(0), // deprecated field
            twapWindowSec:      0,
            paused:             false
        });
        result.bufferManager = new BufferManager(cfg.deployer, address(result.vault), bufCfg);
        console.log("[3.1] BufferManager:", address(result.bufferManager));

        // BufferConfig invariant assertions (audit-grade)
        IBufferManager.BufferConfig memory v = result.bufferManager.getConfig();
        require(v.targetHotBps + v.targetWarmBps == 1000, "DEPLOY_BUG: hot+warm != 1000");
        require(v.maxWarmBps == 1000 - v.minHotBps,       "DEPLOY_BUG: maxWarm != 1000-minHot");
        require(v.opsReserveTargetBps == v.targetHotBps,  "DEPLOY_BUG: opsReserve != targetHot");
        console.log("  [OK] BufferManager config invariants verified");

        result.strategyRouter = new StrategyRouter(
            cfg.deployer,
            address(result.vault),
            address(result.globalConfig)
        );
        console.log("[3.2] StrategyRouter:", address(result.strategyRouter));

        return result;
    }

    // =========================================================================
    // PHASE 4: MODULE ROUTING (guardrail NOT yet active)
    // =========================================================================

    function _wireModules(FMDeploymentResult memory result) internal {
        _setModulesBatch(result.vault, SelectorLib.getQueueModuleSelectors(),
            address(result.queueModule), SelectorLib.ROLE_PUBLIC);
        _setModulesBatch(result.vault, SelectorLib.getQueueModuleViewSelectors(),
            address(result.queueModule), SelectorLib.ROLE_PUBLIC);
        _setModulesBatch(result.vault, SelectorLib.getAdminModuleOwnerSelectors(),
            address(result.adminModule), SelectorLib.ROLE_OWNER);
        _setModulesBatch(result.vault, SelectorLib.getAdminModuleViewSelectors(),
            address(result.adminModule), SelectorLib.ROLE_PUBLIC);
        _setModulesBatch(result.vault, SelectorLib.getERC4626ModuleSelectors(),
            address(result.erc4626Module), SelectorLib.ROLE_PUBLIC);
        _setModulesBatch(result.vault, SelectorLib.getLiquidityOpsModuleSelectors(),
            address(result.liquidityOpsModule), SelectorLib.ROLE_PUBLIC);
        _setModulesBatch(result.vault, SelectorLib.getFixedMaturityModuleSelectors(),
            address(result.fixedMaturityModule), SelectorLib.ROLE_PUBLIC);

        result.vault.authorizeModule(address(result.erc4626Module), true);
        result.vault.authorizeModule(address(result.fixedMaturityModule), true);

        console.log("  Total selectors wired:", SelectorLib.TOTAL_SELECTORS);

        require(
            result.vault.moduleOf(bytes4(keccak256("withdraw(uint256,address,address)"))) == address(result.erc4626Module),
            "GATE: withdraw routing"
        );
        require(
            result.vault.moduleOf(IFixedMaturityModule.setVaultModeFixedMaturity.selector) == address(result.fixedMaturityModule),
            "GATE: setVaultModeFixedMaturity routing"
        );
        require(
            result.vault.moduleOf(IFixedMaturityModule.currentVaultModeAndState.selector) == address(result.fixedMaturityModule),
            "GATE: currentVaultModeAndState routing"
        );
        console.log("  [OK] Critical routing verified");
    }

    // =========================================================================
    // PHASE 5: FM CONFIGURATION
    // =========================================================================

    function _configureFM(FMConfig memory cfg, FMDeploymentResult memory result) internal {
        IFixedMaturityModule fm = IFixedMaturityModule(address(result.vault));

        // Switch to FixedMaturity mode (one-time, irreversible)
        fm.setVaultModeFixedMaturity();
        console.log("  [OK] VaultMode: FixedMaturity");

        // Configure FM lifecycle (one-shot, no reconfiguration possible)
        fm.configureFixedMaturity(
            cfg.maturityTs,
            cfg.minFundingAssets,
            cfg.targetFundingAssets,
            cfg.fundingDeadlineTs,
            cfg.autoClose,
            cfg.instantExit,
            cfg.forcePenaltyBps,
            cfg.fixedTermStrategy
        );
        console.log("  [OK] FM configured:");
        console.log("       fixedTermStrategy:   ", cfg.fixedTermStrategy);
        console.log("       maturityTs:          ", cfg.maturityTs);
        console.log("       fundingDeadlineTs:   ", cfg.fundingDeadlineTs);
        console.log("       minFundingAssets:    ", cfg.minFundingAssets);
        console.log("       targetFundingAssets: ", cfg.targetFundingAssets);
        console.log("       autoClose:           ", cfg.autoClose);
        console.log("       instantExit:         ", cfg.instantExit);
        console.log("       forcePenaltyBps:     ", cfg.forcePenaltyBps);

        (VaultMode mode_, VaultState state_) = fm.currentVaultModeAndState();
        require(uint8(mode_) == 1, "ASSERT: not FixedMaturity mode");
        require(uint8(state_) == 0, "ASSERT: not Funding state");
        console.log("  [OK] State: FixedMaturity/Funding");
    }

    // =========================================================================
    // PHASE 6: ECOSYSTEM WIRING
    // =========================================================================

    function _wireEcosystem(FMConfig memory cfg, FMDeploymentResult memory result) internal {
        IAdminModule(address(result.vault)).setEcosystem(
            IAdminModule.EcosystemConfig({
                bufferManager:  address(result.bufferManager),
                strategyRouter: address(result.strategyRouter),
                healthRegistry: address(result.healthRegistry),
                incentives:     address(0), // no incentives in FM V1
                guardian:       cfg.guardian,
                vetoer:         address(0)  // no vetoer in FM V1
            })
        );
        console.log("  [OK] Ecosystem set (BM, Router, HR, Guardian)");

        result.strategyRouter.setHealthRegistry(address(result.healthRegistry));
        console.log("  [OK] StrategyRouter health registry set");

        result.healthRegistry.setAuthorizedCaller(address(result.vault), true);
        result.healthRegistry.setAuthorizedCaller(address(result.strategyRouter), true);
        console.log("  [OK] HealthRegistry callers authorized");

        // CRITICAL: deposits revert with NavStale without this
        result.bufferManager.refreshWarmNav();
        console.log("  [OK] BufferManager warm NAV refreshed");

        if (cfg.chainlinkFeed != address(0)) {
            result.priceOracle.setOracleFeed(USDC, cfg.chainlinkFeed, 86400);
            result.globalConfig.setDefaultOracleConfig(address(result.priceOracle), 86400);
            result.globalConfig.setAssetOracleConfig(USDC, address(result.priceOracle), 86400);
            (address o, uint256 s) = result.globalConfig.oracleConfigFor(USDC, address(result.vault));
            require(o == address(result.priceOracle) && s == 86400, "DEPLOY_BUG: oracle mismatch");
            console.log("  [OK] Oracle configured:", cfg.chainlinkFeed);
        }

        // Transfer GlobalConfig governor to timelock (after oracle config)
        result.globalConfig.setGovernor(cfg.governor);
        require(result.globalConfig.governor() == cfg.governor, "DEPLOY_BUG: globalConfig governor");
        console.log("  [OK] GlobalConfig governor transferred to:", cfg.governor);

        if (!IAdminModule(address(result.vault)).isFeesInitialized()) {
            IAdminModule(address(result.vault)).setInitialFees(
                25, // depositFeeBps  = 0.25%
                25, // withdrawFeeBps = 0.25%
                100, // immediateExitPenaltyBps = 1%
                150, // forceExitPenaltyBps = 1.5%
                address(result.feeCollector)
            );
            console.log("  [OK] Initial fees set (dep 0.25%, wit 0.25%, imm 1%, force 1.5%)");
        }

        IAdminModule(address(result.vault)).submitPerfParams(1000, 0);
        IAdminModule(address(result.vault)).acceptPerfParams();
        console.log("  [OK] Perf params: 10% rate");
    }

    // =========================================================================
    // PHASE 7: SELECTOR REGISTRY ACTIVATION (guardrail last)
    // =========================================================================

    function _activateSelectorRegistry(FMDeploymentResult memory result) internal {
        result.vault.setSelectorRegistry(address(result.selectorRegistry));
        console.log("  [OK] SelectorRegistry active (guardrail NOW live)");
        console.log("       Total registered:", result.selectorRegistry.totalRegisteredSelectors());
    }

    // =========================================================================
    // PHASE 8: SEED DEAD DEPOSIT (MANDATORY -- inflation attack hardening)
    // =========================================================================

    function _seedDeadDeposit(FMDeploymentResult memory result) internal {
        IAdminModule(address(result.vault)).seedDeadDeposit(1e6); // 1 USDC
        require(IAdminModule(address(result.vault)).isDeadDepositDone(), "SEED: dead deposit failed");
        console.log("  [OK] Dead deposit seeded (1 USDC)");
    }

    // =========================================================================
    // PHASE 9: FINAL ASSERTIONS
    // =========================================================================

    function _assertFinalState(FMConfig memory cfg, FMDeploymentResult memory result) internal view {
        IFixedMaturityModule fm    = IFixedMaturityModule(address(result.vault));
        IAdminModule         admin = IAdminModule(address(result.vault));

        (VaultMode mode_, VaultState state_) = fm.currentVaultModeAndState();
        require(uint8(mode_) == 1,  "ASSERT: not FixedMaturity mode");
        require(uint8(state_) == 0, "ASSERT: not Funding state");
        require(fm.fundingDeadlineTs() == cfg.fundingDeadlineTs, "ASSERT: fundingDeadlineTs");
        require(fm.maturityTs() == cfg.maturityTs,               "ASSERT: maturityTs");
        require(fm.minFundingAssets() == cfg.minFundingAssets,   "ASSERT: minFundingAssets");
        require(fm.fixedTermStrategy() == cfg.fixedTermStrategy, "ASSERT: fixedTermStrategy");
        require(fm.isDepositOpen(),                              "ASSERT: deposits must be open");
        console.log("  [OK] FM state: FixedMaturity/Funding -- deposits open");

        require(admin.isFeesInitialized(), "ASSERT: fees not initialized");
        require(admin.isDeadDepositDone(), "ASSERT: dead deposit not done");
        require(result.vault.paused(),     "ASSERT: vault must still be paused");
        console.log("  [OK] Core: fees init, dead deposit done, vault paused");

        require(
            address(result.vault.selectorRegistry()) == address(result.selectorRegistry),
            "ASSERT: selectorRegistry not set"
        );
        console.log("  [OK] SelectorRegistry active");
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

        // FM required
        cfg.fixedTermStrategy   = vm.envAddress("FIXED_TERM_STRATEGY");
        cfg.maturityTs          = uint64(vm.envUint("FM_MATURITY_TS"));
        cfg.fundingDeadlineTs   = uint64(vm.envUint("FM_FUNDING_DEADLINE_TS"));
        cfg.minFundingAssets    = vm.envUint("FM_MIN_FUNDING_ASSETS");
        cfg.targetFundingAssets = vm.envUint("FM_TARGET_FUNDING_ASSETS");

        // FM optional with defaults
        cfg.autoClose       = vm.envOr("FM_AUTO_CLOSE",         true);
        cfg.instantExit     = vm.envOr("FM_INSTANT_EXIT",       true);
        cfg.forcePenaltyBps = vm.envOr("FM_FORCE_PENALTY_BPS", uint256(500));

        // Validation
        require(cfg.fixedTermStrategy != address(0),             "FIXED_TERM_STRATEGY required");
        require(cfg.maturityTs > block.timestamp,                "FM_MATURITY_TS must be future");
        require(cfg.fundingDeadlineTs > block.timestamp,         "FM_FUNDING_DEADLINE_TS must be future");
        require(cfg.fundingDeadlineTs < cfg.maturityTs,          "deadline must be before maturity");
        require(cfg.minFundingAssets > 0,                        "FM_MIN_FUNDING_ASSETS must be > 0");
        require(cfg.targetFundingAssets >= cfg.minFundingAssets, "target must be >= min");
        require(cfg.forcePenaltyBps <= 5000,                     "FM_FORCE_PENALTY_BPS must be <= 5000");
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    function _setModulesBatch(
        CoreVault vault_,
        bytes4[] memory selectors,
        address module,
        uint8 role
    ) internal {
        uint256 len = selectors.length;
        address[] memory modules = new address[](len);
        uint8[]   memory roles   = new uint8[](len);
        for (uint256 i; i < len; i++) {
            modules[i] = module;
            roles[i]   = role;
        }
        vault_.setModulesBatch(selectors, modules, roles);
    }

    function _printConfig(FMConfig memory cfg) internal pure {
        console.log("================================================================");
        console.log("   FIXED MATURITY VAULT DEPLOYMENT -- FM PURE CORE");
        console.log("================================================================");
        console.log("Deployer:              ", cfg.deployer);
        console.log("Governor/Timelock:     ", cfg.governor);
        console.log("Guardian:              ", cfg.guardian);
        console.log("Treasury:              ", cfg.treasury);
        console.log("Vault name:            ", cfg.vaultName);
        console.log("Vault symbol:          ", cfg.vaultSymbol);
        console.log("fixedTermStrategy:     ", cfg.fixedTermStrategy);
        console.log("maturityTs:            ", cfg.maturityTs);
        console.log("fundingDeadlineTs:     ", cfg.fundingDeadlineTs);
        console.log("minFundingAssets:      ", cfg.minFundingAssets);
        console.log("targetFundingAssets:   ", cfg.targetFundingAssets);
        console.log("autoClose:             ", cfg.autoClose);
        console.log("instantExit:           ", cfg.instantExit);
        console.log("forcePenaltyBps:       ", cfg.forcePenaltyBps);
        console.log("================================================================");
    }

    function _printSummary(FMDeploymentResult memory r) internal pure {
        console.log("================================================================");
        console.log("   DEPLOYMENT COMPLETE -- ADDRESS BOOK");
        console.log("================================================================");
        console.log("CoreVault:               ", address(r.vault));
        console.log("FixedMaturityModule:     ", address(r.fixedMaturityModule));
        console.log("QueueModule:             ", address(r.queueModule));
        console.log("AdminModule:             ", address(r.adminModule));
        console.log("ERC4626Module:           ", address(r.erc4626Module));
        console.log("LiquidityOpsModule:      ", address(r.liquidityOpsModule));
        console.log("BufferManager:           ", address(r.bufferManager));
        console.log("StrategyRouter:          ", address(r.strategyRouter));
        console.log("FeeCollector:            ", address(r.feeCollector));
        console.log("GlobalConfig:            ", address(r.globalConfig));
        console.log("SelectorRegistry:        ", address(r.selectorRegistry));
        console.log("================================================================");
        console.log("NEXT STEPS:");
        console.log("  1. Deploy upkeep: forge script DeployFixedMaturityVaultUpkeep.s.sol");
        console.log("     FM_VAULT_ADDRESS=<vault above>");
        console.log("  2. Register FixedMaturityVaultUpkeep on Chainlink Automation");
        console.log("  3. Unpause vault (owner call after safety check)");
        console.log("  4. Transfer vault ownership to timelock");
        console.log("================================================================");
    }
}
