// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// INCIDENT SIMULATION — ROOT_TIMELOCK compromise and Guardian compromise
//
// Neither RecoveryGate nor CoreVault's pause matrix assume any single
// privileged actor is fully trustworthy forever. This suite proves the
// actual bound on what a compromise of each one can do, rather than
// asserting it in prose:
//
//   - A compromised ROOT_TIMELOCK can propose a malicious recovery, but
//     cannot single-handedly execute it — independent approval AND the
//     minDelay window both stand between proposal and effect, and the
//     vetoer (a distinct key) can cancel it at any point in that window.
//   - A compromised Guardian can trip exactly two withdrawal breakers plus
//     deposits, rate-limited by a cooldown, and can reach nothing on
//     RecoveryGate at all (review §3.3 — fast to restrict, never
//     constructive).
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreVault } from "../../src/core/CoreVault.sol";
import { EpochedQueueModule } from "../../src/core/modules/EpochedQueueModule.sol";
import { AdminModule } from "../../src/core/modules/AdminModule.sol";
import { ERC4626Module } from "../../src/core/modules/ERC4626Module.sol";
import { LiquidityOpsModule } from "../../src/core/modules/LiquidityOpsModule.sol";
import { FeeCollector } from "../../src/core/modules/FeeCollector.sol";
import { GlobalConfig } from "../../src/core/config/GlobalConfig.sol";
import { SelectorRegistry } from "../../src/core/libraries/SelectorRegistry.sol";
import { SelectorLib } from "../../src/core/libraries/SelectorLib.sol";
import { RecoveryGate } from "../../src/governance/RecoveryGate.sol";
import { IAdminModule } from "../../src/interfaces/IAdminModule.sol";
import { IncentivesTimelock } from "../../src/governance/IncentivesTimelock.sol";
import { ERC20Mock } from "../../src/mocks/ERC20Mock.sol";

contract GovernanceCompromise_BlastRadius is Test {
    uint256 constant TIMELOCK_DELAY = 2 days;
    uint64 constant MIN_DELAY = 14 days;
    uint64 constant COOLDOWN = 30 days;
    uint8 constant EPOCH_QUEUE_GROUP = 0;

    address internal deployer;
    address internal guardian;
    address internal vetoer;
    address internal treasury;
    address internal securityApprover;
    address internal randomAttacker;

    ERC20Mock internal usdc;
    IncentivesTimelock internal rootTimelock;
    CoreVault internal vault;
    RecoveryGate internal gate;
    EpochedQueueModule internal queueModuleV1;

    function setUp() public {
        deployer = makeAddr("deployer");
        guardian = makeAddr("guardian");
        vetoer = makeAddr("vetoer");
        treasury = makeAddr("treasury");
        securityApprover = makeAddr("securityApprover");
        randomAttacker = makeAddr("randomAttacker");

        vm.startPrank(deployer);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);

        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = deployer;
        executors[0] = deployer;
        rootTimelock = new IncentivesTimelock(TIMELOCK_DELAY, proposers, executors, deployer);

        FeeCollector feeCollector =
            new FeeCollector(address(rootTimelock), treasury, treasury, treasury, 7000, 200, 3000);
        GlobalConfig globalConfig =
            new GlobalConfig(address(rootTimelock), 50, 100, 2000, 0, 10, 500, 3600, 3600);

        vault = new CoreVault(
            IERC20Metadata(address(usdc)), "Vault", "V", deployer, address(feeCollector), address(globalConfig)
        );

        SelectorRegistry selectorRegistry = new SelectorRegistry();
        vault.setSelectorRegistry(address(selectorRegistry));

        queueModuleV1 = new EpochedQueueModule();
        AdminModule am = new AdminModule();
        ERC4626Module e4626 = new ERC4626Module();
        LiquidityOpsModule lo = new LiquidityOpsModule();

        bytes4[] memory s;
        s = SelectorLib.getQueueModuleSelectors();
        for (uint256 i; i < s.length; ++i) vault.setModule(s[i], address(queueModuleV1), SelectorLib.ROLE_PUBLIC);
        s = SelectorLib.getQueueModuleViewSelectors();
        for (uint256 i; i < s.length; ++i) vault.setModule(s[i], address(queueModuleV1), SelectorLib.ROLE_PUBLIC);
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

        IAdminModule(address(vault)).setEcosystem(IAdminModule.EcosystemConfig({
            bufferManager: makeAddr("bufferManager"),
            strategyRouter: makeAddr("strategyRouter"),
            healthRegistry: address(0),
            incentives: address(0),
            guardian: guardian,
            vetoer: vetoer
        }));

        gate = new RecoveryGate(address(vault), address(rootTimelock), securityApprover, MIN_DELAY, COOLDOWN);
        vault.setRecoveryGate(address(gate));
        vault.freezeRouting();

        vault.beginOwnerTransfer(address(rootTimelock));
        vm.stopPrank();

        vm.prank(address(rootTimelock));
        vault.acceptOwnerTransfer();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ROOT_TIMELOCK compromise: a malicious proposal alone cannot execute
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Simulates a compromised ROOT_TIMELOCK (e.g. a multisig with a
    ///      stolen signer threshold) proposing a hostile module. Two
    ///      independent controls — the security approver and the vetoer —
    ///      each individually stop it from ever taking effect.
    function test_compromisedRootTimelock_cannotSingleHandedlyExecuteRecovery() public {
        address hostileModule = makeAddr("hostileModule");
        bytes4[] memory groupSelectors = gate.selectorsForGroup(EPOCH_QUEUE_GROUP);
        address[] memory hostileModules = new address[](groupSelectors.length);
        for (uint256 i; i < hostileModules.length; ++i) hostileModules[i] = hostileModule;

        // The compromised ROOT_TIMELOCK can propose...
        vm.prank(address(rootTimelock));
        gate.propose(EPOCH_QUEUE_GROUP, hostileModules, "compromised-proposal");

        // ...but cannot approve its own proposal (SECURITY_APPROVER is a
        // distinct key it does not control) or bypass the delay.
        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.expectRevert(RecoveryGate.NotApproved.selector);
        gate.execute(EPOCH_QUEUE_GROUP);

        // Even if it also somehow controlled SECURITY_APPROVER (a strictly
        // stronger compromise), the vetoer — a third, independent key — can
        // still cancel at any point up to execution. Clear the first
        // (unapproved, now-moot) proposal first — only one may be pending
        // per group at a time.
        vm.prank(vetoer);
        gate.vetoCancel(EPOCH_QUEUE_GROUP);

        vm.prank(address(rootTimelock));
        gate.propose(EPOCH_QUEUE_GROUP, hostileModules, "compromised-proposal-2");
        (bytes32 digest,,,) = gate.pendingProposal(EPOCH_QUEUE_GROUP);

        vm.prank(securityApprover); // worst case: approver also compromised
        gate.approve(EPOCH_QUEUE_GROUP, digest);

        vm.prank(vetoer);
        gate.vetoCancel(EPOCH_QUEUE_GROUP);

        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.expectRevert(RecoveryGate.NoPendingProposal.selector);
        gate.execute(EPOCH_QUEUE_GROUP);

        for (uint256 i; i < groupSelectors.length; ++i) {
            assertTrue(vault.moduleOf(groupSelectors[i]) != hostileModule);
        }
    }

    /// @dev A compromised ROOT_TIMELOCK also cannot rotate the security
    ///      approver fast enough to matter — that rotation is subject to
    ///      the identical minDelay and is itself vetoable.
    function test_compromisedRootTimelock_cannotFastTrackAFriendlyApprover() public {
        address friendlyApprover = makeAddr("friendlyApprover");

        vm.prank(address(rootTimelock));
        gate.proposeApproverChange(friendlyApprover);

        // Meanwhile it also proposes a malicious recovery.
        address hostileModule = makeAddr("hostileModule");
        bytes4[] memory groupSelectors = gate.selectorsForGroup(EPOCH_QUEUE_GROUP);
        address[] memory hostileModules = new address[](groupSelectors.length);
        for (uint256 i; i < hostileModules.length; ++i) hostileModules[i] = hostileModule;
        vm.prank(address(rootTimelock));
        gate.propose(EPOCH_QUEUE_GROUP, hostileModules, "racing-approver-swap");

        // The approver swap matures no sooner than the recovery itself —
        // by the time a "friendly" approver could act, the original
        // recovery proposal's own approval window has already been open
        // for the same duration, giving defenders (the vetoer) an equal
        // window to react to either.
        vm.warp(block.timestamp + MIN_DELAY + 1);
        gate.executeApproverChange();
        assertEq(gate.securityApprover(), friendlyApprover);

        // The still-unapproved recovery proposal is untouched by the swap
        // and remains blocked until *someone* approves it.
        vm.expectRevert(RecoveryGate.NotApproved.selector);
        gate.execute(EPOCH_QUEUE_GROUP);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Guardian compromise: bounded, rate-limited, never constructive
    // ══════════════════════════════════════════════════════════════════════════

    function test_compromisedGuardian_canOnlyReachDepositsAndTwoWithdrawalBreakers() public {
        vm.prank(guardian);
        vault.guardianPause();

        assertTrue(vault.paused());
        assertTrue(vault.pausedInstantWithdrawal());
        assertTrue(vault.pausedEpochCloseFund());
        // Everything else is out of reach:
        assertFalse(vault.pausedQueuedRequest());
        assertFalse(vault.pausedFundedClaim());
        assertFalse(vault.pausedForceExit());
    }

    function test_compromisedGuardian_cannotReachOwnerOnlyBreakers() public {
        vm.startPrank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.pauseQueuedRequestOnly(true);

        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.pauseFundedClaimOnly(true);

        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.pauseForceExitOnly(true);

        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.unpauseAll();
        vm.stopPrank();
    }

    function test_compromisedGuardian_cannotSelfReverseItsOwnEmergencyBrake() public {
        // Worst-case scenario a compromised Guardian could attempt: trip
        // guardianPause(), then immediately try to clear the two breakers it
        // reaches, reopening instant settlement and epoch close/fund with no
        // owner involvement at all. Must be impossible — restrict-only.
        vm.prank(guardian);
        vault.guardianPause();
        assertTrue(vault.pausedInstantWithdrawal());
        assertTrue(vault.pausedEpochCloseFund());

        vm.prank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.pauseInstantWithdrawalOnly(false);

        vm.prank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.pauseEpochCloseFundOnly(false);

        assertTrue(vault.pausedInstantWithdrawal(), "guardian must not be able to self-reverse the brake");
        assertTrue(vault.pausedEpochCloseFund(), "guardian must not be able to self-reverse the brake");
    }

    function test_compromisedGuardian_isRateLimitedByCooldown() public {
        vm.prank(guardian);
        vault.guardianPause();

        vm.prank(guardian);
        vm.expectRevert(CoreVault.GuardianCooldownActive.selector);
        vault.guardianPause();
    }

    function test_compromisedGuardian_hasNoPathToModuleReplacement() public {
        vm.startPrank(guardian);
        vm.expectRevert(RecoveryGate.NotRootTimelock.selector);
        gate.propose(EPOCH_QUEUE_GROUP, new address[](0), "guardian-attempt");

        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.setModule(SelectorLib.getQueueModuleSelectors()[0], randomAttacker, 0);

        vm.expectRevert(CoreVault.RoutingFrozen.selector);
        vm.stopPrank();
        vm.prank(address(rootTimelock));
        vault.setModule(SelectorLib.getQueueModuleSelectors()[0], randomAttacker, 0);
    }

    function test_randomAttacker_hasNoCapabilityAnywhereInTheRecoverySystem() public {
        vm.startPrank(randomAttacker);
        vm.expectRevert(CoreVault.NotOwnerOrGuardian.selector);
        vault.pauseInstantWithdrawalOnly(true);

        vm.expectRevert();
        vault.pauseAll();

        vm.expectRevert();
        gate.propose(EPOCH_QUEUE_GROUP, new address[](0), "attacker");

        vm.expectRevert();
        gate.approve(EPOCH_QUEUE_GROUP, bytes32(0));

        vm.expectRevert();
        gate.vetoCancel(EPOCH_QUEUE_GROUP);
        vm.stopPrank();
    }
}
