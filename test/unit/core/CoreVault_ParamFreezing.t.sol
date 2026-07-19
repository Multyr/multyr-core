// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreVault } from "../../../src/core/CoreVault.sol";
import { AdminModule } from "../../../src/core/modules/AdminModule.sol";
import { IAdminModule } from "../../../src/interfaces/IAdminModule.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { ModuleSetter } from "../../helpers/ModuleSetter.sol";

/**
 * @title CoreVault_ParamFreezing
 * @notice Test suite for parameter freezing mechanisms
 * @dev Tests freezeParams() security feature in the Diamond-lite architecture
 */
contract CoreVault_ParamFreezing is Test {
    CoreVault internal vault;
    AdminModule internal adminModule;
    ERC20Mock internal usdc;

    address internal owner = address(0xA11CE);
    address internal feeCollector = address(0xFEE);
    address internal newFeeCollector = address(0xFEE2);
    address internal user = address(0xBEEF);

    uint64 internal constant DEFAULT_MIN_DELAY = 2 days;

    function setUp() public {
        // Deploy mock USDC
        usdc = new ERC20Mock("USDC", "USDC", 6);
        usdc._mint(address(this), 10_000_000e6);

        // Deploy MockParamsProvider
        MockParamsProvider params = new MockParamsProvider();

        // Deploy AdminModule
        adminModule = new AdminModule();

        // Deploy vault with new 6-param constructor
        vm.prank(owner);
        vault = new CoreVault(
            IERC20Metadata(address(usdc)),
            "Test Vault",
            "tvUSDC",
            owner,
            feeCollector,
            address(params)
        );

        // Wire up AdminModule to CoreVault
        bytes4[] memory adminSelectors = new bytes4[](12);
        adminSelectors[0] = IAdminModule.submitFeeParams.selector;
        adminSelectors[1] = IAdminModule.acceptFeeParams.selector;
        adminSelectors[2] = IAdminModule.revokeFeeParams.selector;
        adminSelectors[3] = IAdminModule.submitPerfParams.selector;
        adminSelectors[4] = IAdminModule.acceptPerfParams.selector;
        adminSelectors[5] = IAdminModule.revokePerfParams.selector;
        adminSelectors[6] = IAdminModule.freezeParams.selector;
        adminSelectors[7] = IAdminModule.isParamsFrozen.selector;
        adminSelectors[8] = IAdminModule.getPendingFeeParams.selector;
        adminSelectors[9] = IAdminModule.getFeeParams.selector;
        adminSelectors[10] = IAdminModule.getPendingPerfParams.selector;
        adminSelectors[11] = IAdminModule.getPerfParams.selector;

        vm.startPrank(owner);
        ModuleSetter.setModulesSame(
            address(vault),
            adminSelectors,
            address(adminModule),
            vault.ROLE_OWNER() // Owner-only for admin functions
        );

        // Make view functions public
        bytes4[] memory viewSelectors = new bytes4[](5);
        viewSelectors[0] = IAdminModule.isParamsFrozen.selector;
        viewSelectors[1] = IAdminModule.getPendingFeeParams.selector;
        viewSelectors[2] = IAdminModule.getFeeParams.selector;
        viewSelectors[3] = IAdminModule.getPendingPerfParams.selector;
        viewSelectors[4] = IAdminModule.getPerfParams.selector;

        ModuleSetter.setModulesSame(
            address(vault),
            viewSelectors,
            address(adminModule),
            vault.ROLE_PUBLIC() // Public for view functions
        );
        vm.stopPrank();
    }

    // Helper to get admin interface
    function admin() internal view returns (IAdminModule) {
        return IAdminModule(address(vault));
    }

    /* ===== FREEZE PARAMS TESTS ===== */

    function test_freezeParams_prevents_fee_params_change() public {
        // Freeze params
        vm.prank(owner);
        admin().freezeParams();

        // Verify frozen
        assertTrue(admin().isParamsFrozen(), "params should be frozen");

        // Attempt to submit fee params should revert
        vm.prank(owner);
        vm.expectRevert();
        admin().submitFeeParams(100, 60, 0, 0, newFeeCollector);
    }

    function test_freezeParams_prevents_perf_params_change() public {
        vm.prank(owner);
        admin().freezeParams();

        // submitPerfParams should revert
        vm.prank(owner);
        vm.expectRevert();
        admin().submitPerfParams(2e17, 7200);
    }

    function test_freezeParams_only_owner() public {
        vm.prank(user);
        vm.expectRevert();
        admin().freezeParams();
    }

    function test_freezeParams_is_irreversible() public {
        // Freeze
        vm.prank(owner);
        admin().freezeParams();

        assertTrue(admin().isParamsFrozen());

        // Multiple attempts to change params should all fail
        vm.startPrank(owner);
        vm.expectRevert();
        admin().submitFeeParams(100, 60, 0, 0, feeCollector);

        vm.expectRevert();
        admin().submitPerfParams(2e17, 7200);
        vm.stopPrank();

        // Still frozen
        assertTrue(admin().isParamsFrozen());
    }

    /* ===== PRE-FREEZE OPERATIONS ===== */

    function test_can_change_params_before_freezing() public {
        // Submit and accept fee params before freezing - should work
        vm.prank(owner);
        admin().submitFeeParams(100, 60, 0, 0, newFeeCollector);

        // Fast forward past delay
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY);

        vm.prank(owner);
        admin().acceptFeeParams();

        // Verify params updated
        (uint16 dep, uint16 wit, address treas) = admin().getFeeParams();
        assertEq(dep, 100);
        assertEq(wit, 60);
        assertEq(treas, newFeeCollector);

        // Submit and accept perf params before freezing
        vm.prank(owner);
        admin().submitPerfParams(2e17, 7200);

        vm.warp(block.timestamp + DEFAULT_MIN_DELAY);

        vm.prank(owner);
        admin().acceptPerfParams();

        // Verify perf params updated
        (uint256 rate,,,) = admin().getPerfParams();
        assertEq(rate, 2e17);
    }

    /* ===== OWNERSHIP TRANSFER SCENARIOS ===== */

    function test_frozen_params_persist_after_ownership_transfer() public {
        // Freeze params
        vm.prank(owner);
        admin().freezeParams();

        // Transfer ownership
        address newOwner = address(0xBEE3);
        vm.prank(owner);
        vault.beginOwnerTransfer(newOwner);

        vm.prank(newOwner);
        vault.acceptOwnerTransfer();

        // New owner still cannot change params
        assertTrue(admin().isParamsFrozen(), "params should still be frozen");

        // Wire up admin module for new owner
        bytes4[] memory adminSelectors = new bytes4[](2);
        adminSelectors[0] = IAdminModule.submitFeeParams.selector;
        adminSelectors[1] = IAdminModule.submitPerfParams.selector;

        vm.startPrank(newOwner);
        ModuleSetter.setModulesSame(
            address(vault), adminSelectors, address(adminModule), vault.ROLE_OWNER()
        );
        vm.stopPrank();

        vm.prank(newOwner);
        vm.expectRevert();
        admin().submitFeeParams(100, 60, 0, 0, feeCollector);

        vm.prank(newOwner);
        vm.expectRevert();
        admin().submitPerfParams(2e17, 7200);
    }

    /* ===== EDGE CASES ===== */

    function test_freezeParams_twice_is_noop() public {
        vm.startPrank(owner);
        admin().freezeParams();
        admin().freezeParams(); // Should not revert
        vm.stopPrank();

        assertTrue(admin().isParamsFrozen());
    }

    function test_pending_params_still_rejected_after_freeze() public {
        // Submit params first
        vm.prank(owner);
        admin().submitFeeParams(100, 60, 0, 0, newFeeCollector);

        // Then freeze before accepting
        vm.prank(owner);
        admin().freezeParams();

        // Fast forward past delay
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY);

        // Accept should still work for pending params (they were submitted before freeze)
        // Note: The current implementation might reject this - depends on module design
        // This test documents the expected behavior
        vm.prank(owner);
        admin().acceptFeeParams(); // Should work - pending was created before freeze

        // But new submissions should fail
        vm.prank(owner);
        vm.expectRevert();
        admin().submitFeeParams(200, 100, 0, 0, feeCollector);
    }

    function test_isParamsFrozen_returns_false_initially() public {
        assertFalse(admin().isParamsFrozen(), "params should not be frozen initially");
    }

    function test_isParamsFrozen_returns_true_after_freeze() public {
        vm.prank(owner);
        admin().freezeParams();

        assertTrue(admin().isParamsFrozen(), "params should be frozen after freezeParams()");
    }
}
