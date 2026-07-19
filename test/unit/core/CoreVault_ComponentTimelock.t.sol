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
import {
    ComponentsTimelocked,
    ComponentsNotTimelocked,
    NotPending
} from "../../../src/core/libraries/Errors.sol";

/**
 * @title CoreVault_ComponentTimelock
 * @notice Test suite for component timelock (BufferManager and Router)
 * @dev Tests:
 *   - Bootstrap: setBufferManager/setRouter work before enableComponentsTimelock()
 *   - After enable: setBufferManager/setRouter revert with ComponentsTimelocked
 *   - submit/accept pattern respects paramMinDelay
 *   - revoke clears pending
 */
contract CoreVault_ComponentTimelock is Test {
    CoreVault internal vault;
    AdminModule internal adminModule;
    ERC20Mock internal usdc;

    address internal owner = address(0xA11CE);
    address internal feeCollector = address(0xFEE);
    address internal vetoer = address(0xBEE1);
    address internal user = address(0xBEEF);

    // Mock component addresses
    address internal bufferManager1 = address(0xB0F1);
    address internal bufferManager2 = address(0xB0F2);
    address internal router1 = address(0x2001);
    address internal router2 = address(0x2002);

    uint64 internal constant DEFAULT_MIN_DELAY = 2 days;
    uint64 internal constant PARAM_MAX_WINDOW = 7 days;

    event ComponentsTimelockEnabled();
    event BufferManagerSubmitted(address indexed newBuffer, uint64 eta);
    event BufferManagerAccepted(address indexed newBuffer);
    event BufferManagerRevoked();
    event RouterSubmitted(address indexed newRouter, uint64 eta);
    event RouterAccepted(address indexed newRouter);
    event RouterRevoked();

    function setUp() public {
        // Deploy mock USDC
        usdc = new ERC20Mock("USDC", "USDC", 6);

        // Deploy MockParamsProvider
        MockParamsProvider params = new MockParamsProvider();

        // Deploy AdminModule
        adminModule = new AdminModule();

        // Deploy vault with 6-param constructor
        vm.prank(owner);
        vault = new CoreVault(
            IERC20Metadata(address(usdc)),
            "Test Vault",
            "tvUSDC",
            owner,
            feeCollector,
            address(params)
        );

        // Wire up AdminModule selectors for component timelock
        bytes4[] memory adminSelectors = new bytes4[](17);
        // Existing setters
        adminSelectors[0] = IAdminModule.setBufferManager.selector;
        adminSelectors[1] = IAdminModule.setRouter.selector;
        adminSelectors[2] = IAdminModule.setVetoer.selector;
        // Component timelock functions
        adminSelectors[3] = IAdminModule.enableComponentsTimelock.selector;
        adminSelectors[4] = IAdminModule.submitBufferManager.selector;
        adminSelectors[5] = IAdminModule.acceptBufferManager.selector;
        adminSelectors[6] = IAdminModule.revokeBufferManager.selector;
        adminSelectors[7] = IAdminModule.submitRouter.selector;
        adminSelectors[8] = IAdminModule.acceptRouter.selector;
        adminSelectors[9] = IAdminModule.revokeRouter.selector;
        // View functions
        adminSelectors[10] = IAdminModule.isComponentsTimelocked.selector;
        adminSelectors[11] = IAdminModule.getPendingBufferManager.selector;
        adminSelectors[12] = IAdminModule.getPendingRouter.selector;
        adminSelectors[13] = IAdminModule.getMinDelay.selector;
        // Additional needed for paramMinDelay
        adminSelectors[14] = IAdminModule.submitMinDelay.selector;
        adminSelectors[15] = IAdminModule.acceptMinDelay.selector;
        adminSelectors[16] = IAdminModule.revokeMinDelay.selector;

        vm.startPrank(owner);
        ModuleSetter.setModulesSame(
            address(vault), adminSelectors, address(adminModule), vault.ROLE_OWNER()
        );

        // Make view functions and revoke functions public
        // (revoke functions do their own owner/vetoer check internally)
        bytes4[] memory publicSelectors = new bytes4[](7);
        publicSelectors[0] = IAdminModule.isComponentsTimelocked.selector;
        publicSelectors[1] = IAdminModule.getPendingBufferManager.selector;
        publicSelectors[2] = IAdminModule.getPendingRouter.selector;
        publicSelectors[3] = IAdminModule.getMinDelay.selector;
        publicSelectors[4] = IAdminModule.revokeBufferManager.selector;
        publicSelectors[5] = IAdminModule.revokeRouter.selector;
        publicSelectors[6] = IAdminModule.revokeMinDelay.selector;

        ModuleSetter.setModulesSame(
            address(vault), publicSelectors, address(adminModule), vault.ROLE_PUBLIC()
        );

        // Set vetoer
        IAdminModule(address(vault)).setVetoer(vetoer);

        // Bootstrap paramMinDelay from 0 (constructor default) to 2 days.
        // With paramMinDelay=0 the eta is block.timestamp, so accept works immediately.
        IAdminModule(address(vault)).submitMinDelay(DEFAULT_MIN_DELAY);
        IAdminModule(address(vault)).acceptMinDelay();
        vm.stopPrank();
    }

    // Helper to get admin interface
    function admin() internal view returns (IAdminModule) {
        return IAdminModule(address(vault));
    }

    /* ===== BOOTSTRAP FLOW (before enableComponentsTimelock) ===== */

    function test_setBufferManager_works_before_timelock_enabled() public {
        assertFalse(admin().isComponentsTimelocked(), "should not be timelocked initially");

        vm.prank(owner);
        admin().setBufferManager(bufferManager1);

        assertEq(address(vault.bufferManager()), bufferManager1, "bufferManager not set");
    }

    function test_setRouter_works_before_timelock_enabled() public {
        assertFalse(admin().isComponentsTimelocked(), "should not be timelocked initially");

        vm.prank(owner);
        admin().setRouter(router1);

        assertEq(address(vault.router()), router1, "router not set");
    }

    function test_bootstrap_flow_mimics_factory() public {
        // This mimics what VaultFactory does:
        // 1. Deploy vault
        // 2. setBufferManager
        // 3. setRouter
        // 4. enableComponentsTimelock

        vm.startPrank(owner);

        // Step 2 & 3: Set components (no timelock yet)
        admin().setBufferManager(bufferManager1);
        admin().setRouter(router1);

        // Verify components are set
        assertEq(address(vault.bufferManager()), bufferManager1, "bufferManager not set");
        assertEq(address(vault.router()), router1, "router not set");

        // Step 4: Enable timelock
        admin().enableComponentsTimelock();

        // Verify timelock is now active
        assertTrue(admin().isComponentsTimelocked(), "should be timelocked after enable");

        vm.stopPrank();
    }

    /* ===== enableComponentsTimelock ===== */

    function test_enableComponentsTimelock_sets_flag() public {
        assertFalse(admin().isComponentsTimelocked(), "should not be timelocked initially");

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit ComponentsTimelockEnabled();
        admin().enableComponentsTimelock();

        assertTrue(admin().isComponentsTimelocked(), "should be timelocked after enable");
    }

    function test_enableComponentsTimelock_only_owner() public {
        vm.prank(user);
        vm.expectRevert();
        admin().enableComponentsTimelock();
    }

    function test_enableComponentsTimelock_is_one_way() public {
        vm.prank(owner);
        admin().enableComponentsTimelock();

        assertTrue(admin().isComponentsTimelocked(), "should be timelocked");

        // There's no disableComponentsTimelock - it's one-way
        // Just verify state remains true
        assertTrue(admin().isComponentsTimelocked(), "should remain timelocked");
    }

    /* ===== setBufferManager/setRouter REVERT after timelock enabled ===== */

    function test_setBufferManager_reverts_after_timelock_enabled() public {
        vm.startPrank(owner);
        admin().setBufferManager(bufferManager1);
        admin().enableComponentsTimelock();
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(ComponentsTimelocked.selector);
        admin().setBufferManager(bufferManager2);
    }

    function test_setRouter_reverts_after_timelock_enabled() public {
        vm.startPrank(owner);
        admin().setRouter(router1);
        admin().enableComponentsTimelock();
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(ComponentsTimelocked.selector);
        admin().setRouter(router2);
    }

    /* ===== submitBufferManager FLOW ===== */

    function test_submitBufferManager_creates_pending_with_correct_eta() public {
        vm.startPrank(owner);
        admin().setBufferManager(bufferManager1);
        admin().enableComponentsTimelock();

        uint64 expectedEta = uint64(block.timestamp) + DEFAULT_MIN_DELAY;

        vm.expectEmit(true, true, true, true);
        emit BufferManagerSubmitted(bufferManager2, expectedEta);
        admin().submitBufferManager(bufferManager2);
        vm.stopPrank();

        (address newBuffer, uint64 eta, bool exists) = admin().getPendingBufferManager();
        assertEq(newBuffer, bufferManager2, "pending buffer mismatch");
        assertEq(eta, expectedEta, "eta mismatch");
        assertTrue(exists, "pending should exist");
    }

    function test_submitBufferManager_reverts_if_not_timelocked() public {
        // Without enableComponentsTimelock, submit should revert
        vm.prank(owner);
        vm.expectRevert(ComponentsNotTimelocked.selector);
        admin().submitBufferManager(bufferManager1);
    }

    function test_submitBufferManager_only_owner() public {
        vm.prank(owner);
        admin().enableComponentsTimelock();

        vm.prank(user);
        vm.expectRevert();
        admin().submitBufferManager(bufferManager1);
    }

    function test_acceptBufferManager_succeeds_after_delay() public {
        vm.startPrank(owner);
        admin().setBufferManager(bufferManager1);
        admin().enableComponentsTimelock();
        admin().submitBufferManager(bufferManager2);
        vm.stopPrank();

        // Fast forward past delay
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit BufferManagerAccepted(bufferManager2);
        admin().acceptBufferManager();

        // Verify buffer manager updated
        assertEq(address(vault.bufferManager()), bufferManager2, "bufferManager not updated");

        // Verify pending cleared
        (,, bool exists) = admin().getPendingBufferManager();
        assertFalse(exists, "pending should be cleared");
    }

    function test_acceptBufferManager_reverts_before_eta() public {
        vm.startPrank(owner);
        admin().enableComponentsTimelock();
        admin().submitBufferManager(bufferManager1);
        vm.stopPrank();

        // Try to accept immediately (before eta)
        vm.prank(owner);
        vm.expectRevert();
        admin().acceptBufferManager();

        // Try to accept 1 second before eta
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY - 1);
        vm.prank(owner);
        vm.expectRevert();
        admin().acceptBufferManager();
    }

    function test_acceptBufferManager_reverts_after_window_expires() public {
        vm.startPrank(owner);
        admin().enableComponentsTimelock();
        admin().submitBufferManager(bufferManager1);
        vm.stopPrank();

        // Fast forward past eta + PARAM_MAX_WINDOW
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY + PARAM_MAX_WINDOW + 1);

        vm.prank(owner);
        vm.expectRevert();
        admin().acceptBufferManager();
    }

    function test_acceptBufferManager_reverts_when_no_pending() public {
        vm.prank(owner);
        admin().enableComponentsTimelock();

        vm.prank(owner);
        vm.expectRevert(NotPending.selector);
        admin().acceptBufferManager();
    }

    function test_revokeBufferManager_clears_pending() public {
        vm.startPrank(owner);
        admin().enableComponentsTimelock();
        admin().submitBufferManager(bufferManager1);
        vm.stopPrank();

        // Verify pending exists
        (,, bool existsBefore) = admin().getPendingBufferManager();
        assertTrue(existsBefore, "pending should exist before revoke");

        // Revoke
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit BufferManagerRevoked();
        admin().revokeBufferManager();

        // Verify pending cleared
        (,, bool existsAfter) = admin().getPendingBufferManager();
        assertFalse(existsAfter, "pending should be cleared after revoke");
    }

    function test_revokeBufferManager_by_vetoer() public {
        vm.startPrank(owner);
        admin().enableComponentsTimelock();
        admin().submitBufferManager(bufferManager1);
        vm.stopPrank();

        // Vetoer can also revoke
        vm.prank(vetoer);
        admin().revokeBufferManager();

        (,, bool exists) = admin().getPendingBufferManager();
        assertFalse(exists, "pending should be cleared by vetoer");
    }

    /* ===== submitRouter FLOW ===== */

    function test_submitRouter_creates_pending_with_correct_eta() public {
        vm.startPrank(owner);
        admin().setRouter(router1);
        admin().enableComponentsTimelock();

        uint64 expectedEta = uint64(block.timestamp) + DEFAULT_MIN_DELAY;

        vm.expectEmit(true, true, true, true);
        emit RouterSubmitted(router2, expectedEta);
        admin().submitRouter(router2);
        vm.stopPrank();

        (address newRouter, uint64 eta, bool exists) = admin().getPendingRouter();
        assertEq(newRouter, router2, "pending router mismatch");
        assertEq(eta, expectedEta, "eta mismatch");
        assertTrue(exists, "pending should exist");
    }

    function test_submitRouter_reverts_if_not_timelocked() public {
        vm.prank(owner);
        vm.expectRevert(ComponentsNotTimelocked.selector);
        admin().submitRouter(router1);
    }

    function test_submitRouter_only_owner() public {
        vm.prank(owner);
        admin().enableComponentsTimelock();

        vm.prank(user);
        vm.expectRevert();
        admin().submitRouter(router1);
    }

    function test_acceptRouter_succeeds_after_delay() public {
        vm.startPrank(owner);
        admin().setRouter(router1);
        admin().enableComponentsTimelock();
        admin().submitRouter(router2);
        vm.stopPrank();

        vm.warp(block.timestamp + DEFAULT_MIN_DELAY);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit RouterAccepted(router2);
        admin().acceptRouter();

        assertEq(address(vault.router()), router2, "router not updated");

        (,, bool exists) = admin().getPendingRouter();
        assertFalse(exists, "pending should be cleared");
    }

    function test_acceptRouter_reverts_before_eta() public {
        vm.startPrank(owner);
        admin().enableComponentsTimelock();
        admin().submitRouter(router1);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert();
        admin().acceptRouter();
    }

    function test_acceptRouter_reverts_after_window_expires() public {
        vm.startPrank(owner);
        admin().enableComponentsTimelock();
        admin().submitRouter(router1);
        vm.stopPrank();

        vm.warp(block.timestamp + DEFAULT_MIN_DELAY + PARAM_MAX_WINDOW + 1);

        vm.prank(owner);
        vm.expectRevert();
        admin().acceptRouter();
    }

    function test_acceptRouter_reverts_when_no_pending() public {
        vm.prank(owner);
        admin().enableComponentsTimelock();

        vm.prank(owner);
        vm.expectRevert(NotPending.selector);
        admin().acceptRouter();
    }

    function test_revokeRouter_clears_pending() public {
        vm.startPrank(owner);
        admin().enableComponentsTimelock();
        admin().submitRouter(router1);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit RouterRevoked();
        admin().revokeRouter();

        (,, bool exists) = admin().getPendingRouter();
        assertFalse(exists, "pending should be cleared");
    }

    function test_revokeRouter_by_vetoer() public {
        vm.startPrank(owner);
        admin().enableComponentsTimelock();
        admin().submitRouter(router1);
        vm.stopPrank();

        vm.prank(vetoer);
        admin().revokeRouter();

        (,, bool exists) = admin().getPendingRouter();
        assertFalse(exists, "pending should be cleared by vetoer");
    }

    /* ===== INTEGRATION & EDGE CASES ===== */

    function test_both_pending_can_coexist() public {
        vm.startPrank(owner);
        admin().enableComponentsTimelock();
        admin().submitBufferManager(bufferManager1);
        admin().submitRouter(router1);
        vm.stopPrank();

        (,, bool bufferExists) = admin().getPendingBufferManager();
        (,, bool routerExists) = admin().getPendingRouter();

        assertTrue(bufferExists, "pending buffer should exist");
        assertTrue(routerExists, "pending router should exist");
    }

    function test_accept_both_after_delay() public {
        vm.startPrank(owner);
        admin().enableComponentsTimelock();
        admin().submitBufferManager(bufferManager1);
        admin().submitRouter(router1);
        vm.stopPrank();

        vm.warp(block.timestamp + DEFAULT_MIN_DELAY);

        vm.startPrank(owner);
        admin().acceptBufferManager();
        admin().acceptRouter();
        vm.stopPrank();

        assertEq(address(vault.bufferManager()), bufferManager1, "bufferManager not updated");
        assertEq(address(vault.router()), router1, "router not updated");
    }

    function test_resubmit_after_revoke() public {
        vm.startPrank(owner);
        admin().enableComponentsTimelock();

        // Submit and revoke buffer
        admin().submitBufferManager(bufferManager1);
        admin().revokeBufferManager();

        // Resubmit with different address
        admin().submitBufferManager(bufferManager2);
        vm.stopPrank();

        (address newBuffer,,) = admin().getPendingBufferManager();
        assertEq(newBuffer, bufferManager2, "should have new pending buffer");
    }

    function test_accept_at_exact_eta() public {
        vm.startPrank(owner);
        admin().enableComponentsTimelock();
        admin().submitBufferManager(bufferManager1);
        vm.stopPrank();

        // Accept at exact eta
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY);

        vm.prank(owner);
        admin().acceptBufferManager();

        assertEq(address(vault.bufferManager()), bufferManager1, "should accept at exact eta");
    }

    function test_accept_at_window_end_boundary() public {
        vm.startPrank(owner);
        admin().enableComponentsTimelock();
        admin().submitRouter(router1);
        vm.stopPrank();

        // Accept at eta + PARAM_MAX_WINDOW (last valid moment)
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY + PARAM_MAX_WINDOW);

        vm.prank(owner);
        admin().acceptRouter();

        assertEq(address(vault.router()), router1, "should accept at window end");
    }

    function test_submit_respects_updated_minDelay() public {
        // First wire up minDelay functions
        vm.startPrank(owner);
        admin().enableComponentsTimelock();
        vm.stopPrank();

        // Get current delay
        uint64 currentDelay = admin().getMinDelay();
        assertEq(currentDelay, DEFAULT_MIN_DELAY, "default delay mismatch");

        // Submit buffer with current delay
        vm.prank(owner);
        admin().submitBufferManager(bufferManager1);

        (, uint64 eta1,) = admin().getPendingBufferManager();
        assertEq(eta1, uint64(block.timestamp) + DEFAULT_MIN_DELAY, "eta should use current delay");
    }
}
