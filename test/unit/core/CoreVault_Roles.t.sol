// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { CoreVault } from "../../../src/core/CoreVault.sol";
import { MockUSDC } from "../../helpers/MockUSDC.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { QueueModule } from "src/core/modules/QueueModule.sol";
import { AdminModule } from "src/core/modules/AdminModule.sol";
import { IQueueModule } from "src/interfaces/IQueueModule.sol";
import { IAdminModule } from "src/interfaces/IAdminModule.sol";
import { SelectorLib } from "src/core/libraries/SelectorLib.sol";
import { ModuleSetter } from "test/helpers/ModuleSetter.sol";

/**
 * @title CoreVault_Roles Test Suite
 * @notice Comprehensive test coverage for Roles mixin (src/core/mixins/Roles.sol)
 * @dev Tests initialization, access control, owner management, and role freezing
 */
contract CoreVaultRolesTest is Test {
    CoreVault public vault;
    MockUSDC public usdc;
    QueueModule public queueModule;
    AdminModule public adminModule;

    address public owner = address(0xA11CE);
    address public guardian = address(0xB0B);
    address public treasury = address(0xFEE);
    address public newOwner = address(0x9999);
    address public unauthorized = address(0xDEAD);

    function setUp() public {
        usdc = new MockUSDC();

        // Deploy MockParamsProvider
        MockParamsProvider params = new MockParamsProvider();

        // Deploy vault with 6-param constructor
        vm.prank(owner);
        vault = new CoreVault(
            IERC20Metadata(address(usdc)), "VaultUSDC", "vUSDC", owner, treasury, address(params)
        );

        // Deploy and configure modules
        queueModule = new QueueModule();
        adminModule = new AdminModule();

        vm.startPrank(owner);
        bytes4[] memory queueSels = SelectorLib.getQueueModuleSelectors();
        ModuleSetter.setModulesSame(
            address(vault), queueSels, address(queueModule), SelectorLib.ROLE_PUBLIC
        );

        bytes4[] memory adminOwnerSels = SelectorLib.getAdminModuleOwnerSelectors();
        ModuleSetter.setModulesSame(
            address(vault), adminOwnerSels, address(adminModule), SelectorLib.ROLE_OWNER
        );

        bytes4[] memory adminViewSels = SelectorLib.getAdminModuleViewSelectors();
        ModuleSetter.setModulesSame(
            address(vault), adminViewSels, address(adminModule), SelectorLib.ROLE_PUBLIC
        );
        vm.stopPrank();
    }

    /// @notice Test 1: Verify initialization sets owner correctly
    function test_roles_initialization_sets_owner() public view {
        // After deployment, owner should be set correctly
        assertEq(vault.owner(), owner, "Owner should be initialized correctly");
    }

    /// @notice Test 2: Verify onlyOwner modifier reverts for non-owner
    function test_roles_onlyOwner_reverts_for_non_owner() public {
        // Try to call beginOwnerTransfer as unauthorized user
        vm.prank(unauthorized);
        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.beginOwnerTransfer(newOwner);
    }

    /// @notice Test 3: Verify 2-step ownership transfer succeeds when called by owner
    function test_roles_ownershipTransfer_by_owner_succeeds() public {
        // Owner initiates transfer
        vm.prank(owner);
        vault.beginOwnerTransfer(newOwner);

        // Verify pendingOwner is set but owner unchanged
        assertEq(vault.owner(), owner, "Owner should not change yet");
        assertEq(vault.pendingOwner(), newOwner, "Pending owner should be set");

        // New owner accepts
        vm.prank(newOwner);
        vault.acceptOwnerTransfer();

        // Verify owner has been updated
        assertEq(vault.owner(), newOwner, "Owner should be updated after accept");
        assertEq(vault.pendingOwner(), address(0), "Pending owner should be cleared");

        // Verify new owner has access
        address anotherAddress = address(0x8888);
        vm.prank(newOwner);
        vault.beginOwnerTransfer(anotherAddress);
        vm.prank(anotherAddress);
        vault.acceptOwnerTransfer();
        assertEq(vault.owner(), anotherAddress, "New owner should have access");
    }

    /// @notice Test 4: Verify beginOwnerTransfer reverts when called by non-owner
    function test_roles_beginOwnerTransfer_by_non_owner_reverts() public {
        // Guardian (not owner) tries to begin transfer
        vm.prank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.beginOwnerTransfer(newOwner);

        // Random address tries to begin transfer
        vm.prank(unauthorized);
        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.beginOwnerTransfer(newOwner);

        // Verify owner unchanged
        assertEq(vault.owner(), owner, "Owner should remain unchanged");
    }

    /// @notice Test 5: Verify acceptOwnerTransfer reverts for wrong address
    function test_roles_acceptOwnerTransfer_wrong_address_reverts() public {
        // Owner initiates transfer to newOwner
        vm.prank(owner);
        vault.beginOwnerTransfer(newOwner);

        // Random address tries to accept
        vm.prank(unauthorized);
        vm.expectRevert(CoreVault.NoTransferPending.selector);
        vault.acceptOwnerTransfer();

        // Original owner cannot accept
        vm.prank(owner);
        vm.expectRevert(CoreVault.NoTransferPending.selector);
        vault.acceptOwnerTransfer();

        // Verify owner unchanged
        assertEq(vault.owner(), owner, "Owner should remain unchanged");
    }

    /// @notice Test 6: Fuzz test - random addresses cannot initiate transfer
    function testFuzz_roles_unauthorized_cannot_begin_transfer(address random) public {
        vm.assume(random != owner); // Exclude current owner
        vm.assume(random != address(0)); // Exclude zero for cleaner test

        vm.prank(random);
        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.beginOwnerTransfer(random);

        // Verify owner unchanged
        assertEq(vault.owner(), owner, "Owner should remain owner");
    }

    /// @notice Test 7: Fuzz test - owner can transfer to any address via 2-step
    function testFuzz_roles_owner_can_transfer_to_any_address(address randomOwner) public {
        vm.assume(randomOwner != address(0)); // Cannot transfer to zero address
        vm.assume(randomOwner != owner); // New owner must be different

        vm.prank(owner);
        vault.beginOwnerTransfer(randomOwner);

        vm.prank(randomOwner);
        vault.acceptOwnerTransfer();

        assertEq(vault.owner(), randomOwner, "Owner should be updated to random address");
    }
}
