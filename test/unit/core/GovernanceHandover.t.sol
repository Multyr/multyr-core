// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Test} from "forge-std/Test.sol";
import {FeeCollector} from "../../../src/core/modules/FeeCollector.sol";
import {VaultFactory} from "../../../src/factory/VaultFactory.sol";
import {RecoveryGate} from "../../../src/governance/RecoveryGate.sol";

contract GovernanceHandoverTest is Test {
    address constant GOVERNOR = address(0xBEEF);
    address constant OTHER = address(0xBAD);
    FeeCollector fees;
    VaultFactory factory;
    RecoveryGate gate;
    function setUp() public {
        fees = new FeeCollector(address(this), GOVERNOR, GOVERNOR, GOVERNOR, 7000, 100, 3000);
        factory = new VaultFactory();
        gate = new RecoveryGate(address(0xCAFE), address(this), address(0xABCD), 21 days, 30 days);
    }
    function test_feeGovernorRequiresAcceptanceAndRemovesPreviousAuthority() public {
        fees.beginGovernorTransfer(GOVERNOR);
        assertEq(fees.governor(), address(this));
        vm.prank(OTHER);
        vm.expectRevert("FeeCollector: not pending governor");
        fees.acceptGovernorTransfer();
        vm.prank(GOVERNOR); fees.acceptGovernorTransfer();
        assertEq(fees.governor(), GOVERNOR);
        assertEq(fees.pendingGovernor(), address(0));
        vm.expectRevert("FeeCollector: not governor"); fees.pause();
        vm.prank(GOVERNOR); fees.pause();
        assertTrue(fees.paused());
    }
    function test_factoryRequiresAcceptanceAndRemovesPreviousAuthority() public {
        factory.transferOwnership(GOVERNOR);
        assertEq(factory.owner(), address(this));
        vm.prank(OTHER); vm.expectRevert(VaultFactory.NotPendingOwner.selector); factory.acceptOwnership();
        vm.prank(GOVERNOR); factory.acceptOwnership();
        assertEq(factory.owner(), GOVERNOR);
        assertEq(factory.pendingOwner(), address(0));
        vm.expectRevert(VaultFactory.NotOwner.selector); factory.deprecateVault(address(0xCAFE));
        vm.prank(GOVERNOR); factory.deprecateVault(address(0xCAFE));
    }
    function test_rootTransferCancelsPredecessorProposalsAndPreservesPolicy() public {
        vm.mockCall(address(0xCAFE), abi.encodeWithSignature("moduleOf(bytes4)"), abi.encode(address(0)));
        address[] memory modules = new address[](gate.selectorsForGroup(1).length);
        gate.propose(1, modules, bytes32("old proposal"));
        gate.proposeApproverChange(OTHER);
        gate.beginRootTimelockTransfer(GOVERNOR);
        assertEq(gate.rootTimelock(), address(this));
        vm.prank(OTHER); vm.expectRevert(RecoveryGate.NotPendingRootTimelock.selector); gate.acceptRootTimelockTransfer();
        vm.prank(GOVERNOR); gate.acceptRootTimelockTransfer();
        assertEq(gate.rootTimelock(), GOVERNOR);
        assertEq(gate.pendingRootTimelock(), address(0));
        (,,,bool exists) = gate.pendingProposal(1); assertFalse(exists);
        (,,bool approverExists) = gate.pendingApprover(); assertFalse(approverExists);
        assertEq(gate.minDelay(), 21 days); assertEq(gate.cooldown(), 30 days);
        assertEq(gate.securityApprover(), address(0xABCD));
        vm.expectRevert(RecoveryGate.NotRootTimelock.selector); gate.proposeApproverChange(OTHER);
        vm.prank(GOVERNOR); gate.proposeApproverChange(OTHER);
    }
    function test_onlyCurrentControllerCanNominate() public {
        vm.startPrank(OTHER);
        vm.expectRevert("FeeCollector: not governor"); fees.beginGovernorTransfer(GOVERNOR);
        vm.expectRevert(VaultFactory.NotOwner.selector); factory.transferOwnership(GOVERNOR);
        vm.expectRevert(RecoveryGate.NotRootTimelock.selector); gate.beginRootTimelockTransfer(GOVERNOR);
        vm.stopPrank();
    }
    function test_zeroSuccessorRejected() public {
        vm.expectRevert("FeeCollector: governor=0"); fees.beginGovernorTransfer(address(0));
        vm.expectRevert(VaultFactory.ZeroAddress.selector); factory.transferOwnership(address(0));
        vm.expectRevert(RecoveryGate.ZeroAddress.selector); gate.beginRootTimelockTransfer(address(0));
    }
    function test_replacedNomineeCannotAccept() public {
        fees.beginGovernorTransfer(OTHER); fees.beginGovernorTransfer(GOVERNOR);
        factory.transferOwnership(OTHER); factory.transferOwnership(GOVERNOR);
        gate.beginRootTimelockTransfer(OTHER); gate.beginRootTimelockTransfer(GOVERNOR);
        vm.startPrank(OTHER);
        vm.expectRevert("FeeCollector: not pending governor"); fees.acceptGovernorTransfer();
        vm.expectRevert(VaultFactory.NotPendingOwner.selector); factory.acceptOwnership();
        vm.expectRevert(RecoveryGate.NotPendingRootTimelock.selector); gate.acceptRootTimelockTransfer();
        vm.stopPrank();
    }
}
