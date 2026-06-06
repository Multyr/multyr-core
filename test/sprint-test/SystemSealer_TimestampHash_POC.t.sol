// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────────────────────────────────────────────────────────────────
// SPRINT SECURITY TEST — SystemSealer atomic seal fix
//
// ORIGINAL BUG (now fixed):
//   The prior two-call batch [prepareSeal(config), sealFinalState(configHash)]
//   always reverted because prepareSeal baked block.timestamp into configHash:
//
//     configHash = keccak256(abi.encode(..., block.timestamp ← non-deterministic));
//
//   TimelockController.executeBatch() cannot pass return values between calls.
//   The operator had to encode sealFinalState(configHash) at scheduleBatch() time,
//   but configHash was only known at executeBatch() time (block.timestamp differs
//   by the full timelock delay). The two-call atomic batch ALWAYS reverted.
//
// FIX:
//   verifyAndSeal() merges both steps into a single call. The hash is computed
//   from config addresses only (no timestamp), so it is fully deterministic.
//   The timelock schedules one call: systemSealer.verifyAndSeal(config).
// ──────────────────────────────────────────────────────────────────────────────

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreVault } from "../../src/core/CoreVault.sol";
import { QueueModule } from "../../src/core/modules/QueueModule.sol";
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
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";

contract SystemSealer_TimestampHash_POC is Test {
    uint256 constant TIMELOCK_DELAY = 2 days;

    address internal deployer;
    address internal guardian;
    address internal vetoer;
    address internal treasury;

    ERC20Mock internal usdc;
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

        usdc = new ERC20Mock("USDC", "USDC", 6);
        MockParamsProvider params = new MockParamsProvider();
        params.setLockPeriod(0);

        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = deployer;
        executors[0] = deployer;
        rootTimelock = new IncentivesTimelock(TIMELOCK_DELAY, proposers, executors, deployer);

        feeCollector = new FeeCollector(address(rootTimelock), treasury, treasury, treasury, 7000, 200, 3000);
        globalConfig = new GlobalConfig(address(rootTimelock), 50, 100, 2000, 86400, 10, 500, 3600, 3600);

        systemSealer = new SystemSealer();
        SelectorRegistry selectorRegistry = new SelectorRegistry();

        vault = new CoreVault(
            IERC20Metadata(address(usdc)), "Vault", "V", deployer, address(feeCollector), address(params)
        );

        _wireModules(address(selectorRegistry));

        IBufferManager.BufferConfig memory bufCfg = IBufferManager.BufferConfig({
            targetHotBps: 1000, minHotBps: 500, targetWarmBps: 1000, maxWarmBps: 2000,
            opsReserveTargetBps: 100, maxWarmSlippageBps: 50, asset: address(usdc),
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
        usdc._mint(deployer, deadAmt);
        usdc.approve(address(vault), deadAmt);
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
            deployer:             deployer
        });

        (bool ok, string memory reason) = systemSealer.canSeal(sealConfig);
        assertTrue(ok, string.concat("setUp: canSeal failed: ", reason));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // FIX: single-call batch with verifyAndSeal seals atomically
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice verifyAndSeal() is a single-call timelock batch.
     *
     *         The operator schedules:
     *           [systemSealer.verifyAndSeal(config)]
     *
     *         No configHash needs to be known at scheduleBatch() time.
     *         The hash is computed from config addresses only — no block.timestamp —
     *         so it is deterministic regardless of execution block.
     *
     *         After executeBatch() completes:
     *           - vault.isSystemSealed() == true
     *           - vault.pendingSealHash() == keccak256(abi.encode(...addresses...))
     */
    function test_single_call_verifyAndSeal_seals_atomically() public {
        uint256 t_schedule = block.timestamp;

        address[] memory targets  = new address[](1);
        uint256[] memory values   = new uint256[](1);
        bytes[]   memory payloads = new bytes[](1);

        targets[0]  = address(systemSealer);
        payloads[0] = abi.encodeCall(SystemSealer.verifyAndSeal, (sealConfig));

        bytes32 salt = keccak256("poc-salt");

        vm.prank(deployer);
        rootTimelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, TIMELOCK_DELAY);

        vm.warp(t_schedule + TIMELOCK_DELAY + 1);

        vm.prank(deployer);
        rootTimelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        assertTrue(vault.isSystemSealed(), "vault must be sealed after single-call verifyAndSeal batch");
        assertNotEq(vault.pendingSealHash(), bytes32(0), "pendingSealHash must record the verified config hash");

        console2.log("Vault sealed at block.timestamp:", block.timestamp);
        console2.log("configHash stored:", vm.toString(vault.pendingSealHash()));
    }

    /**
     * @notice Hash is deterministic — computed at execute time from addresses only.
     *         The operator can pre-compute the exact same hash at schedule time.
     *         This proves the TOCTOU vulnerability from the old timestamp-based hash
     *         no longer exists.
     */
    function test_configHash_is_deterministic_across_timelock_delay() public {
        bytes32 hashAtSchedule = keccak256(abi.encode(
            sealConfig.vault,
            sealConfig.rootTimelock,
            sealConfig.guardian,
            sealConfig.vetoer,
            sealConfig.feeCollector,
            sealConfig.strategy,
            sealConfig.incentives,
            sealConfig.incentivesEngine,
            sealConfig.rewardsPayoutManager
        ));

        // Advance past the timelock delay and seal
        address[] memory targets  = new address[](1);
        uint256[] memory values   = new uint256[](1);
        bytes[]   memory payloads = new bytes[](1);
        targets[0]  = address(systemSealer);
        payloads[0] = abi.encodeCall(SystemSealer.verifyAndSeal, (sealConfig));

        vm.prank(deployer);
        rootTimelock.scheduleBatch(targets, values, payloads, bytes32(0), keccak256("det-salt"), TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        vm.prank(deployer);
        rootTimelock.executeBatch(targets, values, payloads, bytes32(0), keccak256("det-salt"));

        // Hash computed at schedule time must equal hash stored at execute time
        assertEq(vault.pendingSealHash(), hashAtSchedule,
            "configHash must be identical at schedule time and execute time - no timestamp dependency");

        console2.log("hash(schedule) == hash(execute):", vm.toString(hashAtSchedule));
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _wireModules(address selectorRegistry) internal {
        vault.setSelectorRegistry(selectorRegistry);

        QueueModule qm        = new QueueModule();
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
