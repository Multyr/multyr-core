// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────────────────────────────────────────────────────────────────
// SPRINT SECURITY TEST — SystemSealer atomic batch seal is IMPOSSIBLE
//
// SystemSealer.prepareSeal() bakes block.timestamp into the configHash:
//
//   configHash = keccak256(abi.encode(
//       config.vault, config.rootTimelock, ..., block.timestamp  ← non-deterministic
//   ));
//
// TimelockController.executeBatch() cannot pass return values between calls.
// The operator must encode sealFinalState(configHash) at scheduleBatch() time,
// but the hash is only known at executeBatch() time (block.timestamp differs by
// the full timelock delay). The two-call atomic batch ALWAYS reverts.
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
    // PROOF: atomic two-call batch always fails because block.timestamp in hash
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice The documented usage (SystemSealer.sol:29-31) says to schedule:
     *         [prepareSeal(config), sealFinalState(configHash)]
     *         as a single executeBatch call. This ALWAYS reverts because:
     *
     *         - configHash is computed with block.timestamp inside prepareSeal
     *         - the operator cannot know block.timestamp at execute time when scheduling
     *         - prepareSeal sets pendingSealHash = hash(t_execute)
     *         - sealFinalState receives hash(t_schedule) — they never match
     */
    function test_atomic_batch_always_reverts_due_to_timestamp_in_hash() public {
        uint256 t_schedule = block.timestamp;

        // Operator's only option: compute the hash using the current (schedule) timestamp.
        // This mirrors prepareSeal's internal keccak exactly.
        bytes32 hashAtSchedule = keccak256(abi.encode(
            sealConfig.vault,
            sealConfig.rootTimelock,
            sealConfig.guardian,
            sealConfig.vetoer,
            sealConfig.feeCollector,
            sealConfig.strategy,
            sealConfig.incentives,
            sealConfig.incentivesEngine,
            sealConfig.rewardsPayoutManager,
            t_schedule
        ));

        // Build the two-call batch as documented
        address[] memory targets  = new address[](2);
        uint256[] memory values   = new uint256[](2);
        bytes[]   memory payloads = new bytes[](2);

        targets[0]  = address(systemSealer);
        payloads[0] = abi.encodeCall(SystemSealer.prepareSeal, (sealConfig));

        targets[1]  = address(vault);
        payloads[1] = abi.encodeWithSignature("sealFinalState(bytes32)", hashAtSchedule);

        bytes32 salt = keccak256("poc-salt");

        vm.prank(deployer);
        rootTimelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, TIMELOCK_DELAY);

        // Advance past the timelock delay — this is when executeBatch can run
        uint256 t_execute = t_schedule + TIMELOCK_DELAY + 1;
        vm.warp(t_execute);

        // prepareSeal will compute hash(t_execute), not hash(t_schedule)
        bytes32 hashAtExecute = keccak256(abi.encode(
            sealConfig.vault,
            sealConfig.rootTimelock,
            sealConfig.guardian,
            sealConfig.vetoer,
            sealConfig.feeCollector,
            sealConfig.strategy,
            sealConfig.incentives,
            sealConfig.incentivesEngine,
            sealConfig.rewardsPayoutManager,
            t_execute
        ));

        console2.log("hash(t_schedule) :", vm.toString(hashAtSchedule));
        console2.log("hash(t_execute)  :", vm.toString(hashAtExecute));
        console2.log("timestamps differ by %d seconds (= timelock delay)", t_execute - t_schedule);

        assertNotEq(hashAtSchedule, hashAtExecute, "hashes must differ - timestamps are different");

        // executeBatch reverts:
        //   call[0] prepareSeal(config)          succeeds — sets pendingSealHash = hash(t_execute)
        //   call[1] sealFinalState(hash_schedule) reverts  — SealHashMismatch(hash_execute, hash_schedule)
        //   entire tx reverts, pendingSealHash is rolled back to zero
        vm.prank(deployer);
        vm.expectRevert();
        rootTimelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        assertFalse(vault.isSystemSealed(),           "vault must not be sealed");
        assertEq(vault.pendingSealHash(), bytes32(0), "pending hash must be zero - tx rolled back");
    }

    /**
     * @notice Non-atomic workaround: two separate timelock operations.
     *
     * Op A (scheduled at t0, executes at t0+delay):
     *   prepareSeal(config) — sets pendingSealHash = hash(t0+delay)
     *   Operator reads pendingSealHash from vault state (or SealPrepared event).
     *
     * Op B (scheduled at t0+delay, executes at t0+2*delay):
     *   sealFinalState(pendingSealHash) — succeeds because hash is now known
     *
     * Vault seals, but the cost is:
     *   - 2x the timelock delay (4 days for a 2-day timelock)
     *   - No atomicity: state can change between Op A and Op B
     */
    function test_non_atomic_two_op_seal_works_but_costs_double_delay() public {
        uint256 t0 = block.timestamp;

        // ── Op A: schedule prepareSeal alone ─────────────────────────────────
        address[] memory tgtsA  = new address[](1);
        uint256[] memory valsA  = new uint256[](1);
        bytes[]   memory dataA  = new bytes[](1);
        tgtsA[0] = address(systemSealer);
        dataA[0] = abi.encodeCall(SystemSealer.prepareSeal, (sealConfig));

        vm.prank(deployer);
        rootTimelock.scheduleBatch(tgtsA, valsA, dataA, bytes32(0), keccak256("op-a"), TIMELOCK_DELAY);

        vm.warp(t0 + TIMELOCK_DELAY + 1);

        vm.prank(deployer);
        rootTimelock.executeBatch(tgtsA, valsA, dataA, bytes32(0), keccak256("op-a"));

        // prepareSeal ran at t0+delay+1 — operator reads the resulting hash
        bytes32 pendingHash = vault.pendingSealHash();
        assertNotEq(pendingHash, bytes32(0), "pendingSealHash must be set after Op A");
        assertFalse(vault.isSystemSealed(),   "vault must not be sealed yet after Op A");

        console2.log("Op A executed. pendingSealHash:", vm.toString(pendingHash));

        // ── Op B: schedule sealFinalState with the now-known hash ────────────
        address[] memory tgtsB  = new address[](1);
        uint256[] memory valsB  = new uint256[](1);
        bytes[]   memory dataB  = new bytes[](1);
        tgtsB[0] = address(vault);
        dataB[0] = abi.encodeWithSignature("sealFinalState(bytes32)", pendingHash);

        vm.prank(deployer);
        rootTimelock.scheduleBatch(tgtsB, valsB, dataB, bytes32(0), keccak256("op-b"), TIMELOCK_DELAY);

        // Must wait a full second delay again before Op B can execute
        vm.warp(t0 + 2 * TIMELOCK_DELAY + 2);

        vm.prank(deployer);
        rootTimelock.executeBatch(tgtsB, valsB, dataB, bytes32(0), keccak256("op-b"));

        assertTrue(vault.isSystemSealed(), "vault sealed after non-atomic two-op flow");

        console2.log("Op B executed. Vault sealed:", vault.isSystemSealed());
        console2.log("Total elapsed: %d seconds (2x %d delay)", 2 * TIMELOCK_DELAY, TIMELOCK_DELAY);
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
        for (uint256 i; i < s.length; ++i) vault.setModule(s[i], address(lo), SelectorLib.ROLE_PUBLIC);
    }
}
