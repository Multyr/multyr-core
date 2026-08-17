// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// Emergency Module Recovery acceptance tests (review §40, adapted to the
// actual RecoveryGate/CoreVault.recoverModuleGroup API). See docs/recovery.md
// for the full design and docs/developer-response-recovery-architecture for
// the review this implements.
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

contract Recovery_Invariants is Test {
    uint256 constant TIMELOCK_DELAY = 2 days;
    uint64 constant MIN_DELAY = 14 days;
    uint64 constant COOLDOWN = 30 days;
    uint8 constant EPOCH_QUEUE_GROUP = 0;
    uint8 constant ERC4626_GROUP = 1;

    address internal deployer;
    address internal guardian;
    address internal vetoer;
    address internal treasury;
    address internal securityApprover;

    ERC20Mock internal usdc;
    IncentivesTimelock internal rootTimelock;
    CoreVault internal vault;
    FeeCollector internal feeCollector;
    GlobalConfig internal globalConfig;
    RecoveryGate internal gate;

    EpochedQueueModule internal queueModuleV1;
    EpochedQueueModule internal queueModuleV2;
    address[] internal queueGroupV2Modules;

    function setUp() public {
        deployer = makeAddr("deployer");
        guardian = makeAddr("guardian");
        vetoer = makeAddr("vetoer");
        treasury = makeAddr("treasury");
        securityApprover = makeAddr("securityApprover");

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

        vault = new CoreVault(
            IERC20Metadata(address(usdc)), "Vault", "V", deployer, address(feeCollector), address(globalConfig)
        );

        SelectorRegistry selectorRegistry = new SelectorRegistry();
        vault.setSelectorRegistry(address(selectorRegistry));

        queueModuleV1 = new EpochedQueueModule();
        queueModuleV2 = new EpochedQueueModule();
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

        // setEcosystem requires non-zero bufferManager/strategyRouter; these
        // recovery tests never exercise deposit/withdraw flows, so
        // placeholder addresses are sufficient.
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

        // The replacement group: same new module address for every selector
        // in EPOCH_QUEUE_GROUP (write + view), the realistic shape of a
        // recovery — one logical implementation owns the whole group.
        bytes4[] memory groupSelectors = gate.selectorsForGroup(EPOCH_QUEUE_GROUP);
        queueGroupV2Modules = new address[](groupSelectors.length);
        for (uint256 i; i < groupSelectors.length; ++i) {
            queueGroupV2Modules[i] = address(queueModuleV2);
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Constructor / immutable policy
    // ══════════════════════════════════════════════════════════════════════════

    function test_constructor_reverts_belowFourteenDayFloor() public {
        vm.expectRevert(RecoveryGate.DelayTooShort.selector);
        new RecoveryGate(address(vault), address(rootTimelock), securityApprover, 13 days, COOLDOWN);
    }

    function test_constructor_reverts_zeroAddresses() public {
        vm.expectRevert(RecoveryGate.ZeroAddress.selector);
        new RecoveryGate(address(0), address(rootTimelock), securityApprover, MIN_DELAY, COOLDOWN);
    }

    function test_recoveryGate_immutableOnceSet() public {
        vm.prank(address(rootTimelock));
        vm.expectRevert(CoreVault.RecoveryGateAlreadySet.selector);
        vault.setRecoveryGate(makeAddr("otherGate"));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Access control
    // ══════════════════════════════════════════════════════════════════════════

    function test_onlyRecoveryGate_canCall_recoverModuleGroup() public {
        vm.prank(address(rootTimelock));
        vm.expectRevert(CoreVault.NotRecoveryGate.selector);
        vault.recoverModuleGroup(EPOCH_QUEUE_GROUP, queueGroupV2Modules);
    }

    function test_onlyRootTimelock_canPropose() public {
        vm.prank(deployer);
        vm.expectRevert(RecoveryGate.NotRootTimelock.selector);
        gate.propose(EPOCH_QUEUE_GROUP, queueGroupV2Modules, "reason");
    }

    function test_onlySecurityApprover_canApprove() public {
        bytes32 digest = _proposeQueueRecovery();
        vm.prank(deployer);
        vm.expectRevert(RecoveryGate.NotSecurityApprover.selector);
        gate.approve(EPOCH_QUEUE_GROUP, digest);
    }

    function test_onlyVetoer_canVetoCancel() public {
        _proposeQueueRecovery();
        vm.prank(deployer);
        vm.expectRevert(RecoveryGate.NotVetoer.selector);
        gate.vetoCancel(EPOCH_QUEUE_GROUP);
    }

    function test_guardian_cannotCallAnythingOnRecoveryGate() public {
        vm.startPrank(guardian);
        vm.expectRevert(RecoveryGate.NotRootTimelock.selector);
        gate.propose(EPOCH_QUEUE_GROUP, queueGroupV2Modules, "reason");

        vm.expectRevert(RecoveryGate.NotSecurityApprover.selector);
        gate.approve(EPOCH_QUEUE_GROUP, bytes32(0));

        vm.expectRevert(RecoveryGate.NotVetoer.selector);
        gate.vetoCancel(EPOCH_QUEUE_GROUP);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Proposal validation
    // ══════════════════════════════════════════════════════════════════════════

    function test_propose_reverts_wrongSelectorCount() public {
        address[] memory tooFew = new address[](1);
        tooFew[0] = address(queueModuleV2);

        vm.prank(address(rootTimelock));
        vm.expectRevert(RecoveryGate.WrongSelectorCount.selector);
        gate.propose(EPOCH_QUEUE_GROUP, tooFew, "reason");
    }

    function test_propose_reverts_invalidGroup() public {
        vm.prank(address(rootTimelock));
        vm.expectRevert(RecoveryGate.InvalidGroup.selector);
        gate.propose(99, queueGroupV2Modules, "reason");
    }

    function test_propose_reverts_whilePendingProposalExists() public {
        _proposeQueueRecovery();

        vm.prank(address(rootTimelock));
        vm.expectRevert(RecoveryGate.PendingProposalExists.selector);
        gate.propose(EPOCH_QUEUE_GROUP, queueGroupV2Modules, "reason-2");
    }

    function test_approve_reverts_onDigestMismatch() public {
        _proposeQueueRecovery();

        vm.prank(securityApprover);
        vm.expectRevert(RecoveryGate.DigestMismatch.selector);
        gate.approve(EPOCH_QUEUE_GROUP, bytes32(uint256(1234)));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Execution timing
    // ══════════════════════════════════════════════════════════════════════════

    function test_execute_reverts_beforeDelayElapsed() public {
        bytes32 digest = _proposeQueueRecovery();
        vm.prank(securityApprover);
        gate.approve(EPOCH_QUEUE_GROUP, digest);

        vm.expectRevert(RecoveryGate.EtaNotReached.selector);
        gate.execute(EPOCH_QUEUE_GROUP);
    }

    function test_execute_reverts_withoutApproval() public {
        _proposeQueueRecovery();
        vm.warp(block.timestamp + MIN_DELAY + 1);

        vm.expectRevert(RecoveryGate.NotApproved.selector);
        gate.execute(EPOCH_QUEUE_GROUP);
    }

    function test_execute_reverts_afterExecutionWindowExpires() public {
        bytes32 digest = _proposeQueueRecovery();
        vm.prank(securityApprover);
        gate.approve(EPOCH_QUEUE_GROUP, digest);

        vm.warp(block.timestamp + MIN_DELAY + gate.EXECUTION_WINDOW() + 1);

        vm.expectRevert(RecoveryGate.EtaExpired.selector);
        gate.execute(EPOCH_QUEUE_GROUP);
    }

    function test_execute_reverts_onReplay() public {
        _executeQueueRecoveryHappyPath();

        vm.expectRevert(RecoveryGate.NoPendingProposal.selector);
        gate.execute(EPOCH_QUEUE_GROUP);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Veto
    // ══════════════════════════════════════════════════════════════════════════

    function test_vetoCancel_blocksExecution() public {
        bytes32 digest = _proposeQueueRecovery();
        vm.prank(securityApprover);
        gate.approve(EPOCH_QUEUE_GROUP, digest);

        vm.prank(vetoer);
        gate.vetoCancel(EPOCH_QUEUE_GROUP);

        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.expectRevert(RecoveryGate.NoPendingProposal.selector);
        gate.execute(EPOCH_QUEUE_GROUP);
    }

    function test_vetoCancel_readsVetoerLiveFromCoreVault() public {
        // Rotate the vault's vetoer, then confirm the OLD vetoer can no
        // longer veto and the NEW one can — proves RecoveryGate never
        // caches the address.
        address newVetoer = makeAddr("newVetoer");
        vm.prank(address(rootTimelock));
        IAdminModule(address(vault)).setVetoer(newVetoer);

        _proposeQueueRecovery();

        vm.prank(vetoer);
        vm.expectRevert(RecoveryGate.NotVetoer.selector);
        gate.vetoCancel(EPOCH_QUEUE_GROUP);

        vm.prank(newVetoer);
        gate.vetoCancel(EPOCH_QUEUE_GROUP);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Re-proposal invalidates prior approval
    // ══════════════════════════════════════════════════════════════════════════

    function test_repropose_invalidatesPriorApproval() public {
        bytes32 digest1 = _proposeQueueRecovery();
        vm.prank(securityApprover);
        gate.approve(EPOCH_QUEUE_GROUP, digest1);

        // Vetoing clears the slot so we can propose a different plan for the
        // same group without waiting out the (non-existent yet) cooldown.
        vm.prank(vetoer);
        gate.vetoCancel(EPOCH_QUEUE_GROUP);

        EpochedQueueModule queueModuleV3 = new EpochedQueueModule();
        address[] memory v3Modules = new address[](queueGroupV2Modules.length);
        for (uint256 i; i < v3Modules.length; ++i) v3Modules[i] = address(queueModuleV3);

        vm.prank(address(rootTimelock));
        gate.propose(EPOCH_QUEUE_GROUP, v3Modules, "reason-3");

        vm.warp(block.timestamp + MIN_DELAY + 1);
        // Never approved under the NEW digest -> must still revert.
        vm.expectRevert(RecoveryGate.NotApproved.selector);
        gate.execute(EPOCH_QUEUE_GROUP);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Concurrent proposals across different groups don't interfere
    // ══════════════════════════════════════════════════════════════════════════

    function test_concurrentProposals_differentGroups_doNotInterfere() public {
        _proposeQueueRecovery();

        ERC4626Module erc4626V2 = new ERC4626Module();
        bytes4[] memory erc4626Selectors = gate.selectorsForGroup(ERC4626_GROUP);
        address[] memory erc4626Modules = new address[](erc4626Selectors.length);
        for (uint256 i; i < erc4626Modules.length; ++i) erc4626Modules[i] = address(erc4626V2);

        vm.prank(address(rootTimelock));
        gate.propose(ERC4626_GROUP, erc4626Modules, "erc4626-reason");

        (bytes32 erc4626Digest,,, bool exists) = gate.pendingProposal(ERC4626_GROUP);
        assertTrue(exists);

        vm.prank(securityApprover);
        gate.approve(ERC4626_GROUP, erc4626Digest);

        vm.warp(block.timestamp + MIN_DELAY + 1);
        gate.execute(ERC4626_GROUP);

        // The EPOCH_QUEUE_GROUP proposal is untouched and still pending,
        // unapproved.
        (, , bool queueApproved, bool queueExists) = gate.pendingProposal(EPOCH_QUEUE_GROUP);
        assertTrue(queueExists, "queue group proposal untouched by the ERC4626 group's execution");
        assertFalse(queueApproved);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Cooldown
    // ══════════════════════════════════════════════════════════════════════════

    function test_cooldown_blocksImmediateReRecoveryOfSameGroup() public {
        _executeQueueRecoveryHappyPath();

        EpochedQueueModule queueModuleV3 = new EpochedQueueModule();
        address[] memory v3Modules = new address[](queueGroupV2Modules.length);
        for (uint256 i; i < v3Modules.length; ++i) v3Modules[i] = address(queueModuleV3);

        vm.prank(address(rootTimelock));
        vm.expectRevert(RecoveryGate.CooldownActive.selector);
        gate.propose(EPOCH_QUEUE_GROUP, v3Modules, "too-soon");
    }

    function test_cooldown_clearsAfterElapsing() public {
        _executeQueueRecoveryHappyPath();

        vm.warp(block.timestamp + COOLDOWN + 1);

        EpochedQueueModule queueModuleV3 = new EpochedQueueModule();
        address[] memory v3Modules = new address[](queueGroupV2Modules.length);
        for (uint256 i; i < v3Modules.length; ++i) v3Modules[i] = address(queueModuleV3);

        vm.prank(address(rootTimelock));
        gate.propose(EPOCH_QUEUE_GROUP, v3Modules, "cooldown-elapsed");
        (, , , bool exists) = gate.pendingProposal(EPOCH_QUEUE_GROUP);
        assertTrue(exists);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Happy path — end to end, and the structural role-relaxation guarantee
    // ══════════════════════════════════════════════════════════════════════════

    function test_happyPath_recoversEntireGroupAtomically() public {
        bytes4[] memory selectors = gate.selectorsForGroup(EPOCH_QUEUE_GROUP);

        // Capture every selector's role before recovery.
        uint8[] memory rolesBefore = new uint8[](selectors.length);
        for (uint256 i; i < selectors.length; ++i) {
            rolesBefore[i] = vault.roleOf(selectors[i]);
            assertEq(vault.moduleOf(selectors[i]), address(queueModuleV1), "starts on V1");
        }

        _executeQueueRecoveryHappyPath();

        for (uint256 i; i < selectors.length; ++i) {
            assertEq(vault.moduleOf(selectors[i]), address(queueModuleV2), "every selector moved to V2");
            assertEq(vault.roleOf(selectors[i]), rolesBefore[i], "role unchanged by recovery (review section 11)");
        }
    }

    function test_happyPath_doesNotTouchOtherGroups() public {
        address erc4626ModuleBefore = vault.moduleOf(bytes4(keccak256("deposit(uint256,address)")));

        _executeQueueRecoveryHappyPath();

        assertEq(
            vault.moduleOf(bytes4(keccak256("deposit(uint256,address)"))),
            erc4626ModuleBefore,
            "ERC4626_GROUP untouched by an EPOCH_QUEUE_GROUP recovery"
        );
    }

    function test_setModule_stillPermanentlyDisabled_afterFreeze() public {
        vm.prank(address(rootTimelock));
        vm.expectRevert(CoreVault.RoutingFrozen.selector);
        vault.setModule(SelectorLib.getQueueModuleSelectors()[0], address(queueModuleV2), 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Security approver rotation
    // ══════════════════════════════════════════════════════════════════════════

    function test_approverRotation_happyPath() public {
        address newApprover = makeAddr("newApprover");

        vm.prank(address(rootTimelock));
        gate.proposeApproverChange(newApprover);

        vm.warp(block.timestamp + MIN_DELAY + 1);
        gate.executeApproverChange();

        assertEq(gate.securityApprover(), newApprover);
    }

    function test_approverRotation_vetoable() public {
        address newApprover = makeAddr("newApprover");

        vm.prank(address(rootTimelock));
        gate.proposeApproverChange(newApprover);

        vm.prank(vetoer);
        gate.vetoApproverChange();

        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.expectRevert(RecoveryGate.NoPendingProposal.selector);
        gate.executeApproverChange();

        assertEq(gate.securityApprover(), securityApprover, "unchanged after veto");
    }

    function test_approverRotation_onlyRootTimelockCanPropose() public {
        vm.prank(deployer);
        vm.expectRevert(RecoveryGate.NotRootTimelock.selector);
        gate.proposeApproverChange(makeAddr("newApprover"));
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _proposeQueueRecovery() internal returns (bytes32 digest) {
        vm.prank(address(rootTimelock));
        gate.propose(EPOCH_QUEUE_GROUP, queueGroupV2Modules, "queue-incident-001");
        (digest,,,) = gate.pendingProposal(EPOCH_QUEUE_GROUP);
    }

    function _executeQueueRecoveryHappyPath() internal {
        bytes32 digest = _proposeQueueRecovery();
        vm.prank(securityApprover);
        gate.approve(EPOCH_QUEUE_GROUP, digest);

        vm.warp(block.timestamp + MIN_DELAY + 1);
        gate.execute(EPOCH_QUEUE_GROUP);
    }
}
