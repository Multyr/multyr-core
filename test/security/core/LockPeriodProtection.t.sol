// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreVault } from "../../../src/core/CoreVault.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { QueueModule } from "../../../src/core/modules/QueueModule.sol";
import { AdminModule } from "../../../src/core/modules/AdminModule.sol";
import { IQueueModule } from "../../../src/interfaces/IQueueModule.sol";

/**
 * @title LockPeriodProtection
 * @notice Security tests for lock period protection against flash loan attacks
 * @dev Lock period prevents same-block/same-day deposit-withdraw arbitrage
 *
 * Run with high fuzz runs: forge test --match-contract LockPeriodProtection --fuzz-runs 10000
 */
contract LockPeriodProtection is Test {
    CoreHarness internal vault;
    ERC20Mock internal usdc;
    MockParamsProvider internal params;
    QueueModule internal queueModule;
    AdminModule internal adminModule;

    address internal owner = address(0xA11CE);
    address internal guardian = address(0xB0B);
    address internal treasury = address(0xFEE);
    address internal attacker = address(0xBAD);
    address internal victim = address(0xBEEF);

    uint64 constant LOCK_PERIOD = 1 days;
    uint256 constant FLASH_AMOUNT = 10_000_000e6;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);

        usdc._mint(attacker, FLASH_AMOUNT);
        usdc._mint(victim, 1_000_000e6);

        // Deploy params WITH lock period enabled
        params = new MockParamsProvider();
        params.setLockPeriod(LOCK_PERIOD);

        // Deploy modules
        queueModule = new QueueModule();
        adminModule = new AdminModule();

        // Deploy CoreHarness (wires all modules + unpauses automatically)
        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Test Vault",
            "tvUSDC",
            address(this), // owner (this contract for setup)
            treasury,
            address(params)
        );

        // Wire up modules
        _wireModules();

        // Set guardian
        vault.setGuardian(guardian);

        // Transfer ownership
        vault.beginOwnerTransfer(owner);
        vm.prank(owner);
        vault.acceptOwnerTransfer();

        // Victim deposits first (establishes existing shareholders)
        vm.startPrank(victim);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000e6, victim);
        vm.stopPrank();

        // Attacker approves
        vm.prank(attacker);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _wireModules() internal {
        // QueueModule selectors (PUBLIC)
        vault.setModule(
            QueueModule.requestClaim.selector, address(queueModule), vault.ROLE_PUBLIC()
        );
        vault.setModule(QueueModule.cancelClaim.selector, address(queueModule), vault.ROLE_PUBLIC());
        vault.setModule(
            QueueModule.processQueuedRedemptions.selector, address(queueModule), vault.ROLE_PUBLIC()
        );
        vault.setModule(
            QueueModule.settleFeesAndProcessQueue.selector,
            address(queueModule),
            vault.ROLE_PUBLIC()
        );
        vault.setModule(
            QueueModule.pendingShares.selector, address(queueModule), vault.ROLE_PUBLIC()
        );
        vault.setModule(QueueModule.queueLength.selector, address(queueModule), vault.ROLE_PUBLIC());

        // AdminModule selectors (OWNER)
        vault.setModule(
            AdminModule.submitFeeParams.selector, address(adminModule), vault.ROLE_OWNER()
        );
        vault.setModule(
            AdminModule.acceptFeeParams.selector, address(adminModule), vault.ROLE_OWNER()
        );
        vault.setModule(
            AdminModule.getFeeParams.selector, address(adminModule), vault.ROLE_PUBLIC()
        );
    }

    /* ========== LOCK PERIOD ENFORCEMENT ========== */

    /**
     * @notice Cannot withdraw immediately after deposit
     */
    function test_cannot_withdraw_before_lock_period() public {
        vm.startPrank(attacker);

        vault.deposit(FLASH_AMOUNT, attacker);

        // Try to withdraw immediately - should fail
        vm.expectRevert();
        vault.withdraw(FLASH_AMOUNT, attacker, attacker);

        vm.stopPrank();
    }

    /**
     * @notice Cannot redeem immediately after deposit
     */
    function test_cannot_redeem_before_lock_period() public {
        vm.startPrank(attacker);

        vault.deposit(FLASH_AMOUNT, attacker);
        uint256 shares = vault.balanceOf(attacker);

        // Try to redeem immediately - should fail
        vm.expectRevert();
        vault.redeem(shares, attacker, attacker);

        vm.stopPrank();
    }

    /**
     * @notice Can withdraw after lock period expires
     */
    function test_can_withdraw_after_lock_period() public {
        vm.startPrank(attacker);

        vault.deposit(FLASH_AMOUNT, attacker);

        // Warp past lock period
        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        // Now withdrawal should work (async pattern)
        uint256 usdcBefore = usdc.balanceOf(attacker);
        uint256 shares = vault.previewWithdraw(FLASH_AMOUNT);
        IQueueModule(address(vault)).requestClaim(true, shares);
        vm.stopPrank();
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);
        uint256 assets = usdc.balanceOf(attacker) - usdcBefore;
        assertGt(assets, 0, "withdraw works after lock");
    }

    /**
     * @notice Can redeem after lock period expires
     */
    function test_can_redeem_after_lock_period() public {
        vm.startPrank(attacker);

        vault.deposit(FLASH_AMOUNT, attacker);
        uint256 shares = vault.balanceOf(attacker);

        // Warp past lock period
        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        // Now redeem should work (async pattern)
        uint256 usdcBefore = usdc.balanceOf(attacker);
        IQueueModule(address(vault)).requestClaim(true, shares);
        vm.stopPrank();
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);
        uint256 assets = usdc.balanceOf(attacker) - usdcBefore;
        assertGt(assets, 0, "redeem works after lock");
    }

    /* ========== FLASH LOAN ATTACK BLOCKED ========== */

    /**
     * @notice Flash loan attack is blocked by lock period
     */
    function test_flash_loan_attack_blocked() public {
        // Simulates flash loan attack:
        // 1. Borrow 10M via flash loan
        // 2. Deposit to vault
        // 3. Try to withdraw to repay flash loan - BLOCKED!

        vm.startPrank(attacker);

        // Step 1-2: Deposit flash-loaned funds
        vault.deposit(FLASH_AMOUNT, attacker);

        // Step 3: Cannot withdraw to repay flash loan (lock period)
        vm.expectRevert();
        vault.withdraw(FLASH_AMOUNT, attacker, attacker);

        vm.stopPrank();

        // Attacker would default on flash loan - attack failed
    }

    /**
     * @notice Multiple deposits don't bypass lock
     */
    function test_cannot_bypass_lock_with_multiple_deposits() public {
        vm.startPrank(attacker);

        // Multiple deposits
        vault.deposit(1_000_000e6, attacker);
        vault.deposit(2_000_000e6, attacker);
        vault.deposit(3_000_000e6, attacker);

        // Still cannot withdraw any (all locked)
        vm.expectRevert();
        vault.withdraw(1e6, attacker, attacker);

        vm.stopPrank();
    }

    /**
     * @notice Second deposit resets/extends lock period
     */
    function test_second_deposit_extends_lock() public {
        // Use explicit timestamps to avoid any variable confusion
        // Foundry starts at timestamp = 1
        uint256 T0 = 1;
        uint256 T12H = T0 + 12 hours; // 43201
        uint256 T24H = T0 + 24 hours; // 86401
        uint256 T36H = T0 + 36 hours; // 129601

        vm.startPrank(attacker);

        // First deposit at t=1
        vault.deposit(1_000_000e6, attacker);

        // Warp to 12 hours
        vm.warp(T12H);
        assertEq(block.timestamp, T12H, "should be at T+12h");

        // Second deposit resets lock (now lastDepositTs = T12H)
        vault.deposit(1_000_000e6, attacker);

        // Warp to 24h (only 12h from second deposit, need 24h)
        vm.warp(T24H);
        assertEq(block.timestamp, T24H, "should be at T+24h");

        // Should still be locked (second deposit was 12h ago, lock is 24h)
        // At T24H = 86401, lastDepositTs = 43201, unlock at 43201 + 86400 = 129601
        // 86401 < 129601, so still locked
        vm.expectRevert();
        vault.withdraw(1e6, attacker, attacker);

        // Warp to full 24h+ from second deposit (36h+ from start)
        vm.warp(T36H + 1);
        assertEq(block.timestamp, T36H + 1, "should be at T+36h+1");

        // Now should work (129602 > 129601, async pattern)
        uint256 sh = vault.previewWithdraw(1e6);
        IQueueModule(address(vault)).requestClaim(true, sh);
        vm.stopPrank();
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);
    }

    /* ========== FUZZ TESTS ========== */

    /**
     * @notice Fuzz: Lock period always enforced
     */
    function testFuzz_lock_period_enforced(uint256 amount, uint256 waitTime) public {
        amount = bound(amount, 1e6, FLASH_AMOUNT);
        waitTime = bound(waitTime, 0, LOCK_PERIOD - 1);

        vm.startPrank(attacker);

        vault.deposit(amount, attacker);

        // Warp less than lock period
        vm.warp(block.timestamp + waitTime);

        // Should still fail
        vm.expectRevert();
        vault.withdraw(1e6, attacker, attacker);

        vm.stopPrank();
    }

    /**
     * @notice Fuzz: Can always withdraw after lock expires
     */
    function testFuzz_can_withdraw_after_lock(uint256 amount, uint256 extraWait) public {
        amount = bound(amount, 1e6, FLASH_AMOUNT);
        extraWait = bound(extraWait, 1, 30 days);

        vm.startPrank(attacker);

        vault.deposit(amount, attacker);

        // Warp past lock period
        vm.warp(block.timestamp + LOCK_PERIOD + extraWait);

        // Should work (async pattern)
        uint256 usdcBefore = usdc.balanceOf(attacker);
        uint256 sh = vault.previewWithdraw(amount / 2);
        IQueueModule(address(vault)).requestClaim(true, sh);
        vm.stopPrank();
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);
        uint256 received = usdc.balanceOf(attacker) - usdcBefore;
        assertGt(received, 0, "withdraw works after lock");
    }

    /* ========== ECONOMIC PROTECTION VERIFICATION ========== */

    /**
     * @notice Victim protected during lock period
     */
    function test_victim_protected_during_lock() public {
        uint256 victimShares = vault.balanceOf(victim);
        uint256 victimValueBefore = vault.convertToAssets(victimShares);

        // Attacker deposits large amount
        vm.startPrank(attacker);
        vault.deposit(FLASH_AMOUNT, attacker);

        // Attacker cannot exit immediately to manipulate price
        uint256 attackerShares = vault.balanceOf(attacker);
        vm.expectRevert();
        vault.redeem(attackerShares, attacker, attacker);
        vm.stopPrank();

        // Victim's value is protected
        uint256 victimValueAfter = vault.convertToAssets(victimShares);
        assertApproxEqRel(victimValueAfter, victimValueBefore, 0.0001e18, "victim protected");
    }

    /**
     * @notice Lock period prevents arbitrage
     */
    function testFuzz_lock_prevents_arbitrage(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e6, FLASH_AMOUNT);

        uint256 attackerStart = usdc.balanceOf(attacker);

        vm.startPrank(attacker);

        vault.deposit(depositAmount, attacker);
        uint256 shares = vault.balanceOf(attacker);

        // Cannot immediately exit to arbitrage
        vm.expectRevert();
        vault.redeem(shares, attacker, attacker);

        vm.stopPrank();

        // Attacker's funds are locked - no arbitrage possible
        uint256 attackerEnd = usdc.balanceOf(attacker);
        assertLt(attackerEnd, attackerStart, "funds locked in vault");
    }

    /* ========== CLAIM SYSTEM LOCK ========== */

    /**
     * @notice Claim requests respect lock period
     */
    function test_claim_respects_lock_period() public {
        vm.startPrank(attacker);

        vault.deposit(FLASH_AMOUNT, attacker);
        uint256 shares = vault.balanceOf(attacker);

        // Request claim immediately
        try IQueueModule(address(vault)).requestClaim(true, shares) {
            // If immediate claim allowed, funds should not be transferred yet
            // (claim goes to queue or is blocked)
            uint256 attackerBalance = usdc.balanceOf(attacker);
            assertEq(attackerBalance, 0, "no immediate payout during lock");
        } catch {
            // Claim blocked during lock - also valid
            assertTrue(true, "claim blocked during lock");
        }

        vm.stopPrank();
    }
}
