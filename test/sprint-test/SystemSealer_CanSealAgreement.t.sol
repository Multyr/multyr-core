// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// SPRINT SECURITY TEST — SystemSealer single verification engine (review §25)
//
// BUG (0bab749 architecture review, 2026-08-14):
//   canSeal() and verifyAndSeal() maintained two independently-written
//   invariant lists. Two invariants existed ONLY in verifyAndSeal(): the
//   strategy role checks (_verifyStrategyRoles) and the deployer-retains-no-
//   roles check. canSeal() could therefore return (true, "") for a config
//   that verifyAndSeal() would still revert on — exactly the drift risk
//   review §25 warns about. Neither function checked block.chainid at all
//   (review §24/§42).
//
// FIX:
//   Both entry points now call one shared _verifyLiveState(). This suite
//   proves the closing requirement of review §42 directly: a positive result
//   from canSeal() must imply verifyAndSeal() succeeds against unchanged
//   state — including the two cases that used to be checked in one function
//   but not the other, plus the new chainId binding.
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

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
import { Incentives } from "../../src/core/modules/Incentives.sol";
import { IIncentives } from "../../src/interfaces/IIncentives.sol";
import { IAdminModule } from "../../src/interfaces/IAdminModule.sol";
import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";
import { IncentivesTimelock } from "../../src/governance/IncentivesTimelock.sol";
import { ERC20Mock } from "../../src/mocks/ERC20Mock.sol";

/// @dev Minimal AccessControl strategy stand-in — only used to exercise
///      SystemSealer's strategy-role invariant (INVARIANT 9). Whoever holds
///      DEFAULT_ADMIN_ROLE can grant/revoke every other role by default.
contract MinimalStrategyMock is AccessControl {
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }
}

contract SystemSealer_CanSealAgreement_Test is Test {
    uint256 constant TIMELOCK_DELAY = 2 days;

    address internal deployer;
    address internal guardian;
    address internal vetoer;
    address internal treasury;

    ERC20Mock internal usdc; // 6dp — decimals overrides are exempt
    IncentivesTimelock internal rootTimelock;
    CoreVault internal vault;
    FeeCollector internal feeCollector;
    GlobalConfig internal globalConfig;
    BufferManager internal bufferManager;
    StrategyRouter internal strategyRouter;
    StrategyHealthRegistry internal healthRegistry;
    SystemSealer internal systemSealer;
    MinimalStrategyMock internal strategy;

    SystemSealer.SealConfig internal sealConfig;

    function setUp() public {
        deployer = makeAddr("deployer");
        guardian = makeAddr("guardian");
        vetoer = makeAddr("vetoer");
        treasury = makeAddr("treasury");

        vm.startPrank(deployer);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);

        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = deployer;
        executors[0] = deployer;
        rootTimelock = new IncentivesTimelock(TIMELOCK_DELAY, proposers, executors, deployer);

        feeCollector =
            new FeeCollector(address(rootTimelock), treasury, treasury, treasury, 7000, 200, 3000);
        globalConfig = new GlobalConfig(address(rootTimelock), 50, 100, 2000, 0, 10, 500, 3600, 3600);

        systemSealer = new SystemSealer();
        SelectorRegistry selectorRegistry = new SelectorRegistry();

        vault = new CoreVault(
            IERC20Metadata(address(usdc)), "Vault", "V", deployer, address(feeCollector), address(globalConfig)
        );

        _wireModules(address(selectorRegistry));

        IBufferManager.BufferConfig memory bufCfg = IBufferManager.BufferConfig({
            targetHotBps: 1000, minHotBps: 500, targetWarmBps: 1000, maxWarmBps: 2000,
            opsReserveTargetBps: 100, maxWarmSlippageBps: 50, asset: address(usdc),
            warmAdapter: address(0), twapWindowSec: 0, paused: true
        });
        bufferManager = new BufferManager(deployer, address(vault), bufCfg);
        strategyRouter = new StrategyRouter(deployer, address(vault), address(globalConfig));
        healthRegistry = new StrategyHealthRegistry(deployer, guardian);

        // Strategy correctly wired from the start: ROOT_TIMELOCK holds
        // DEFAULT_ADMIN_ROLE/PARAM_ROLE, CoreVault holds CORE_ROLE, guardian
        // holds KEEPER_ROLE, deployer holds nothing. Individual tests break
        // one of these to prove canSeal() now catches it.
        strategy = new MinimalStrategyMock(deployer);
        strategy.grantRole(strategy.DEFAULT_ADMIN_ROLE(), address(rootTimelock));
        strategy.grantRole(strategy.PARAM_ROLE(), address(rootTimelock));
        strategy.grantRole(strategy.CORE_ROLE(), address(vault));
        strategy.grantRole(strategy.KEEPER_ROLE(), guardian);
        strategy.renounceRole(strategy.DEFAULT_ADMIN_ROLE(), deployer);

        IAdminModule(address(vault)).setEcosystem(IAdminModule.EcosystemConfig({
            bufferManager: address(bufferManager),
            strategyRouter: address(strategyRouter),
            healthRegistry: address(healthRegistry),
            incentives: address(0),
            guardian: guardian,
            vetoer: vetoer
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
            chainId: block.chainid,
            vault: address(vault),
            strategyRouter: address(strategyRouter),
            bufferManager: address(bufferManager),
            healthRegistry: address(healthRegistry),
            globalConfig: address(globalConfig),
            feeCollector: address(feeCollector),
            rootTimelock: address(rootTimelock),
            guardian: guardian,
            vetoer: vetoer,
            strategy: address(strategy),
            incentives: address(0),
            incentivesEngine: address(0),
            rewardsPayoutManager: address(0),
                recoveryGate: address(0),
                recoveryManifestVersion: 0,
            rewardsTreasury: address(0),
            deployer: deployer
        });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Happy path — the property review §42 requires: canSeal() true implies
    // verifyAndSeal() succeeds against unchanged state. Exercises the strategy
    // and chainId dimensions that were previously untested end-to-end.
    // ══════════════════════════════════════════════════════════════════════════

    function test_canSealTrue_impliesVerifyAndSealSucceeds() public {
        (bool ok, string memory reason) = systemSealer.canSeal(sealConfig);
        assertTrue(ok, string.concat("canSeal should pass on a fully correct config: ", reason));

        _scheduleAndExecute(sealConfig, "happy-path-salt");
        assertTrue(vault.isSystemSealed(), "vault must seal when canSeal() already agreed it could");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Live-wiring bind checks (review §24) — a correctly governed decoy
    // component must not be able to satisfy the seal if it is not the
    // component actually wired into the vault. Previously only globalConfig
    // had this check (fixed on PR #11); feeCollector/strategyRouter/
    // bufferManager/healthRegistry did not.
    // ══════════════════════════════════════════════════════════════════════════

    function test_canSeal_and_verifyAndSeal_agree_whenSystemSealerIsNotAuthorizedOnVault() public {
        // A second, otherwise-identical SystemSealer that the vault never
        // authorized via setAuthorizedSealer(). canSeal() on THIS instance
        // must reject, even though every other invariant in sealConfig is
        // satisfied — otherwise a deploy-day dry run against the wrong
        // SystemSealer address could report "ready to seal" when
        // verifyAndSeal() would actually revert with NotAuthorizedSealer.
        SystemSealer unauthorizedSealer = new SystemSealer();

        (bool ok, string memory reason) = unauthorizedSealer.canSeal(sealConfig);
        assertFalse(ok, "canSeal must reject a SystemSealer the vault did not authorize");
        assertEq(reason, "SystemSealer not authorized on vault");

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        targets[0] = address(unauthorizedSealer);
        payloads[0] = abi.encodeCall(SystemSealer.verifyAndSeal, (sealConfig));

        bytes32 salt = keccak256(abi.encode("unauthorized-sealer-salt"));

        vm.prank(deployer);
        rootTimelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.prank(deployer);
        vm.expectRevert();
        rootTimelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        assertFalse(vault.isSystemSealed());
    }

    function test_canSeal_and_verifyAndSeal_agree_whenIncentivesIsADecoy() public {
        IIncentives.Params memory p =
            IIncentives.Params({ cliffDays: 30, fullDays: 180, bmaxWad: 3e16, vestingDays: 180 });

        Incentives realIncentives = new Incentives(address(rootTimelock), address(vault), treasury, p);
        vm.prank(address(rootTimelock));
        IAdminModule(address(vault)).setIncentives(address(realIncentives));

        Incentives decoy = new Incentives(address(rootTimelock), address(vault), treasury, p);

        SystemSealer.SealConfig memory decoyConfig = sealConfig;
        decoyConfig.incentives = address(decoy);

        (bool ok, string memory reason) = systemSealer.canSeal(decoyConfig);
        assertFalse(ok, "canSeal must reject a correctly-governed Incentives the vault does not read from");
        assertEq(reason, "Incentives not bound to vault");

        _scheduleAndExpectRevert(decoyConfig, "incentives-decoy-salt");
        assertFalse(vault.isSystemSealed());
    }

    function test_canSeal_and_verifyAndSeal_agree_whenFeeCollectorIsADecoy() public {
        FeeCollector decoy =
            new FeeCollector(address(rootTimelock), treasury, treasury, treasury, 7000, 200, 3000);
        SystemSealer.SealConfig memory decoyConfig = sealConfig;
        decoyConfig.feeCollector = address(decoy);

        (bool ok, string memory reason) = systemSealer.canSeal(decoyConfig);
        assertFalse(ok, "canSeal must reject a correctly-governed FeeCollector the vault does not read from");
        assertEq(reason, "FeeCollector not bound to vault");

        _scheduleAndExpectRevert(decoyConfig, "feecollector-decoy-salt");
        assertFalse(vault.isSystemSealed());
    }

    function test_canSeal_and_verifyAndSeal_agree_whenStrategyRouterIsADecoy() public {
        StrategyRouter decoy = new StrategyRouter(deployer, address(vault), address(globalConfig));
        vm.prank(deployer);
        decoy.transferOwnership(address(rootTimelock));

        SystemSealer.SealConfig memory decoyConfig = sealConfig;
        decoyConfig.strategyRouter = address(decoy);

        (bool ok, string memory reason) = systemSealer.canSeal(decoyConfig);
        assertFalse(ok, "canSeal must reject a correctly-governed StrategyRouter the vault does not read from");
        assertEq(reason, "StrategyRouter not bound to vault");

        _scheduleAndExpectRevert(decoyConfig, "router-decoy-salt");
        assertFalse(vault.isSystemSealed());
    }

    function test_canSeal_and_verifyAndSeal_agree_whenBufferManagerIsADecoy() public {
        IBufferManager.BufferConfig memory bufCfg = IBufferManager.BufferConfig({
            targetHotBps: 1000, minHotBps: 500, targetWarmBps: 1000, maxWarmBps: 2000,
            opsReserveTargetBps: 100, maxWarmSlippageBps: 50, asset: address(usdc),
            warmAdapter: address(0), twapWindowSec: 0, paused: true
        });
        BufferManager decoy = new BufferManager(deployer, address(vault), bufCfg);
        vm.prank(deployer);
        decoy.transferOwnership(address(rootTimelock));

        SystemSealer.SealConfig memory decoyConfig = sealConfig;
        decoyConfig.bufferManager = address(decoy);

        (bool ok, string memory reason) = systemSealer.canSeal(decoyConfig);
        assertFalse(ok, "canSeal must reject a correctly-governed BufferManager the vault does not read from");
        assertEq(reason, "BufferManager not bound to vault");

        _scheduleAndExpectRevert(decoyConfig, "buffermanager-decoy-salt");
        assertFalse(vault.isSystemSealed());
    }

    function test_canSeal_and_verifyAndSeal_agree_whenHealthRegistryIsADecoy() public {
        StrategyHealthRegistry decoy = new StrategyHealthRegistry(deployer, guardian);
        vm.prank(deployer);
        decoy.transferOwnership(address(rootTimelock));

        SystemSealer.SealConfig memory decoyConfig = sealConfig;
        decoyConfig.healthRegistry = address(decoy);

        (bool ok, string memory reason) = systemSealer.canSeal(decoyConfig);
        assertFalse(ok, "canSeal must reject a correctly-governed HealthRegistry the vault does not read from");
        assertEq(reason, "HealthRegistry not bound to vault");

        _scheduleAndExpectRevert(decoyConfig, "healthregistry-decoy-salt");
        assertFalse(vault.isSystemSealed());
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Strategy role invariant — previously checked ONLY in verifyAndSeal().
    // canSeal() used to return (true, "") here; it must now agree with
    // verifyAndSeal() and reject it too.
    // ══════════════════════════════════════════════════════════════════════════

    function test_canSeal_and_verifyAndSeal_agree_whenRootTimelockMissingParamRole() public {
        // Fetch the role constant BEFORE pranking — it's itself an external
        // call, and vm.prank only applies to the single next call.
        bytes32 paramRole = strategy.PARAM_ROLE();
        vm.prank(address(rootTimelock));
        strategy.revokeRole(paramRole, address(rootTimelock));

        (bool ok, string memory reason) = systemSealer.canSeal(sealConfig);
        assertFalse(ok, "canSeal must now catch a missing strategy PARAM_ROLE, not just verifyAndSeal");
        assertEq(reason, "Strategy: ROOT_TIMELOCK missing PARAM_ROLE");

        _scheduleAndExpectRevert(sealConfig, "missing-param-role-salt");
        assertFalse(vault.isSystemSealed());
    }

    function test_canSeal_and_verifyAndSeal_agree_whenGuardianMissingKeeperRole() public {
        bytes32 keeperRole = strategy.KEEPER_ROLE();
        vm.prank(address(rootTimelock));
        strategy.revokeRole(keeperRole, guardian);

        (bool ok, string memory reason) = systemSealer.canSeal(sealConfig);
        assertFalse(ok, "canSeal must now catch a missing Guardian KEEPER_ROLE");
        assertEq(reason, "Strategy: Guardian missing KEEPER_ROLE (backup)");

        _scheduleAndExpectRevert(sealConfig, "missing-keeper-role-salt");
        assertFalse(vault.isSystemSealed());
    }

    function test_canSeal_and_verifyAndSeal_agree_whenCoreVaultMissingCoreRole() public {
        bytes32 coreRole = strategy.CORE_ROLE();
        vm.prank(address(rootTimelock));
        strategy.revokeRole(coreRole, address(vault));

        (bool ok, string memory reason) = systemSealer.canSeal(sealConfig);
        assertFalse(ok, "canSeal must now catch a missing CoreVault CORE_ROLE");
        assertEq(reason, "Strategy: CoreVault missing CORE_ROLE");

        _scheduleAndExpectRevert(sealConfig, "missing-core-role-salt");
        assertFalse(vault.isSystemSealed());
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Deployer-retains-no-roles invariant — previously checked ONLY in
    // verifyAndSeal(). canSeal() used to return (true, "") here too.
    // ══════════════════════════════════════════════════════════════════════════

    function test_canSeal_and_verifyAndSeal_agree_whenDeployerStillHasStrategyAdminRole() public {
        // Deployer forgot to renounce DEFAULT_ADMIN_ROLE on the strategy after
        // handing governance to ROOT_TIMELOCK — OZ AccessControl allows
        // multiple simultaneous admins, so this is a real, reachable
        // misconfiguration distinct from vault ownership (which invariant 1
        // already forces to ROOT_TIMELOCK before this check runs).
        bytes32 adminRole = strategy.DEFAULT_ADMIN_ROLE();
        vm.prank(address(rootTimelock));
        strategy.grantRole(adminRole, deployer);

        (bool ok, string memory reason) = systemSealer.canSeal(sealConfig);
        assertFalse(ok, "canSeal must catch a deployer that still holds strategy DEFAULT_ADMIN_ROLE");
        assertEq(reason, "Deployer still has strategy DEFAULT_ADMIN_ROLE");

        _scheduleAndExpectRevert(sealConfig, "deployer-strategy-admin-salt");
        assertFalse(vault.isSystemSealed());
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Chain binding — neither function checked this before (review §24/§42).
    // ══════════════════════════════════════════════════════════════════════════

    function test_canSeal_and_verifyAndSeal_agree_whenChainIdMismatched() public {
        SystemSealer.SealConfig memory badConfig = sealConfig;
        badConfig.chainId = sealConfig.chainId + 1;

        (bool ok, string memory reason) = systemSealer.canSeal(badConfig);
        assertFalse(ok, "canSeal must reject a manifest built for a different chain");
        assertEq(reason, "chainId mismatch");

        _scheduleAndExpectRevert(badConfig, "wrong-chain-salt");
        assertFalse(vault.isSystemSealed());
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _scheduleAndExecute(SystemSealer.SealConfig memory config, bytes32 saltSeed) internal {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        targets[0] = address(systemSealer);
        payloads[0] = abi.encodeCall(SystemSealer.verifyAndSeal, (config));

        bytes32 salt = keccak256(abi.encode(saltSeed));

        vm.prank(deployer);
        rootTimelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.prank(deployer);
        rootTimelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    function _scheduleAndExpectRevert(SystemSealer.SealConfig memory config, bytes32 saltSeed) internal {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        targets[0] = address(systemSealer);
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
        AdminModule am = new AdminModule();
        ERC4626Module e4626 = new ERC4626Module();
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
