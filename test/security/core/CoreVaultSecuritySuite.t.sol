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
import { IAdminModule } from "../../../src/interfaces/IAdminModule.sol";

/**
 * @title CoreVaultSecuritySuite
 * @notice Comprehensive security test suite for CoreVault
 * @dev Heavy fuzzing auditor-style tests covering:
 *      - Flash loan attacks
 *      - Share inflation/deflation
 *      - Sandwich attacks
 *      - Access control exploits
 *      - DoS/griefing vectors
 *      - State consistency
 *
 * Run with high fuzz runs: forge test --match-contract CoreVaultSecuritySuite --fuzz-runs 50000
 */
contract CoreVaultSecuritySuite is Test {
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
    address internal user1 = address(0xCAFE);

    uint256 constant INITIAL_DEPOSIT = 1_000_000e6;
    uint256 constant MAX_DEPOSIT = 100_000_000e6;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);

        usdc._mint(attacker, type(uint128).max);
        usdc._mint(victim, type(uint128).max);
        usdc._mint(user1, type(uint128).max);
        usdc._mint(address(this), type(uint128).max);

        params = new MockParamsProvider();

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

        // Approvals
        vm.prank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(victim);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(user1);
        usdc.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);

        // Initial liquidity
        vault.deposit(INITIAL_DEPOSIT, address(this));
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
            AdminModule.revokeFeeParams.selector, address(adminModule), vault.ROLE_PUBLIC()
        ); // Internal check for owner/vetoer
        vault.setModule(AdminModule.setVetoer.selector, address(adminModule), vault.ROLE_OWNER());
        vault.setModule(
            AdminModule.getFeeParams.selector, address(adminModule), vault.ROLE_PUBLIC()
        );
    }

    /* ========== FLASH LOAN / ECONOMIC ATTACKS ========== */

    /**
     * @notice Flash loan deposit/withdraw should never be profitable
     */
    function testFuzz_flash_loan_never_profitable(uint256 amount) public {
        amount = bound(amount, 1e6, MAX_DEPOSIT);

        uint256 startBalance = usdc.balanceOf(attacker);

        vm.startPrank(attacker);
        uint256 shares = vault.deposit(amount, attacker);
        IQueueModule(address(vault)).requestClaim(true, shares);
        vm.stopPrank();
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);

        uint256 endBalance = usdc.balanceOf(attacker);
        assertLe(endBalance, startBalance, "flash loan never profitable");
    }

    /**
     * @notice Share price remains stable across operations
     */
    function testFuzz_share_price_stability(uint256 deposit1, uint256 deposit2, uint256 withdraw1)
        public
    {
        deposit1 = bound(deposit1, 1e6, MAX_DEPOSIT);
        deposit2 = bound(deposit2, 1e6, MAX_DEPOSIT);
        withdraw1 = bound(withdraw1, 1, deposit1);

        uint256 priceBefore = vault.convertToAssets(1e6);

        vm.prank(attacker);
        vault.deposit(deposit1, attacker);

        vm.prank(victim);
        vault.deposit(deposit2, victim);

        uint256 sharesToWithdraw = vault.previewWithdraw(withdraw1);
        vm.prank(attacker);
        IQueueModule(address(vault)).requestClaim(true, sharesToWithdraw);
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);

        uint256 priceAfter = vault.convertToAssets(1e6);

        // Price should remain within 0.01%
        assertApproxEqRel(priceAfter, priceBefore, 0.0001e18, "price stable");
    }

    /**
     * @notice Victim protected from whale deposits
     */
    function testFuzz_whale_cannot_dilute_retail(uint256 whaleSize, uint256 retailSize) public {
        retailSize = bound(retailSize, 1e6, 100_000e6);
        whaleSize = bound(whaleSize, 10_000_000e6, MAX_DEPOSIT);

        // Retail deposits first
        vm.prank(victim);
        uint256 retailShares = vault.deposit(retailSize, victim);
        uint256 retailValueBefore = vault.convertToAssets(retailShares);

        // Whale enters and exits
        vm.startPrank(attacker);
        uint256 whaleShares = vault.deposit(whaleSize, attacker);
        IQueueModule(address(vault)).requestClaim(true, whaleShares);
        vm.stopPrank();
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);

        // Retail value unchanged
        uint256 retailValueAfter = vault.convertToAssets(retailShares);
        assertApproxEqRel(retailValueAfter, retailValueBefore, 0.0001e18, "retail protected");
    }

    /* ========== SANDWICH ATTACK PROTECTION ========== */

    /**
     * @notice Classic sandwich attack is not profitable
     */
    function testFuzz_sandwich_not_profitable(uint256 attackSize, uint256 victimSize) public {
        attackSize = bound(attackSize, 1e6, MAX_DEPOSIT);
        victimSize = bound(victimSize, 1e6, MAX_DEPOSIT);

        uint256 attackerStart = usdc.balanceOf(attacker);

        // Front-run
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(attackSize, attacker);

        // Victim
        vm.prank(victim);
        vault.deposit(victimSize, victim);

        // Back-run
        vm.prank(attacker);
        IQueueModule(address(vault)).requestClaim(true, attackerShares);
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);

        uint256 attackerEnd = usdc.balanceOf(attacker);
        assertLe(attackerEnd, attackerStart + 1, "no sandwich profit");
    }

    /* ========== ACCESS CONTROL ========== */

    function test_only_owner_can_pause() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.pauseAll();

        vm.prank(owner);
        vault.pauseAll();
        assertTrue(vault.paused(), "owner can pause");
    }

    function test_only_owner_can_unpause() public {
        vm.prank(owner);
        vault.pauseAll();

        vm.prank(attacker);
        vm.expectRevert();
        vault.unpauseAll();

        vm.prank(owner);
        vault.unpauseAll();
        assertFalse(vault.paused(), "owner can unpause");
    }

    function test_only_owner_can_set_fee_params() public {
        vm.prank(attacker);
        vm.expectRevert();
        IAdminModule(address(vault)).submitFeeParams(100, 100, 0, 0, treasury);

        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(100, 100, 0, 0, treasury);
    }

    function testFuzz_random_cannot_admin(address random) public {
        vm.assume(random != owner);

        vm.prank(random);
        vm.expectRevert();
        vault.pauseAll();

        vm.prank(random);
        vm.expectRevert();
        IAdminModule(address(vault)).submitFeeParams(100, 100, 0, 0, random);

        vm.prank(random);
        vm.expectRevert();
        vault.setGuardian(random);
    }

    function test_ownership_requires_acceptance() public {
        vm.prank(owner);
        vault.beginOwnerTransfer(victim);

        assertEq(vault.owner(), owner, "still original owner");

        vm.prank(attacker);
        vm.expectRevert();
        vault.acceptOwnerTransfer();

        vm.prank(victim);
        vault.acceptOwnerTransfer();
        assertEq(vault.owner(), victim, "ownership transferred");
    }

    function test_vetoer_can_veto_pending_params() public {
        vm.prank(owner);
        IAdminModule(address(vault)).setVetoer(guardian);

        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(100, 100, 0, 0, treasury);

        vm.prank(guardian);
        IAdminModule(address(vault)).revokeFeeParams();

        // Now acceptFeeParams should fail
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        vm.expectRevert();
        IAdminModule(address(vault)).acceptFeeParams();
    }

    function test_attacker_cannot_veto() public {
        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(100, 100, 0, 0, treasury);

        vm.prank(attacker);
        vm.expectRevert();
        IAdminModule(address(vault)).revokeFeeParams();
    }

    /* ========== PAUSED STATE PROTECTION ========== */

    function test_cannot_deposit_when_paused() public {
        vm.prank(owner);
        vault.pauseAll();

        vm.prank(attacker);
        vm.expectRevert();
        vault.deposit(1e6, attacker);
    }

    function test_cannot_withdraw_when_paused() public {
        vm.prank(attacker);
        vault.deposit(1_000_000e6, attacker);

        vm.prank(owner);
        vault.pauseAll();

        vm.prank(attacker);
        vm.expectRevert();
        vault.withdraw(500_000e6, attacker, attacker);
    }

    /* ========== ACCOUNTING INVARIANTS ========== */

    /**
     * @notice Total supply always equals sum of balances
     */
    function testFuzz_supply_equals_balance_sum(uint256 d1, uint256 d2, uint256 d3) public {
        d1 = bound(d1, 1e6, MAX_DEPOSIT);
        d2 = bound(d2, 1e6, MAX_DEPOSIT);
        d3 = bound(d3, 1e6, MAX_DEPOSIT);

        vault.deposit(d1, address(this));
        vm.prank(victim);
        vault.deposit(d2, victim);
        vm.prank(attacker);
        vault.deposit(d3, attacker);

        uint256 totalSupply = vault.totalSupply();
        uint256 sumBalances =
            vault.balanceOf(address(this)) + vault.balanceOf(victim) + vault.balanceOf(attacker);

        assertEq(totalSupply, sumBalances, "supply = sum balances");
    }

    /**
     * @notice Deposit/withdraw cycle preserves value
     */
    function testFuzz_deposit_withdraw_preserves_value(uint256 amount) public {
        amount = bound(amount, 1e6, MAX_DEPOSIT);

        uint256 balanceBefore = usdc.balanceOf(attacker);

        vm.startPrank(attacker);
        uint256 shares = vault.deposit(amount, attacker);
        IQueueModule(address(vault)).requestClaim(true, shares);
        vm.stopPrank();
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);

        uint256 balanceAfter = usdc.balanceOf(attacker);

        // Max 2 wei rounding loss (balance delta ≈ 0)
        assertGe(balanceAfter, balanceBefore - 2, "max 2 wei loss");
        assertApproxEqAbs(balanceAfter, balanceBefore, 2, "balance preserved");
    }

    /**
     * @notice Multiple operations don't cause significant drift
     * @dev This test verifies accounting stays bounded, not perfectly precise.
     *      Uses user1 account to avoid interference from setUp's initial deposit.
     */
    function testFuzz_no_accounting_drift(uint256 seed) public {
        uint256 totalDeposited = 0;

        // Use user1 (fresh account) to avoid setUp's initial deposit
        vm.startPrank(user1);

        for (uint256 i = 0; i < 10; i++) {
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i))), 1e6, 10_000_000e6);
            vault.deposit(amount, user1);
            totalDeposited += amount;
        }

        uint256 shares = vault.balanceOf(user1);
        uint256 usdcBefore = usdc.balanceOf(user1);
        IQueueModule(address(vault)).requestClaim(true, shares);
        vm.stopPrank();
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);
        uint256 received = usdc.balanceOf(user1) - usdcBefore;

        // Allow 0.1% tolerance for rounding across many operations
        // (10 deposits + 1 redeem = 11 operations with share/asset conversions)
        assertApproxEqRel(received, totalDeposited, 0.001e18, "bounded drift");

        // Also verify received is never MORE than deposited (no inflation attack)
        assertLe(received, totalDeposited, "no inflation");
    }

    /* ========== DONATION HANDLING ========== */

    /**
     * @notice Donations benefit all shareholders proportionally
     */
    function testFuzz_donation_fair_distribution(
        uint256 deposit1,
        uint256 deposit2,
        uint256 donation
    ) public {
        // Use larger minimum amounts to avoid rounding to zero
        deposit1 = bound(deposit1, 1000e6, MAX_DEPOSIT);
        deposit2 = bound(deposit2, 1000e6, MAX_DEPOSIT);
        donation = bound(donation, 1000e6, 10_000_000e6);

        vault.deposit(deposit1, address(this));

        vm.prank(victim);
        vault.deposit(deposit2, victim);

        uint256 myValueBefore = vault.convertToAssets(vault.balanceOf(address(this)));
        uint256 victimValueBefore = vault.convertToAssets(vault.balanceOf(victim));

        // Donation
        vm.prank(attacker);
        usdc.transfer(address(vault), donation);

        uint256 myValueAfter = vault.convertToAssets(vault.balanceOf(address(this)));
        uint256 victimValueAfter = vault.convertToAssets(vault.balanceOf(victim));

        // Both should gain (with significant deposits, gains will be observable)
        assertGe(myValueAfter, myValueBefore, "I gained or stayed same");
        assertGe(victimValueAfter, victimValueBefore, "victim gained or stayed same");

        // Total gains should match donation
        uint256 totalGain = (myValueAfter - myValueBefore) + (victimValueAfter - victimValueBefore);
        assertApproxEqRel(totalGain, donation, 0.01e18, "donation distributed");
    }

    /* ========== DOS / GRIEFING ========== */

    function test_dust_deposits_dont_break_accounting() public {
        vm.startPrank(attacker);
        for (uint256 i = 0; i < 100; i++) {
            vault.deposit(1, attacker);
        }
        vm.stopPrank();

        uint256 totalSupply = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();

        assertGt(totalSupply, 0, "supply tracked");
        assertGt(totalAssets, 0, "assets tracked");
    }

    function test_deposit_gas_bounded() public {
        vm.prank(attacker);
        uint256 gasStart = gasleft();
        vault.deposit(1_000_000e6, attacker);
        uint256 gasUsed = gasStart - gasleft();

        assertLt(gasUsed, 500_000, "deposit gas bounded");
    }

    function test_withdraw_gas_bounded() public {
        vm.prank(attacker);
        vault.deposit(1_000_000e6, attacker);

        uint256 shares = vault.previewWithdraw(500_000e6);
        vm.prank(attacker);
        uint256 gasStart = gasleft();
        IQueueModule(address(vault)).requestClaim(true, shares);
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);
        uint256 gasUsed = gasStart - gasleft();

        assertLt(gasUsed, 2_000_000, "withdraw gas bounded");
    }

    /* ========== STATE CONSISTENCY ========== */

    function test_state_consistency_after_many_operations() public {
        for (uint256 i = 0; i < 20; i++) {
            address user = address(uint160(0x1000 + i));
            usdc._mint(user, 100_000e6);

            vm.startPrank(user);
            usdc.approve(address(vault), type(uint256).max);
            vault.deposit(100_000e6, user);

            if (i % 2 == 0) {
                uint256 sh = vault.previewWithdraw(50_000e6);
                IQueueModule(address(vault)).requestClaim(false, sh);
            }
            vm.stopPrank();
            if (i % 2 == 0) {
                IQueueModule(address(vault)).settleFeesAndProcessQueue(1);
            }
        }

        uint256 totalSupply = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();

        assertGt(totalSupply, 0, "supply after stress");
        assertGt(totalAssets, 0, "assets after stress");

        // Price should be reasonable
        uint256 price = totalAssets * 1e6 / totalSupply;
        assertApproxEqRel(price, 1e6, 0.05e18, "price stable after stress");
    }

    /* ========== ZERO VALUE PROTECTION ========== */

    function test_cannot_deposit_zero() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.deposit(0, attacker);
    }

    function test_cannot_mint_zero() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.mint(0, attacker);
    }

    /* ========== PRIVILEGE ESCALATION ========== */

    function test_deposit_grants_no_privileges() public {
        vm.startPrank(attacker);
        vault.deposit(MAX_DEPOSIT, attacker);

        vm.expectRevert();
        vault.pauseAll();

        vm.expectRevert();
        vault.setGuardian(attacker);

        vm.expectRevert();
        IAdminModule(address(vault)).submitFeeParams(0, 0, 0, 0, attacker);

        vm.stopPrank();
    }
}
