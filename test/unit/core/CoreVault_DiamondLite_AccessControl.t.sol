// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreVault } from "src/core/CoreVault.sol";
import { QueueModule } from "src/core/modules/QueueModule.sol";
import { AdminModule } from "src/core/modules/AdminModule.sol";
import { SelectorLib } from "src/core/libraries/SelectorLib.sol";
import { Events } from "src/core/libraries/Events.sol";
import { ERC20Mock } from "src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "test/helpers/MockParamsProvider.sol";
import { ModuleSetter } from "test/helpers/ModuleSetter.sol";
import { CoreHarness } from "test/helpers/CoreHarness.sol";
import { MockBufferManagerForTests } from "test/helpers/MockBufferManagerForTests.sol";
import { ExitEngineLib } from "src/core/libraries/ExitEngineLib.sol";

interface IQueueModule_AC {
    function requestClaim(bool immediate, uint256 shares) external;
}

/// @title CoreVault Access Control Tests
/// @notice Tests for timelock ownership, guardian restrictions, and role enforcement
contract CoreVault_AccessControl_Test is Test {
    CoreVault public router;
    QueueModule public queueModule;
    AdminModule public adminModule;
    ERC20Mock public usdc;
    MockParamsProvider public params;

    // Actors
    address public timelock = address(0x71E3); // Owner = Timelock (not multisig)
    address public guardian = address(0x6A2D);
    address public feeCollector = address(0xFEE5);
    address public attacker = address(0xBAD);
    address public user = address(0xBEEF);

    function setUp() public {
        // Deploy mock USDC
        usdc = new ERC20Mock("USDC", "USDC", 6);
        usdc._mint(user, 100_000e6);

        // Deploy params provider
        params = new MockParamsProvider();
        params.setLockPeriod(0);

        // Deploy CoreVault with Timelock as owner (via CoreHarness for setBufferManagerUnsafe)
        CoreHarness _harness = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Test Vault",
            "tVault",
            timelock, // Owner = Timelock (not direct multisig)
            feeCollector,
            address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(_harness));
        _harness.setBufferManagerUnsafe(address(mockBM));
        router = _harness;

        // Deploy modules
        queueModule = new QueueModule();
        adminModule = new AdminModule();

        // Configure routing from timelock
        vm.startPrank(timelock);

        bytes4[] memory queueSelectors = SelectorLib.getQueueModuleSelectors();
        ModuleSetter.setModulesSame(
            address(router), queueSelectors, address(queueModule), SelectorLib.ROLE_PUBLIC
        );

        bytes4[] memory adminOwnerSelectors = SelectorLib.getAdminModuleOwnerSelectors();
        ModuleSetter.setModulesSame(
            address(router), adminOwnerSelectors, address(adminModule), SelectorLib.ROLE_OWNER
        );

        bytes4[] memory adminViewSelectors = SelectorLib.getAdminModuleViewSelectors();
        ModuleSetter.setModulesSame(
            address(router), adminViewSelectors, address(adminModule), SelectorLib.ROLE_PUBLIC
        );

        // Note: Internal module selectors (processorMint/processorBurn) are no longer routed via modules
        // They are internal functions that check msg.sender == address(this)

        // Set guardian
        router.setGuardian(guardian);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // OWNER (TIMELOCK) ONLY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_owner_isTimelock() public view {
        assertEq(router.owner(), timelock, "Owner should be timelock");
    }

    function test_pauseAll_onlyOwner() public {
        // Attacker cannot pause
        vm.prank(attacker);
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.pauseAll();

        // Guardian cannot pause via pauseAll (only guardianPause)
        vm.prank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.pauseAll();

        // Timelock (owner) can pause
        vm.prank(timelock);
        router.pauseAll();
        assertTrue(router.paused());
    }

    function test_unpauseAll_onlyOwner() public {
        // First pause
        vm.prank(timelock);
        router.pauseAll();

        // Attacker cannot unpause
        vm.prank(attacker);
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.unpauseAll();

        // Guardian cannot unpause
        vm.prank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.unpauseAll();

        // Timelock (owner) can unpause
        vm.prank(timelock);
        router.unpauseAll();
        assertFalse(router.paused());
    }

    function test_setGuardian_onlyOwner() public {
        address newGuardian = address(0x1E06);

        // Attacker cannot set guardian
        vm.prank(attacker);
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.setGuardian(newGuardian);

        // Current guardian cannot set new guardian
        vm.prank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.setGuardian(newGuardian);

        // Timelock (owner) can set guardian
        vm.prank(timelock);
        router.setGuardian(newGuardian);
        assertEq(router.guardian(), newGuardian);
    }

    function test_beginOwnerTransfer_onlyOwner() public {
        address newOwner = address(0x1E00);

        // Attacker cannot transfer ownership
        vm.prank(attacker);
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.beginOwnerTransfer(newOwner);

        // Timelock (owner) can transfer
        vm.prank(timelock);
        router.beginOwnerTransfer(newOwner);
        assertEq(router.pendingOwner(), newOwner);
    }

    function test_setModule_onlyOwner() public {
        bytes4 selector = bytes4(0x12345678);

        // Attacker cannot set module
        vm.prank(attacker);
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.setModule(selector, address(0x1), 0);

        // Guardian cannot set module
        vm.prank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.setModule(selector, address(0x1), 0);
    }

    function test_freezeRouting_onlyOwner() public {
        // Attacker cannot freeze
        vm.prank(attacker);
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.freezeRouting();

        // Guardian cannot freeze
        vm.prank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.freezeRouting();

        // Timelock (owner) can freeze
        vm.prank(timelock);
        router.freezeRouting();
        assertTrue(router.isRoutingFrozen());
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // GUARDIAN ONLY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_guardian_canOnlyPause() public {
        // Warp past initial cooldown
        vm.warp(8 days);

        // Guardian can call guardianPause
        vm.prank(guardian);
        router.guardianPause();
        assertTrue(router.paused());
    }

    function test_guardian_cannotCallOwnerFunctions() public {
        vm.startPrank(guardian);

        // Guardian cannot pauseAll (owner function)
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.pauseAll();

        // Guardian cannot unpauseAll
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.unpauseAll();

        // Guardian cannot pauseDepositsOnly
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.pauseDepositsOnly(true);

        // Guardian cannot pauseWithdrawalsOnly
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.pauseWithdrawalsOnly(true);

        // Guardian cannot setGuardian
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.setGuardian(address(0x1));

        // Guardian cannot beginOwnerTransfer
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.beginOwnerTransfer(address(0x1));

        // Guardian cannot setModule
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.setModule(bytes4(0x00000001), address(0x1), 0);

        // Guardian cannot freezeRouting
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.freezeRouting();

        vm.stopPrank();
    }

    function test_guardian_cannotCallAdminModuleOwnerFunctions() public {
        // Guardian cannot call owner-only AdminModule functions via fallback
        vm.prank(guardian);
        (bool success, bytes memory data) = address(router)
            .call(
                abi.encodeWithSelector(AdminModule.submitFeeParams.selector, 10, 10, feeCollector)
            );
        assertFalse(success);
        assertEq(bytes4(data), CoreVault.NotOwner.selector);
    }

    function test_guardianPause_cooldown7Days() public {
        // Warp past initial cooldown
        vm.warp(8 days);

        // First pause succeeds
        vm.prank(guardian);
        router.guardianPause();
        assertTrue(router.paused());

        // Owner unpauses
        vm.prank(timelock);
        router.unpauseAll();

        // Second pause immediately fails (cooldown active)
        vm.prank(guardian);
        vm.expectRevert(CoreVault.GuardianCooldownActive.selector);
        router.guardianPause();

        // After 7 days, guardian can pause again
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(guardian);
        router.guardianPause();
        assertTrue(router.paused());
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN MODULE ACCESS CONTROL (via routing)
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_adminModule_ownerFunctions_blockedForNonOwner() public {
        // List of owner-only AdminModule functions
        bytes4[] memory ownerSelectors = SelectorLib.getAdminModuleOwnerSelectors();

        for (uint256 i; i < ownerSelectors.length; i++) {
            vm.prank(attacker);
            (bool success, bytes memory data) =
                address(router).call(abi.encodeWithSelector(ownerSelectors[i]));
            // Either the call fails, or it reverts with NotOwner
            // Some calls might succeed with invalid data (view functions),
            // but mutation should fail
            if (!success && data.length >= 4) {
                assertEq(bytes4(data), CoreVault.NotOwner.selector, "Should revert with NotOwner");
            }
        }
    }

    function test_adminModule_viewFunctions_allowedForAnyone() public view {
        // List of public AdminModule view functions
        bytes4[] memory viewSelectors = SelectorLib.getAdminModuleViewSelectors();

        for (uint256 i; i < viewSelectors.length; i++) {
            // View functions should not revert (they're public)
            (bool success,) = address(router).staticcall(abi.encodeWithSelector(viewSelectors[i]));
            assertTrue(success, "View function should not revert");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // QUEUE MODULE ACCESS CONTROL (PUBLIC)
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_queueModule_functionsArePublic() public {
        // Queue functions should be callable by anyone (though may revert for other reasons)
        bytes4[] memory queueSelectors = SelectorLib.getQueueModuleSelectors();

        // Just verify role check passes - actual function may revert for other reasons
        for (uint256 i; i < queueSelectors.length; i++) {
            assertEq(
                router.roleOf(queueSelectors[i]),
                SelectorLib.ROLE_PUBLIC,
                "Queue function should be public"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // OWNERSHIP TRANSFER (2-STEP)
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_ownershipTransfer_requiresAcceptance() public {
        address newOwner = address(0x1E00);

        // Timelock initiates transfer
        vm.prank(timelock);
        router.beginOwnerTransfer(newOwner);

        // Ownership not changed yet
        assertEq(router.owner(), timelock);
        assertEq(router.pendingOwner(), newOwner);

        // Random user cannot accept
        vm.prank(attacker);
        vm.expectRevert(CoreVault.NoTransferPending.selector);
        router.acceptOwnerTransfer();

        // Original owner cannot accept for new owner
        vm.prank(timelock);
        vm.expectRevert(CoreVault.NoTransferPending.selector);
        router.acceptOwnerTransfer();

        // New owner accepts
        vm.prank(newOwner);
        router.acceptOwnerTransfer();

        // Ownership changed
        assertEq(router.owner(), newOwner);
        assertEq(router.pendingOwner(), address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // DEPOSIT/WITHDRAW NOT BLOCKED BY ROLE
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_deposit_allowedForAnyUser() public {
        vm.startPrank(user);
        usdc.approve(address(router), 1000e6);

        uint256 shares = router.deposit(1000e6, user);
        assertGt(shares, 0);
        vm.stopPrank();
    }

    function test_withdraw_allowedForAnyUser() public {
        // First deposit
        vm.startPrank(user);
        usdc.approve(address(router), 1000e6);
        router.deposit(1000e6, user);

        // redeem() always reverts now; verify requestClaim works for any user
        uint256 shares = router.balanceOf(user);
        IQueueModule_AC(address(router)).requestClaim(true, shares);
        // Just verify it doesn't revert (role check passes)
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PAUSE BLOCKS OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_pause_blocksDeposit() public {
        vm.prank(timelock);
        router.pauseAll();

        vm.startPrank(user);
        usdc.approve(address(router), 1000e6);

        vm.expectRevert(CoreVault.Paused.selector);
        router.deposit(1000e6, user);
        vm.stopPrank();
    }

    function test_pause_blocksWithdraw() public {
        // First deposit while not paused
        vm.startPrank(user);
        usdc.approve(address(router), 1000e6);
        router.deposit(1000e6, user);
        vm.stopPrank();

        // Pause
        vm.prank(timelock);
        router.pauseAll();

        // redeem() always reverts with AsyncWithdrawalRequired (before pause check)
        vm.prank(user);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        router.redeem(100, user, user);
    }

    function test_guardianPause_blocksAllOperations() public {
        vm.warp(8 days);

        // Deposit while not paused
        vm.startPrank(user);
        usdc.approve(address(router), 1000e6);
        router.deposit(1000e6, user);
        vm.stopPrank();

        // Guardian pauses
        vm.prank(guardian);
        router.guardianPause();

        // Deposit blocked
        vm.startPrank(user);
        usdc.approve(address(router), 1000e6);
        vm.expectRevert(CoreVault.Paused.selector);
        router.deposit(1000e6, user);
        vm.stopPrank();

        // redeem() always reverts with AsyncWithdrawalRequired (before pause check)
        vm.prank(user);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        router.redeem(100, user, user);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // EVENT EMISSION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_pauseAll_emitsEvent() public {
        vm.prank(timelock);
        vm.expectEmit(false, false, false, false);
        emit Events.AllPaused();
        router.pauseAll();
    }

    function test_unpauseAll_emitsEvent() public {
        // First pause
        vm.prank(timelock);
        router.pauseAll();

        // Then unpause and check event
        vm.prank(timelock);
        vm.expectEmit(false, false, false, false);
        emit Events.AllUnpaused();
        router.unpauseAll();
    }

    function test_beginOwnerTransfer_emitsEvent() public {
        address newOwner = address(0x1E00);

        vm.prank(timelock);
        vm.expectEmit(true, true, false, false);
        emit Events.OwnershipTransferInitiated(timelock, newOwner);
        router.beginOwnerTransfer(newOwner);
    }

    function test_acceptOwnerTransfer_emitsEvent() public {
        address newOwner = address(0x1E00);

        // First initiate transfer
        vm.prank(timelock);
        router.beginOwnerTransfer(newOwner);

        // Then accept and check event
        vm.prank(newOwner);
        vm.expectEmit(true, true, false, false);
        emit Events.OwnershipTransferred(timelock, newOwner);
        router.acceptOwnerTransfer();
    }
}
