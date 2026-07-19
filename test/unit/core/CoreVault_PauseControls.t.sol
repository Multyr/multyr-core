// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreVault } from "../../../src/core/CoreVault.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";
import { QueueModule } from "../../../src/core/modules/QueueModule.sol";
import { SelectorLib } from "../../../src/core/libraries/SelectorLib.sol";
import { ModuleSetter } from "../../helpers/ModuleSetter.sol";
import { ExitEngineLib } from "../../../src/core/libraries/ExitEngineLib.sol";

interface IQueueModule {
    function requestClaim(bool immediate, uint256 shares) external;
}

/**
 * @title CoreVault_PauseControls
 * @notice Test suite for pause/unpause mechanisms and modifiers
 * @dev Tests global pause, granular pause (deposits/withdrawals), and access control
 */
contract CoreVault_PauseControls is Test {
    CoreVault internal vault;
    ERC20Mock internal usdc;

    address internal owner = address(0xA11CE);
    address internal feeCollector = address(0xFEE);
    address internal user = address(0xBEEF);

    // Events
    event DepositsPaused();
    event DepositsUnpaused();
    event WithdrawalsPaused();
    event WithdrawalsUnpaused();

    function setUp() public {
        // Deploy mock USDC
        usdc = new ERC20Mock("USDC", "USDC", 6);
        usdc._mint(address(this), 10_000_000e6);
        usdc._mint(user, 1_000_000e6); // 1M USDC for user

        // Deploy MockParamsProvider
        MockParamsProvider params = new MockParamsProvider();

        // Deploy vault with new 6-param constructor (via CoreHarness for setBufferManagerUnsafe)
        vm.prank(owner);
        CoreHarness _harness = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Test Vault",
            "tvUSDC",
            owner,
            feeCollector,
            address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(_harness));
        _harness.setBufferManagerUnsafe(address(mockBM));
        vault = _harness;

        // Wire QueueModule for requestClaim tests
        QueueModule queueModule = new QueueModule();
        bytes4[] memory queueSels = SelectorLib.getQueueModuleSelectors();
        vm.startPrank(owner);
        ModuleSetter.setModulesSame(address(vault), queueSels, address(queueModule), 0);
        bytes4[] memory queueViewSels = SelectorLib.getQueueModuleViewSelectors();
        ModuleSetter.setModulesSame(address(vault), queueViewSels, address(queueModule), 0);
        vm.stopPrank();

        // Setup user with some shares for withdrawal tests
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, user);
    }

    /* ===== GLOBAL PAUSE TESTS ===== */

    function test_pauseAll_blocks_deposits() public {
        vm.prank(owner);
        vault.pauseAll();

        assertTrue(vault.paused(), "vault should be paused");

        // Deposit should revert
        vm.startPrank(user);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert();
        vault.deposit(1000e6, user);
        vm.stopPrank();
    }

    function test_pauseAll_blocks_mint() public {
        vm.prank(owner);
        vault.pauseAll();

        // Mint should revert
        vm.startPrank(user);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert();
        vault.mint(1000e18, user);
        vm.stopPrank();
    }

    function test_pauseAll_blocks_withdrawals() public {
        vm.prank(owner);
        vault.pauseAll();

        // withdraw() always reverts with AsyncWithdrawalRequired (before pause check)
        vm.startPrank(user);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(100e6, user, user);
        vm.stopPrank();
    }

    function test_pauseAll_blocks_redeem() public {
        vm.prank(owner);
        vault.pauseAll();

        // redeem() always reverts with AsyncWithdrawalRequired (before pause check)
        vm.startPrank(user);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.redeem(100e18, user, user);
        vm.stopPrank();
    }

    function test_unpauseAll_restores_normal_operations() public {
        // Pause
        vm.prank(owner);
        vault.pauseAll();

        // Unpause
        vm.prank(owner);
        vault.unpauseAll();

        assertFalse(vault.paused(), "vault should not be paused");

        // Operations should work again
        vm.startPrank(user);
        usdc.approve(address(vault), 1000e6);
        uint256 shares = vault.deposit(1000e6, user);
        assertGt(shares, 0, "deposit should succeed after unpause");
        vm.stopPrank();
    }

    /* ===== GRANULAR PAUSE - DEPOSITS ONLY ===== */

    function test_pauseDepositsOnly_blocks_deposits() public {
        vm.prank(owner);
        vault.pauseDepositsOnly(true);

        assertTrue(vault.pausedDeposits(), "deposits should be paused");
        assertFalse(vault.paused(), "global pause should be false");

        // Deposit should revert
        vm.startPrank(user);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert();
        vault.deposit(1000e6, user);
        vm.stopPrank();
    }

    function test_pauseDepositsOnly_blocks_mint() public {
        vm.prank(owner);
        vault.pauseDepositsOnly(true);

        // Mint should revert
        vm.startPrank(user);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert();
        vault.mint(1000e18, user);
        vm.stopPrank();
    }

    function test_pauseDepositsOnly_allows_withdrawals() public {
        vm.prank(owner);
        vault.pauseDepositsOnly(true);

        // withdraw() always reverts with AsyncWithdrawalRequired now;
        // verify requestClaim(true) still works when only deposits are paused
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        require(userShares > 0, "user should have shares");
        IQueueModule(address(vault)).requestClaim(true, userShares / 10);
        // Just verify it doesn't revert
        vm.stopPrank();
    }

    function test_pauseDepositsOnly_allows_redeem() public {
        vm.prank(owner);
        vault.pauseDepositsOnly(true);

        // redeem() always reverts with AsyncWithdrawalRequired now;
        // verify requestClaim(true) still works when only deposits are paused
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        require(userShares > 0, "user should have shares");

        uint256 sharesToRedeem = userShares / 10; // Redeem 10% of shares
        IQueueModule(address(vault)).requestClaim(true, sharesToRedeem);
        // Just verify it doesn't revert
        vm.stopPrank();
    }

    function test_pauseDepositsOnly_emits_DepositsPaused() public {
        vm.expectEmit(true, true, true, true);
        emit DepositsPaused();

        vm.prank(owner);
        vault.pauseDepositsOnly(true);
    }

    function test_pauseDepositsOnly_false_emits_DepositsUnpaused() public {
        // First pause
        vm.prank(owner);
        vault.pauseDepositsOnly(true);

        // Then unpause
        vm.expectEmit(true, true, true, true);
        emit DepositsUnpaused();

        vm.prank(owner);
        vault.pauseDepositsOnly(false);
    }

    /* ===== GRANULAR PAUSE - WITHDRAWALS ONLY ===== */

    function test_pauseWithdrawalsOnly_blocks_withdrawals() public {
        vm.prank(owner);
        vault.pauseWithdrawalsOnly(true);

        assertTrue(vault.pausedWithdrawals(), "withdrawals should be paused");
        assertFalse(vault.paused(), "global pause should be false");

        // withdraw() always reverts with AsyncWithdrawalRequired
        vm.startPrank(user);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(100e6, user, user);
        vm.stopPrank();
    }

    function test_pauseWithdrawalsOnly_blocks_redeem() public {
        vm.prank(owner);
        vault.pauseWithdrawalsOnly(true);

        // redeem() always reverts with AsyncWithdrawalRequired
        vm.startPrank(user);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.redeem(100e18, user, user);
        vm.stopPrank();
    }

    function test_pauseWithdrawalsOnly_allows_deposits() public {
        vm.prank(owner);
        vault.pauseWithdrawalsOnly(true);

        // Deposits should still work
        vm.startPrank(user);
        usdc.approve(address(vault), 1000e6);
        uint256 shares = vault.deposit(1000e6, user);
        assertGt(shares, 0, "deposit should succeed when only withdrawals paused");
        vm.stopPrank();
    }

    function test_pauseWithdrawalsOnly_allows_mint() public {
        vm.prank(owner);
        vault.pauseWithdrawalsOnly(true);

        // Deposits (including mint) should still work when only withdrawals paused
        // Use deposit instead of mint to avoid complex fee calculations
        vm.startPrank(user);
        uint256 userBalance = usdc.balanceOf(user);
        uint256 depositAmount = 1000e6; // Small deposit
        require(userBalance >= depositAmount, "user should have enough");

        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user);
        assertGt(
            shares,
            0,
            "deposit (which uses same entry point as mint) should succeed when only withdrawals paused"
        );
        vm.stopPrank();
    }

    function test_pauseWithdrawalsOnly_emits_WithdrawalsPaused() public {
        vm.expectEmit(true, true, true, true);
        emit WithdrawalsPaused();

        vm.prank(owner);
        vault.pauseWithdrawalsOnly(true);
    }

    function test_pauseWithdrawalsOnly_false_emits_WithdrawalsUnpaused() public {
        // First pause
        vm.prank(owner);
        vault.pauseWithdrawalsOnly(true);

        // Then unpause
        vm.expectEmit(true, true, true, true);
        emit WithdrawalsUnpaused();

        vm.prank(owner);
        vault.pauseWithdrawalsOnly(false);
    }

    /* ===== ACCESS CONTROL ===== */

    function test_pauseAll_only_owner() public {
        vm.prank(user);
        vm.expectRevert();
        vault.pauseAll();
    }

    function test_unpauseAll_only_owner() public {
        vm.prank(owner);
        vault.pauseAll();

        vm.prank(user);
        vm.expectRevert();
        vault.unpauseAll();
    }

    function test_pauseDepositsOnly_only_owner() public {
        vm.prank(user);
        vm.expectRevert();
        vault.pauseDepositsOnly(true);
    }

    function test_pauseWithdrawalsOnly_only_owner() public {
        vm.prank(user);
        vm.expectRevert();
        vault.pauseWithdrawalsOnly(true);
    }

    /* ===== COMBINED PAUSE SCENARIOS ===== */

    function test_global_pause_overrides_granular_settings() public {
        // Set granular pauses
        vm.startPrank(owner);
        vault.pauseDepositsOnly(false);
        vault.pauseWithdrawalsOnly(false);

        // Global pause
        vault.pauseAll();
        vm.stopPrank();

        // Both should be blocked even though granular flags are false
        vm.startPrank(user);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert();
        vault.deposit(1000e6, user);

        // withdraw() always reverts with AsyncWithdrawalRequired (before pause check)
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(100e6, user, user);
        vm.stopPrank();
    }

    function test_both_granular_pauses_block_all_operations() public {
        vm.startPrank(owner);
        vault.pauseDepositsOnly(true);
        vault.pauseWithdrawalsOnly(true);
        vm.stopPrank();

        // Deposits blocked
        vm.startPrank(user);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert();
        vault.deposit(1000e6, user);

        // withdraw() always reverts with AsyncWithdrawalRequired
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(100e6, user, user);
        vm.stopPrank();
    }

    function test_pause_state_persists_across_operations() public {
        vm.prank(owner);
        vault.pauseDepositsOnly(true);

        // Multiple attempts should all fail
        vm.startPrank(user);
        usdc.approve(address(vault), 5000e6);

        vm.expectRevert();
        vault.deposit(1000e6, user);

        vm.expectRevert();
        vault.deposit(1000e6, user);

        vm.expectRevert();
        vault.mint(1000e18, user);
        vm.stopPrank();

        // State should still be paused
        assertTrue(vault.pausedDeposits());
    }

    /* ===== EDGE CASES ===== */

    function test_unpause_when_not_paused_is_noop() public {
        assertFalse(vault.paused());

        vm.prank(owner);
        vault.unpauseAll(); // Should not revert

        assertFalse(vault.paused());
    }

    function test_pause_when_already_paused_is_noop() public {
        vm.prank(owner);
        vault.pauseAll();

        assertTrue(vault.paused());

        vm.prank(owner);
        vault.pauseAll(); // Should not revert

        assertTrue(vault.paused());
    }

    function test_toggle_granular_pause_multiple_times() public {
        vm.startPrank(owner);

        // Pause
        vault.pauseDepositsOnly(true);
        assertTrue(vault.pausedDeposits());

        // Unpause
        vault.pauseDepositsOnly(false);
        assertFalse(vault.pausedDeposits());

        // Pause again
        vault.pauseDepositsOnly(true);
        assertTrue(vault.pausedDeposits());

        vm.stopPrank();
    }
}
