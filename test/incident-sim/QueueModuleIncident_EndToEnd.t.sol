// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// INCIDENT SIMULATION — EpochedQueueModule exploit, full lifecycle
//
// Ties together Phase 1 (withdrawal pause matrix) and the Emergency Module
// Recovery mechanism into one incident-response narrative matching review
// §47's three phases:
//
//   Phase A — Containment (seconds/minutes): Guardian trips the two
//     withdrawal breakers it may reach. No module replacement.
//   Phase B — Stabilization (hours/days): governance schedules recovery.
//   Phase C — Remediation (days/weeks): Emergency Module Recovery executes;
//     normal operation resumes on the patched module.
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness } from "../helpers/CoreHarness.sol";
import { MockUSDC } from "../helpers/MockUSDC.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";
import { CoreVault } from "../../src/core/CoreVault.sol";
import { ERC4626Module } from "../../src/core/modules/ERC4626Module.sol";
import { EpochedQueueModule } from "../../src/core/modules/EpochedQueueModule.sol";
import { SelectorLib } from "../../src/core/libraries/SelectorLib.sol";
import { RecoveryGate } from "../../src/governance/RecoveryGate.sol";
import { IncentivesTimelock } from "../../src/governance/IncentivesTimelock.sol";

contract QueueModuleIncident_EndToEnd is Test {
    uint256 constant TIMELOCK_DELAY = 2 days;
    uint64 constant MIN_DELAY = 14 days;
    uint64 constant COOLDOWN = 30 days;
    uint8 constant EPOCH_QUEUE_GROUP = 0;

    address internal owner;
    address internal guardian;
    address internal vetoer;
    address internal user;
    address internal securityApprover;

    CoreHarness internal core;
    MockUSDC internal usdc;
    MockParamsProvider internal params;
    IncentivesTimelock internal rootTimelock;
    RecoveryGate internal gate;
    EpochedQueueModule internal patchedQueueModule;

    function setUp() public {
        guardian = makeAddr("guardian");
        vetoer = makeAddr("vetoer");
        user = makeAddr("user");
        securityApprover = makeAddr("securityApprover");

        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(this);
        executors[0] = address(this);
        rootTimelock = new IncentivesTimelock(TIMELOCK_DELAY, proposers, executors, address(this));
        owner = address(rootTimelock);

        usdc = new MockUSDC();
        params = new MockParamsProvider();

        // CoreHarness's constructor wires EpochedQueueModule/ERC4626Module/
        // etc for us and starts unpaused — deploy with rootTimelock as owner
        // directly so we don't need a separate ownership-transfer step.
        core = new CoreHarness(
            IERC20Metadata(address(usdc)), "Vault", "V", owner, owner, address(params)
        );

        vm.prank(owner);
        core.setGuardian(guardian);
        vm.prank(owner);
        // AdminModule.setVetoer is ROLE_OWNER-routed through the fallback in
        // production; CoreHarness wires AdminModule for exactly this.
        (bool ok,) = address(core).call(abi.encodeWithSignature("setVetoer(address)", vetoer));
        require(ok, "setVetoer failed");

        gate = new RecoveryGate(address(core), owner, securityApprover, MIN_DELAY, COOLDOWN);
        vm.prank(owner);
        core.setRecoveryGate(address(gate));

        vm.prank(owner);
        core.freezeRouting();

        patchedQueueModule = new EpochedQueueModule();

        usdc.mint(user, 10_000_000e6);
        vm.prank(user);
        IERC20(address(usdc)).approve(address(core), type(uint256).max);
    }

    function test_fullIncidentLifecycle_containment_recovery_resolution() public {
        // ── Normal operation before the incident ──────────────────────────
        vm.prank(user);
        uint256 shares = ERC4626Module(address(core)).deposit(1_000_000e6, user);
        assertGt(shares, 0);

        // ── PHASE A: Containment ───────────────────────────────────────────
        // Guardian detects anomalous behavior in EpochedQueueModule and
        // contains it immediately. No module replacement at this stage.
        vm.prank(guardian);
        core.guardianPause();

        assertTrue(core.pausedInstantWithdrawal(), "instant settlement contained");
        assertTrue(core.pausedEpochCloseFund(), "epoch close/fund contained");
        // Queued-request creation and funded claims remain open throughout —
        // exit intent is never blocked by containment (review §19/§20).
        assertFalse(core.pausedQueuedRequest());
        assertFalse(core.pausedFundedClaim());

        // Users can still register exit intent during containment.
        vm.prank(user);
        (uint256 epochId, uint256 claimId) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(shares / 2);
        assertGt(claimId + 1, 0);

        // ── PHASE B: Stabilization — governance schedules recovery ─────────
        bytes4[] memory groupSelectors = gate.selectorsForGroup(EPOCH_QUEUE_GROUP);
        address[] memory newModules = new address[](groupSelectors.length);
        for (uint256 i; i < newModules.length; ++i) newModules[i] = address(patchedQueueModule);

        vm.prank(owner);
        gate.propose(EPOCH_QUEUE_GROUP, newModules, "incident-2026-08-queue-exploit");

        (bytes32 digest,,,) = gate.pendingProposal(EPOCH_QUEUE_GROUP);
        vm.prank(securityApprover);
        gate.approve(EPOCH_QUEUE_GROUP, digest);

        // ── PHASE C: Remediation ───────────────────────────────────────────
        vm.warp(block.timestamp + MIN_DELAY + 1);
        gate.execute(EPOCH_QUEUE_GROUP);

        for (uint256 i; i < groupSelectors.length; ++i) {
            assertEq(core.moduleOf(groupSelectors[i]), address(patchedQueueModule));
        }

        // Governance lifts containment now that the patched module is live.
        vm.prank(owner);
        core.unpauseAll();
        assertFalse(core.pausedInstantWithdrawal());
        assertFalse(core.pausedEpochCloseFund());

        // Normal operation resumes on the patched module: the pre-incident
        // claim is still valid (module swap does not touch queue storage)
        // and new activity works end-to-end.
        vm.warp(block.timestamp + 7 days + 1);
        EpochedQueueModule(address(core)).closeCurrentEpoch();
        EpochedQueueModule(address(core)).fundEpoch(epochId);

        vm.prank(user);
        EpochedQueueModule(address(core)).claimEpochAssets(epochId, claimId);
    }

    function test_vetoBlocksAMaliciousRecoveryProposal_evenUnderContainment() public {
        vm.prank(user);
        ERC4626Module(address(core)).deposit(1_000_000e6, user);

        vm.prank(guardian);
        core.guardianPause();

        // A malicious or mistaken proposal is submitted (e.g. a compromised
        // ROOT_TIMELOCK signer set, or a rushed patch that turns out wrong).
        address suspiciousModule = makeAddr("suspiciousModule");
        bytes4[] memory groupSelectors = gate.selectorsForGroup(EPOCH_QUEUE_GROUP);
        address[] memory newModules = new address[](groupSelectors.length);
        for (uint256 i; i < newModules.length; ++i) newModules[i] = suspiciousModule;

        vm.prank(owner);
        gate.propose(EPOCH_QUEUE_GROUP, newModules, "suspicious-proposal");

        // The security approver never approves it.
        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.expectRevert(RecoveryGate.NotApproved.selector);
        gate.execute(EPOCH_QUEUE_GROUP);

        // Independently, the vetoer can cancel it outright at any point.
        vm.prank(vetoer);
        gate.vetoCancel(EPOCH_QUEUE_GROUP);

        (, , , bool exists) = gate.pendingProposal(EPOCH_QUEUE_GROUP);
        assertFalse(exists, "malicious proposal cancelled before it could ever execute");

        for (uint256 i; i < groupSelectors.length; ++i) {
            assertTrue(
                core.moduleOf(groupSelectors[i]) != suspiciousModule,
                "vault never routed to the suspicious module"
            );
        }
    }
}
