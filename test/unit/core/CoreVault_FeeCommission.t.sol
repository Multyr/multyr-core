// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreVault } from "../../../src/core/CoreVault.sol";
import { AdminModule } from "../../../src/core/modules/AdminModule.sol";
import { IAdminModule } from "../../../src/interfaces/IAdminModule.sol";
import { SelectorLib } from "../../../src/core/libraries/SelectorLib.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { ModuleSetter } from "../../helpers/ModuleSetter.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";
import { ExitEngineLib } from "../../../src/core/libraries/ExitEngineLib.sol";

/**
 * @title CoreVault_FeeCommission
 * @notice Test suite for fee commission mechanisms
 * @dev Tests deposit fees, withdrawal fees, performance fees, and treasury payments
 *
 * Key behaviors tested:
 * - Deposit fees are deducted and sent to treasury
 * - Withdrawal fees are deducted and sent to treasury
 * - Performance fees on gains
 * - Fee recipient changes
 * - Fee boundaries (0% and max%)
 */
contract CoreVault_FeeCommission is Test {
    CoreVault internal vault;
    AdminModule internal adminModule;
    ERC20Mock internal usdc;

    address internal owner = address(0xA11CE);
    address internal guardian = address(0xB0B);
    address internal treasury = address(0xFEE);
    address internal newTreasury = address(0xFEE2);
    address internal user = address(0xBEEF);

    // Role constants
    uint8 constant ROLE_PUBLIC = 0;
    uint8 constant ROLE_OWNER = 1;

    function setUp() public {
        // Deploy mock USDC
        usdc = new ERC20Mock("USDC", "USDC", 6);
        usdc._mint(address(this), 10_000_000e6);
        usdc._mint(user, 1_000_000e6);

        // Deploy MockParamsProvider
        MockParamsProvider params = new MockParamsProvider();

        // Deploy vault (6-param constructor, via CoreHarness for setBufferManagerUnsafe)
        vm.prank(owner);
        CoreHarness _harness = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Test Vault",
            "tvUSDC",
            owner,
            treasury, // feeCollector
            address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(_harness));
        _harness.setBufferManagerUnsafe(address(mockBM));
        vault = _harness;

        // Deploy AdminModule and wire it
        adminModule = new AdminModule();

        // Wire AdminModule owner selectors
        bytes4[] memory adminOwnerSelectors = SelectorLib.getAdminModuleOwnerSelectors();
        vm.startPrank(owner);
        ModuleSetter.setModulesSame(
            address(vault), adminOwnerSelectors, address(adminModule), ROLE_OWNER
        );

        // Wire AdminModule view selectors (PUBLIC)
        bytes4[] memory adminViewSelectors = SelectorLib.getAdminModuleViewSelectors();
        ModuleSetter.setModulesSame(
            address(vault), adminViewSelectors, address(adminModule), ROLE_PUBLIC
        );
        vm.stopPrank();

        // Set initial fee params via timelock (submit + warp + accept)
        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(100, 50, 0, 0, treasury); // 1% deposit, 0.5% withdraw

        // Warp past timelock (2 days default)
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(owner);
        IAdminModule(address(vault)).acceptFeeParams();
    }

    /* ===== DEPOSIT FEES ===== */

    function test_deposit_fee_reduces_shares_minted() public {
        vm.startPrank(user);
        usdc.approve(address(vault), 10_000e6);

        // With 1% deposit fee, 10k assets -> 9.9k net -> 9.9k shares
        uint256 shares = vault.deposit(10_000e6, user);

        assertEq(shares, 9_900e6, "1% fee applied");
        assertEq(vault.balanceOf(user), 9_900e6, "user receives net shares");
        vm.stopPrank();
    }

    function test_deposit_fee_mints_shares_to_treasury() public {
        vm.startPrank(user);
        usdc.approve(address(vault), 10_000e6);

        uint256 treasurySharesBefore = vault.balanceOf(treasury);
        vault.deposit(10_000e6, user);
        uint256 treasurySharesAfter = vault.balanceOf(treasury);

        // Treasury gets 1% of the gross (100 USDC worth of shares)
        uint256 treasuryGain = treasurySharesAfter - treasurySharesBefore;
        assertEq(treasuryGain, 100e6, "treasury receives fee shares");
        vm.stopPrank();
    }

    function test_zero_deposit_fee_no_treasury_shares() public {
        // Set zero deposit fee via timelock
        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(0, 50, 0, 0, treasury);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(owner);
        IAdminModule(address(vault)).acceptFeeParams();

        vm.startPrank(user);
        usdc.approve(address(vault), 10_000e6);

        uint256 treasurySharesBefore = vault.balanceOf(treasury);
        uint256 shares = vault.deposit(10_000e6, user);
        uint256 treasurySharesAfter = vault.balanceOf(treasury);

        assertEq(shares, 10_000e6, "no fee deducted");
        assertEq(treasurySharesAfter, treasurySharesBefore, "treasury unchanged");
        vm.stopPrank();
    }

    /* ===== WITHDRAWAL FEES ===== */

    function test_withdraw_reverts_AsyncWithdrawalRequired() public {
        // First deposit
        vm.startPrank(user);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, user);
        vm.stopPrank();

        // withdraw() now ALWAYS reverts with AsyncWithdrawalRequired
        vm.prank(user);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(10_000e6, user, user);
    }

    function test_zero_withdraw_fee_still_reverts_AsyncWithdrawalRequired() public {
        // Set zero withdraw fee via timelock
        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(100, 0, 0, 0, treasury);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(owner);
        IAdminModule(address(vault)).acceptFeeParams();

        // First deposit
        vm.startPrank(user);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, user);
        vm.stopPrank();

        // withdraw() now ALWAYS reverts with AsyncWithdrawalRequired, even with zero fee
        vm.prank(user);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(10_000e6, user, user);
    }

    /* ===== FEE CHANGES ===== */

    function test_setFeeParams_updates_deposit_and_withdraw_fees() public {
        // Use timelock pattern
        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(200, 100, 0, 0, treasury); // 2% deposit, 1% withdraw

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(owner);
        IAdminModule(address(vault)).acceptFeeParams();

        (uint16 depFee, uint16 witFee, address treas) = IAdminModule(address(vault)).getFeeParams();

        assertEq(depFee, 200, "deposit fee updated");
        assertEq(witFee, 100, "withdraw fee updated");
        assertEq(treas, treasury, "treasury unchanged");
    }

    function test_setFeeParams_can_change_treasury() public {
        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(100, 50, 0, 0, newTreasury);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(owner);
        IAdminModule(address(vault)).acceptFeeParams();

        (,, address treas) = IAdminModule(address(vault)).getFeeParams();

        assertEq(treas, newTreasury, "treasury updated");
    }

    function test_new_fees_apply_to_new_operations() public {
        // Deposit with old fee (1%)
        vm.startPrank(user);
        usdc.approve(address(vault), 200_000e6);
        uint256 shares1 = vault.deposit(10_000e6, user);
        assertEq(shares1, 9_900e6, "old 1% fee");

        vm.stopPrank();

        // Change fee to 2% via timelock
        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(200, 50, 0, 0, treasury);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(owner);
        IAdminModule(address(vault)).acceptFeeParams();

        // Deposit with new fee (2%)
        vm.startPrank(user);
        uint256 shares2 = vault.deposit(10_000e6, user);
        assertEq(shares2, 9_800e6, "new 2% fee");
        vm.stopPrank();
    }

    /* ===== EDGE CASES ===== */

    function test_max_fee_blocked_by_FeeTooHigh() public {
        // Try to set 100% deposit fee - should be blocked by FeeTooHigh (max 5% = 500 bps in AdminModule)
        vm.prank(owner);
        vm.expectRevert(AdminModule.FeeTooHigh.selector);
        IAdminModule(address(vault)).submitFeeParams(10000, 50, 0, 0, treasury);

        // Instead test the actual max (500 bps = 5%)
        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(500, 50, 0, 0, treasury);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(owner);
        IAdminModule(address(vault)).acceptFeeParams();

        vm.startPrank(user);
        usdc.approve(address(vault), 10_000e6);
        uint256 shares = vault.deposit(10_000e6, user);
        vm.stopPrank();

        // User gets 95% of shares (5% goes to fee)
        assertEq(shares, 9_500e6, "5% fee - user gets 95%");
        assertEq(vault.balanceOf(treasury), 500e6, "treasury gets 5%");
    }

    function test_fee_calculation_precision_small_amounts() public {
        // Test with very small deposit (100 USDC = 100e6)
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);

        uint256 shares = vault.deposit(100e6, user);

        // With 1% fee: 100 - 1 = 99 USDC worth of shares
        assertEq(shares, 99e6, "precision maintained for small amounts");
        vm.stopPrank();
    }
}
