// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// INCIDENT SIMULATION — CoreVault shell defect
//
// Review §36: "Migration Remains Mandatory for Shell Defects". Emergency
// Module Recovery must NOT be capable of repairing a defect in CoreVault's
// direct functions, the fallback dispatcher, core storage, the recovery
// entry point itself, or a critical immutable governance binding — the
// correct (and only) remedy for those is migration to a new vault.
//
// This is a NEGATIVE test suite: every scenario below is an attempt to reach
// shell-level state through the recovery path, and every one must fail —
// not because of a policy check that could theoretically be misconfigured,
// but because there is structurally no path from RecoveryGate/
// recoverModuleGroup to any of this state at all.
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreVault } from "../../src/core/CoreVault.sol";
import { EpochedQueueModule } from "../../src/core/modules/EpochedQueueModule.sol";
import { AdminModule } from "../../src/core/modules/AdminModule.sol";
import { FeeCollector } from "../../src/core/modules/FeeCollector.sol";
import { GlobalConfig } from "../../src/core/config/GlobalConfig.sol";
import { SelectorRegistry } from "../../src/core/libraries/SelectorRegistry.sol";
import { SelectorLib } from "../../src/core/libraries/SelectorLib.sol";
import { RecoveryGate } from "../../src/governance/RecoveryGate.sol";
import { IAdminModule } from "../../src/interfaces/IAdminModule.sol";
import { IncentivesTimelock } from "../../src/governance/IncentivesTimelock.sol";
import { ERC20Mock } from "../../src/mocks/ERC20Mock.sol";

contract CoreVaultShellDefect_Unreachable is Test {
    uint256 constant TIMELOCK_DELAY = 2 days;
    uint64 constant MIN_DELAY = 14 days;
    uint64 constant COOLDOWN = 30 days;

    address internal deployer;
    address internal guardian;
    address internal vetoer;
    address internal treasury;
    address internal securityApprover;
    address internal attacker;

    ERC20Mock internal usdc;
    IncentivesTimelock internal rootTimelock;
    CoreVault internal vault;
    RecoveryGate internal gate;

    function setUp() public {
        deployer = makeAddr("deployer");
        guardian = makeAddr("guardian");
        vetoer = makeAddr("vetoer");
        treasury = makeAddr("treasury");
        securityApprover = makeAddr("securityApprover");
        attacker = makeAddr("attacker");

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

        AdminModule am = new AdminModule();
        bytes4[] memory s = SelectorLib.getAdminModuleOwnerSelectors();
        for (uint256 i; i < s.length; ++i) vault.setModule(s[i], address(am), SelectorLib.ROLE_OWNER);

        gate = new RecoveryGate(address(vault), address(rootTimelock), securityApprover, MIN_DELAY, COOLDOWN);
        vault.setRecoveryGate(address(gate));
        vault.freezeRouting();

        vault.beginOwnerTransfer(address(rootTimelock));
        vm.stopPrank();

        vm.prank(address(rootTimelock));
        vault.acceptOwnerTransfer();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // No group ID reaches AdminModule's governance/sealing surface
    // ══════════════════════════════════════════════════════════════════════════

    function test_noRecoveryGroup_coversAnyAdminModuleOwnerSelector() public view {
        bytes4[] memory adminSelectors = SelectorLib.getAdminModuleOwnerSelectors();

        for (uint8 groupId; groupId < gate.GROUP_COUNT(); ++groupId) {
            bytes4[] memory groupSelectors = gate.selectorsForGroup(groupId);
            for (uint256 i; i < adminSelectors.length; ++i) {
                for (uint256 j; j < groupSelectors.length; ++j) {
                    assertTrue(
                        adminSelectors[i] != groupSelectors[j],
                        "no recoverable group may contain an AdminModule owner selector"
                    );
                }
            }
        }
    }

    /// @dev NOTE ON SCOPE: this only re-confirms, end-to-end for one group
    ///      instead of by selector-set comparison, that recoverModuleGroup()
    ///      never WRITES to an AdminModule selector's moduleOf entry — the
    ///      same fact test_noRecoveryGroup_coversAnyAdminModuleOwnerSelector
    ///      above already establishes by construction. It is NOT evidence
    ///      that AdminModule's governance/sealing surface is unreachable
    ///      through a *malicious recovered module's code* — a module
    ///      installed via recoverModuleGroup runs via delegatecall and
    ///      therefore has full read/write access to all of CoreStorage,
    ///      including roleOf and owner, regardless of which selectors it was
    ///      recovered under. Whether that constitutes a live "role relaxation"
    ///      gap is tracked separately (see docs/recovery.md and the caveat in
    ///      RecoveryGate.sol's own NatSpec: "restricting recovery to existing
    ///      selectors ... does not mathematically prove a replacement module
    ///      only repairs a bug"). Do not cite this test as disproving that.
    function test_adminModuleRouting_survivesRecoveryOfEveryOtherGroup() public {
        bytes4[] memory adminSelectors = SelectorLib.getAdminModuleOwnerSelectors();
        address adminModuleBefore = vault.moduleOf(adminSelectors[0]);

        // Recover EPOCH_QUEUE_GROUP (unwired in this minimal fixture —
        // recovering an unwired group is still valid: it just sets moduleOf
        // from address(0) to the new address, same as normal) and confirm
        // AdminModule's *routing table entry* is untouched. The replacement
        // module here (EpochedQueueModule) is never actually invoked through
        // the recovered selectors in this test, so this says nothing about
        // what a malicious module's code could do once installed.
        EpochedQueueModule qm = new EpochedQueueModule();
        bytes4[] memory queueSelectors = gate.selectorsForGroup(0);
        address[] memory queueModules = new address[](queueSelectors.length);
        for (uint256 i; i < queueModules.length; ++i) queueModules[i] = address(qm);

        vm.prank(address(rootTimelock));
        gate.propose(0, queueModules, "shell-defect-sim");
        (bytes32 digest,,,) = gate.pendingProposal(0);
        vm.prank(securityApprover);
        gate.approve(0, digest);
        vm.warp(block.timestamp + MIN_DELAY + 1);
        gate.execute(0);

        assertEq(
            vault.moduleOf(adminSelectors[0]),
            adminModuleBefore,
            "AdminModule routing untouched by recovering an unrelated group"
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    // recoverModuleGroup rejects any group ID outside the four defined ones —
    // there is no "escape hatch" group that reaches CoreVault's own functions.
    // ══════════════════════════════════════════════════════════════════════════

    function test_recoverModuleGroup_rejectsOutOfRangeGroupId() public {
        address[] memory newModules = new address[](1);
        newModules[0] = makeAddr("maliciousModule");

        vm.prank(address(gate));
        vm.expectRevert(CoreVault.InvalidRecoveryGroup.selector);
        vault.recoverModuleGroup(4, newModules);

        vm.prank(address(gate));
        vm.expectRevert(CoreVault.InvalidRecoveryGroup.selector);
        vault.recoverModuleGroup(255, newModules);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Direct CoreVault functions are not moduleOf-routed at all — recovery
    // has no selector to target them with, regardless of group ID.
    // ══════════════════════════════════════════════════════════════════════════

    function test_directCoreVaultFunctions_areNeverModuleOfRouted() public view {
        // setModule, freezeRouting, pauseAll, setRecoveryGate, and
        // setSelectorRegistry are defined directly on CoreVault, dispatched
        // by explicit function selectors in the contract itself, not via the
        // fallback()/moduleOf() mechanism recoverModuleGroup writes to.
        // Confirm none of their selectors appear in any recoverable group.
        bytes4[] memory shellSelectors = new bytes4[](5);
        shellSelectors[0] = CoreVault.setModule.selector;
        shellSelectors[1] = CoreVault.freezeRouting.selector;
        shellSelectors[2] = CoreVault.pauseAll.selector;
        shellSelectors[3] = CoreVault.setRecoveryGate.selector;
        shellSelectors[4] = CoreVault.setSelectorRegistry.selector;

        for (uint8 groupId; groupId < gate.GROUP_COUNT(); ++groupId) {
            bytes4[] memory groupSelectors = gate.selectorsForGroup(groupId);
            for (uint256 i; i < shellSelectors.length; ++i) {
                for (uint256 j; j < groupSelectors.length; ++j) {
                    assertTrue(
                        shellSelectors[i] != groupSelectors[j],
                        "no recoverable group may contain a direct CoreVault shell function"
                    );
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // The recovery policy itself (RecoveryGate's own immutable fields) cannot
    // be reached through recovery — there is no group that recovers the
    // recovery mechanism.
    // ══════════════════════════════════════════════════════════════════════════

    function test_recoveryGate_hasNoSelfModificationPath() public {
        // RecoveryGate has no setter for vault/rootTimelock/minDelay/cooldown
        // at all (immutable), and setRecoveryGate() on CoreVault is set-once.
        // An attacker in control of ROOT_TIMELOCK cannot even attempt to
        // rewire recovery to a hostile gate post-seal.
        vm.prank(address(rootTimelock));
        vm.expectRevert(CoreVault.RecoveryGateAlreadySet.selector);
        vault.setRecoveryGate(attacker);
    }
}
