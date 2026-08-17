// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────────────────────────────────────────────────────────────────
// SPRINT SECURITY TEST — SystemSealer non-6dp decimals guard
//
// BUG (kpi4/corevault-decimals-guard review, 2026-08-11):
//   GlobalConfig's defaults (defaultVaultDepositCap = 10M * 1e6,
//   defaultMinDeployAmount = 10 * 1e6, ...) are 6dp/USDC-shaped. The per-vault
//   override setters (setVaultDepositLimits, setVaultWithdrawalOverride,
//   setVaultGovCaps) exist to correct this for non-6dp assets (e.g. 18dp WETH),
//   but nothing enforced their use — an 18dp vault sealed without calling them
//   ends up with a deposit cap of ~0.00001 WETH and a near-zero minDeployAmount:
//   a bricked configuration that SystemSealer previously let through.
//
// FIX:
//   SystemSealer.verifyAndSeal / canSeal now require, for any vault whose asset
//   is not 6dp, that VAULT_CAP, WITHDRAWAL, and GOV_CAPS overrides are all set
//   in GlobalConfig before the vault can be sealed. 6dp vaults are exempt (they
//   already match the GlobalConfig defaults).
// ──────────────────────────────────────────────────────────────────────────────

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreVault } from "../../src/core/CoreVault.sol";
import { EpochedQueueModule } from "../../src/core/modules/EpochedQueueModule.sol";
import { AdminModule } from "../../src/core/modules/AdminModule.sol";
import { ERC4626Module } from "../../src/core/modules/ERC4626Module.sol";
import { LiquidityOpsModule } from "../../src/core/modules/LiquidityOpsModule.sol";
import { FeeCollector } from "../../src/core/modules/FeeCollector.sol";
import { BufferManager } from "../../src/core/modules/BufferManager.sol";
import { StrategyRouter } from "../../src/core/modules/StrategyRouter.sol";
import { StrategyHealthRegistry } from "../../src/core/modules/StrategyHealthRegistry.sol";
import { GlobalConfig } from "../../src/core/config/GlobalConfig.sol";
import { SelectorRegistry } from "../../src/core/libraries/SelectorRegistry.sol";
import { SelectorLib } from "../../src/core/libraries/SelectorLib.sol";
import { SystemSealer } from "../../src/core/SystemSealer.sol";
import { IAdminModule } from "../../src/interfaces/IAdminModule.sol";
import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";
import { IncentivesTimelock } from "../../src/governance/IncentivesTimelock.sol";
import { ERC20Mock } from "../../src/mocks/ERC20Mock.sol";

contract SystemSealer_DecimalsGuard_Test is Test {
    uint256 constant TIMELOCK_DELAY = 2 days;

    address internal deployer;
    address internal guardian;
    address internal vetoer;
    address internal treasury;

    ERC20Mock internal weth; // 18dp
    IncentivesTimelock internal rootTimelock;
    CoreVault internal vault;
    FeeCollector internal feeCollector;
    GlobalConfig internal globalConfig;
    BufferManager internal bufferManager;
    StrategyRouter internal strategyRouter;
    StrategyHealthRegistry internal healthRegistry;
    SystemSealer internal systemSealer;

    SystemSealer.SealConfig internal sealConfig;

    function setUp() public {
        deployer  = makeAddr("deployer");
        guardian  = makeAddr("guardian");
        vetoer    = makeAddr("vetoer");
        treasury  = makeAddr("treasury");

        vm.startPrank(deployer);

        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);

        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = deployer;
        executors[0] = deployer;
        rootTimelock = new IncentivesTimelock(TIMELOCK_DELAY, proposers, executors, deployer);

        feeCollector = new FeeCollector(address(rootTimelock), treasury, treasury, treasury, 7000, 200, 3000);
        globalConfig = new GlobalConfig(address(rootTimelock), 50, 100, 2000, 0, 10, 500, 3600, 3600);

        systemSealer = new SystemSealer();
        SelectorRegistry selectorRegistry = new SelectorRegistry();

        // The vault must resolve its params from the SAME contract the seal config names:
        // SystemSealer requires config.globalConfig == vault.params(), and the decimals
        // override check is only meaningful against the provider the vault actually reads.
        vault = new CoreVault(
            IERC20Metadata(address(weth)), "Vault", "V", deployer, address(feeCollector), address(globalConfig)
        );

        _wireModules(address(selectorRegistry));

        IBufferManager.BufferConfig memory bufCfg = IBufferManager.BufferConfig({
            targetHotBps: 1000, minHotBps: 500, targetWarmBps: 1000, maxWarmBps: 2000,
            opsReserveTargetBps: 100, maxWarmSlippageBps: 50, asset: address(weth),
            warmAdapter: address(0), twapWindowSec: 0, paused: true
        });
        bufferManager  = new BufferManager(deployer, address(vault), bufCfg);
        strategyRouter = new StrategyRouter(deployer, address(vault), address(globalConfig));
        healthRegistry = new StrategyHealthRegistry(deployer, guardian);

        IAdminModule(address(vault)).setEcosystem(IAdminModule.EcosystemConfig({
            bufferManager:  address(bufferManager),
            strategyRouter: address(strategyRouter),
            healthRegistry: address(healthRegistry),
            incentives:     address(0),
            guardian:       guardian,
            vetoer:         vetoer
        }));

        uint256 deadAmt = 10_000_000;
        weth._mint(deployer, deadAmt);
        weth.approve(address(vault), deadAmt);
        IAdminModule(address(vault)).seedDeadDeposit(deadAmt);
        IAdminModule(address(vault)).enableComponentsTimelock();
        vault.freezeRouting();
        vault.setAuthorizedSealer(address(systemSealer));

        bufferManager.transferOwnership(address(rootTimelock));
        strategyRouter.transferOwnership(address(rootTimelock));
        healthRegistry.transferOwnership(address(rootTimelock));
        vault.beginOwnerTransfer(address(rootTimelock));

        vm.stopPrank();

        vm.prank(address(rootTimelock));
        vault.acceptOwnerTransfer();

        sealConfig = SystemSealer.SealConfig({
            chainId:              block.chainid,
            vault:                address(vault),
            strategyRouter:       address(strategyRouter),
            bufferManager:        address(bufferManager),
            healthRegistry:       address(healthRegistry),
            globalConfig:         address(globalConfig),
            feeCollector:         address(feeCollector),
            rootTimelock:         address(rootTimelock),
            guardian:             guardian,
            vetoer:               vetoer,
            strategy:             address(0),
            incentives:           address(0),
            incentivesEngine:     address(0),
            rewardsPayoutManager: address(0),
            recoveryGate:         address(0),
            recoveryManifestVersion: 0,
            rewardsTreasury:      address(0),
            deployer:             deployer
        });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 18dp vault, no overrides set -> must not seal
    // ══════════════════════════════════════════════════════════════════════════

    function test_canSeal_returnsFalse_for18dpVault_withNoOverrides() public {
        (bool ok, string memory reason) = systemSealer.canSeal(sealConfig);
        assertFalse(ok, "canSeal must reject an 18dp vault with no decimals overrides");
        assertEq(reason, "Non-6dp vault missing VAULT_CAP override");
    }

    function test_verifyAndSeal_reverts_for18dpVault_withNoOverrides() public {
        _scheduleAndExpectRevert(sealConfig, "no-overrides-salt");
        assertFalse(vault.isSystemSealed(), "vault must not seal while 18dp overrides are missing");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 18dp vault, only some overrides set -> still must not seal
    // ══════════════════════════════════════════════════════════════════════════

    function test_canSeal_returnsFalse_whenOnlyVaultCapSet() public {
        vm.prank(address(rootTimelock));
        globalConfig.setVaultDepositLimits(address(vault), 1_000e18, 100e18, 0.01e18);

        (bool ok, string memory reason) = systemSealer.canSeal(sealConfig);
        assertFalse(ok, "VAULT_CAP alone is not sufficient");
        assertEq(reason, "Non-6dp vault missing WITHDRAWAL override");
    }

    function test_canSeal_returnsFalse_whenVaultCapAndWithdrawalSet_butNotGovCaps() public {
        vm.startPrank(address(rootTimelock));
        globalConfig.setVaultDepositLimits(address(vault), 1_000e18, 100e18, 0.01e18);
        globalConfig.setVaultWithdrawalOverride(
            address(vault),
            GlobalConfig.WithdrawalConfig({
                capPerEpochBps: 1000,
                maxWithdrawalPerBlock: 0,
                maxWithdrawalPerTx: 0,
                minClaimAmount: 0.01e18,
                lockPeriod: 0
            })
        );
        vm.stopPrank();

        (bool ok, string memory reason) = systemSealer.canSeal(sealConfig);
        assertFalse(ok, "VAULT_CAP + WITHDRAWAL without GOV_CAPS is not sufficient");
        assertEq(reason, "Non-6dp vault missing GOV_CAPS override");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 18dp vault, all three overrides set -> seals successfully
    // ══════════════════════════════════════════════════════════════════════════

    function test_verifyAndSeal_succeeds_for18dpVault_withAllOverridesSet() public {
        _setAllDecimalsOverrides();

        (bool ok, string memory reason) = systemSealer.canSeal(sealConfig);
        assertTrue(ok, string.concat("canSeal should pass once all overrides are set: ", reason));

        address[] memory targets  = new address[](1);
        uint256[] memory values   = new uint256[](1);
        bytes[]   memory payloads = new bytes[](1);
        targets[0]  = address(systemSealer);
        payloads[0] = abi.encodeCall(SystemSealer.verifyAndSeal, (sealConfig));

        vm.prank(deployer);
        rootTimelock.scheduleBatch(targets, values, payloads, bytes32(0), keccak256("18dp-good-salt"), TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.prank(deployer);
        rootTimelock.executeBatch(targets, values, payloads, bytes32(0), keccak256("18dp-good-salt"));

        assertTrue(vault.isSystemSealed(), "18dp vault must seal once all decimals overrides are set");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Decoy GlobalConfig: overrides set on a provider the vault does not read
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev config.globalConfig is caller-supplied. A second, correctly governed
    ///      GlobalConfig carrying all three overrides satisfies the decimals check on
    ///      its own terms while the vault keeps resolving its params from the real one,
    ///      still on 6dp-shaped defaults. Sealing against it must be rejected.
    function test_verifyAndSeal_reverts_whenGlobalConfigIsNotTheVaultsProvider() public {
        GlobalConfig decoy = new GlobalConfig(address(rootTimelock), 50, 100, 2000, 0, 10, 500, 3600, 3600);

        vm.startPrank(address(rootTimelock));
        decoy.setVaultDepositLimits(address(vault), 1_000e18, 100e18, 0.01e18);
        decoy.setVaultWithdrawalOverride(
            address(vault),
            GlobalConfig.WithdrawalConfig({
                capPerEpochBps: 1000,
                maxWithdrawalPerBlock: 0,
                maxWithdrawalPerTx: 0,
                minClaimAmount: 0.01e18,
                lockPeriod: 0
            })
        );
        decoy.setVaultGovCaps(address(vault), 2 days, 5e17, 500, 200, 200, 7 days, 0.001e18, 1_000_000, 3000);
        vm.stopPrank();

        // The decoy passes every check the vault's real provider would fail.
        assertTrue(decoy.hasOverride(address(vault), GlobalConfig.ParamType.VAULT_CAP));
        assertTrue(decoy.hasOverride(address(vault), GlobalConfig.ParamType.WITHDRAWAL));
        assertTrue(decoy.hasOverride(address(vault), GlobalConfig.ParamType.GOV_CAPS));
        assertFalse(globalConfig.hasOverride(address(vault), GlobalConfig.ParamType.VAULT_CAP));
        assertEq(address(vault.params()), address(globalConfig), "vault still reads the real provider");

        SystemSealer.SealConfig memory decoyConfig = sealConfig;
        decoyConfig.globalConfig = address(decoy);

        (bool ok, string memory reason) = systemSealer.canSeal(decoyConfig);
        assertFalse(ok, "canSeal must reject a globalConfig the vault does not resolve");
        assertEq(reason, "GlobalConfig not bound to vault");

        _scheduleAndExpectRevert(decoyConfig, "decoy-global-config-salt");
        assertFalse(vault.isSystemSealed(), "vault must not seal against a decoy globalConfig");
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _setAllDecimalsOverrides() internal {
        vm.startPrank(address(rootTimelock));
        globalConfig.setVaultDepositLimits(address(vault), 1_000e18, 100e18, 0.01e18);
        globalConfig.setVaultWithdrawalOverride(
            address(vault),
            GlobalConfig.WithdrawalConfig({
                capPerEpochBps: 1000,
                maxWithdrawalPerBlock: 0,
                maxWithdrawalPerTx: 0,
                minClaimAmount: 0.01e18,
                lockPeriod: 0
            })
        );
        globalConfig.setVaultGovCaps(
            address(vault),
            2 days,
            5e17,
            500,
            200,
            200,
            7 days,
            0.001e18, // minDeployAmount, rescaled to 18dp
            1_000_000,
            3000
        );
        vm.stopPrank();
    }

    function _scheduleAndExpectRevert(SystemSealer.SealConfig memory config, bytes32 saltSeed) internal {
        address[] memory targets  = new address[](1);
        uint256[] memory values   = new uint256[](1);
        bytes[]   memory payloads = new bytes[](1);
        targets[0]  = address(systemSealer);
        payloads[0] = abi.encodeCall(SystemSealer.verifyAndSeal, (config));

        bytes32 salt = keccak256(abi.encode(saltSeed));

        vm.prank(deployer);
        rootTimelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.prank(deployer);
        vm.expectRevert();
        rootTimelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    function _wireModules(address selectorRegistry) internal {
        vault.setSelectorRegistry(selectorRegistry);

        EpochedQueueModule qm = new EpochedQueueModule();
        AdminModule am        = new AdminModule();
        ERC4626Module e4626   = new ERC4626Module();
        LiquidityOpsModule lo = new LiquidityOpsModule();

        bytes4[] memory s;
        s = SelectorLib.getQueueModuleSelectors();
        for (uint256 i; i < s.length; ++i) vault.setModule(s[i], address(qm), SelectorLib.ROLE_PUBLIC);
        s = SelectorLib.getQueueModuleViewSelectors();
        for (uint256 i; i < s.length; ++i) vault.setModule(s[i], address(qm), SelectorLib.ROLE_PUBLIC);
        s = SelectorLib.getAdminModuleOwnerSelectors();
        for (uint256 i; i < s.length; ++i) vault.setModule(s[i], address(am), SelectorLib.ROLE_OWNER);
        s = SelectorLib.getAdminModuleViewSelectors();
        for (uint256 i; i < s.length; ++i) vault.setModule(s[i], address(am), SelectorLib.ROLE_PUBLIC);
        s = SelectorLib.getERC4626ModuleSelectors();
        for (uint256 i; i < s.length; ++i) vault.setModule(s[i], address(e4626), SelectorLib.ROLE_PUBLIC);
        s = SelectorLib.getLiquidityOpsModuleSelectors();
        for (uint256 i; i < s.length; ++i) {
            uint8 role = s[i] == LiquidityOpsModule.deployToStrategiesWithPlan.selector
                ? SelectorLib.ROLE_OWNER_OR_GUARDIAN
                : SelectorLib.ROLE_PUBLIC;
            vault.setModule(s[i], address(lo), role);
        }
    }
}
