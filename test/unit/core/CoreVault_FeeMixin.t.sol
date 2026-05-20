// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { CoreVault } from "../../../src/core/CoreVault.sol";
import { AdminModule } from "../../../src/core/modules/AdminModule.sol";
import { QueueModule } from "../../../src/core/modules/QueueModule.sol";
import { IAdminModule } from "../../../src/interfaces/IAdminModule.sol";
import { IQueueModule } from "../../../src/interfaces/IQueueModule.sol";
import { SelectorLib } from "../../../src/core/libraries/SelectorLib.sol";
import { MockUSDC } from "../../helpers/MockUSDC.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { ModuleSetter } from "../../helpers/ModuleSetter.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Events } from "../../../src/core/libraries/Events.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";

/**
 * @title CoreVault_FeeMixin Additional Tests
 * @notice Critical edge case tests for fee handling in new modular CoreVault
 * @dev Tests fee params via AdminModule timelock pattern
 */
contract CoreVaultFeeMixinTest is Test {
    CoreVault public vault;
    AdminModule public adminModule;
    QueueModule public queueModule;
    MockUSDC public usdc;
    address public vaultAddr;

    address public owner = address(0xA11CE);
    address public guardian = address(0xB0B);
    address public treasury = address(0xFEE);
    address public newTreasury = address(0xFEE2);
    address public user = address(0x1234);

    // Role constants
    uint8 constant ROLE_PUBLIC = 0;
    uint8 constant ROLE_OWNER = 1;

    function setUp() public {
        usdc = new MockUSDC();

        // Deploy MockParamsProvider
        MockParamsProvider params = new MockParamsProvider();

        // Deploy vault with 6-param constructor (via CoreHarness for setBufferManagerUnsafe)
        vm.prank(owner);
        CoreHarness _harness = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "VaultUSDC",
            "vUSDC",
            owner,
            treasury, // feeCollector
            address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(_harness));
        _harness.setBufferManagerUnsafe(address(mockBM));
        vault = _harness;
        vaultAddr = address(vault);

        // Deploy AdminModule and QueueModule
        adminModule = new AdminModule();
        queueModule = new QueueModule();

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

        // Wire QueueModule selectors (PUBLIC)
        bytes4[] memory queueSels = SelectorLib.getQueueModuleSelectors();
        ModuleSetter.setModulesSame(
            vaultAddr, queueSels, address(queueModule), ROLE_PUBLIC
        );
        // Bootstrap paramMinDelay from 0 to 2 days (accept works immediately when delay=0)
        IAdminModule(address(vault)).submitMinDelay(2 days);
        IAdminModule(address(vault)).acceptMinDelay();
        vm.stopPrank();

        // Set initial fee params via timelock (submit + warp + accept)
        // 1% deposit (100 bps), 0.5% withdraw (50 bps)
        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(100, 50, 0, 0, treasury);

        // Warp past timelock (2 days default)
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(owner);
        IAdminModule(address(vault)).acceptFeeParams();

        // Fund user
        usdc.mint(user, 10_000_000e6);
    }

    /// @notice Helper to submit and accept fee params via timelock
    function _setFeeParams(uint16 depBps, uint16 witBps, address treas) internal {
        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(depBps, witBps, 0, 0, treas);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(owner);
        IAdminModule(address(vault)).acceptFeeParams();
    }

    /// @notice Test 1: Verify submitFeeParams reverts when fees exceed MAX_FEE_BPS (500 = 5%)
    function test_fee_submitFeeParams_above_max_reverts() public {
        // Try to set withdraw fee > 5% (500 bps) - AdminModule MAX_FEE_BPS
        vm.prank(owner);
        vm.expectRevert(AdminModule.FeeTooHigh.selector);
        IAdminModule(address(vault)).submitFeeParams(100, 501, 0, 0, treasury);

        // Verify unchanged
        (uint16 dep, uint16 wit, address treas) = IAdminModule(address(vault)).getFeeParams();
        assertEq(dep, 100, "Deposit fee should remain unchanged");
        assertEq(wit, 50, "Withdraw fee should remain unchanged");
        assertEq(treas, treasury, "Treasury should remain unchanged");
    }

    /// @notice Test 2: Verify submitFeeParams reverts when depositFeeBps > MAX_FEE_BPS
    function test_fee_submitFeeParams_deposit_bps_gt_max_reverts() public {
        // Try to set deposit fee > 5% (500 bps)
        vm.prank(owner);
        vm.expectRevert(AdminModule.FeeTooHigh.selector);
        IAdminModule(address(vault)).submitFeeParams(501, 50, 0, 0, treasury);

        // Verify unchanged
        (uint16 dep, uint16 wit,) = IAdminModule(address(vault)).getFeeParams();
        assertEq(dep, 100, "Deposit fee should remain unchanged");
        assertEq(wit, 50, "Withdraw fee should remain unchanged");
    }

    /// @notice Test 3: Verify FeeParamsSubmitted event is emitted
    function test_fee_FeeParamsSubmitted_event_emitted() public {
        uint16 newDep = 200;
        uint16 newWit = 150;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        // paramMinDelay bootstrapped to 2 days in setUp
        emit Events.FeeParamsSubmitted(newDep, newWit, treasury, uint64(block.timestamp + 2 days));

        IAdminModule(address(vault)).submitFeeParams(newDep, newWit, 0, 0, treasury);
    }

    /// @notice Test 4: Verify fee rounding on tiny amounts (deposit)
    function test_fee_rounding_edge_cases_tiny_deposit_amounts() public {
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000_000e6);

        // Test with 1 USDC (1e6)
        // 1% of 1e6 = 10_000 (0.01 USDC)
        // Should NOT round down to zero
        uint256 shares1 = vault.deposit(1e6, user);
        assertGt(shares1, 0, "Should receive shares even on tiny deposit");
        assertLt(shares1, 1e6, "Fee should be deducted");

        // Test with 10 USDC (10e6)
        // 1% of 10e6 = 100_000 (0.1 USDC)
        uint256 balBefore = vault.balanceOf(user);
        uint256 shares2 = vault.deposit(10e6, user);
        uint256 expectedNet = 10e6 - (10e6 * 100 / 10000); // 9.9e6
        assertEq(shares2, expectedNet, "Fee calculation should be precise");
        assertEq(vault.balanceOf(user) - balBefore, shares2, "User should receive net shares");

        vm.stopPrank();
    }

    /// @notice Test 5: Verify fee rounding on tiny amounts (withdraw via requestClaim)
    /// @dev withdraw() always reverts with AsyncWithdrawalRequired, so we use requestClaim.
    ///      Fee is observable via share transfer to feeCollector.
    function test_fee_rounding_edge_cases_tiny_withdraw_amounts() public {
        // Deposit first
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1000e6, user);

        // Withdraw ~1 USDC worth of shares with 0.5% fee via requestClaim
        uint256 shares = vault.previewWithdraw(1e6);
        uint256 assetsBefore = usdc.balanceOf(user);
        uint256 feeSharesBefore = vault.balanceOf(treasury);

        IQueueModule(vaultAddr).requestClaim(true, shares);
        uint256 assetsReceived = usdc.balanceOf(user) - assetsBefore;
        uint256 feeSharesAfter = vault.balanceOf(treasury);

        // User receives assets (less fee deducted from shares)
        assertGt(assetsReceived, 0, "user should receive assets");

        // Fee shares transferred to treasury
        assertGe(feeSharesAfter, feeSharesBefore, "fee shares should not decrease");

        vm.stopPrank();
    }

    /// @notice Test 6: Verify fee params with both fees at max (500 bps = 5% in AdminModule)
    function test_fee_setFeeParams_both_at_max_succeeds() public {
        _setFeeParams(500, 500, treasury);

        (uint16 dep, uint16 wit,) = IAdminModule(address(vault)).getFeeParams();
        assertEq(dep, 500, "Deposit fee should be at max");
        assertEq(wit, 500, "Withdraw fee should be at max");

        // Verify 5% fee actually applies
        vm.startPrank(user);
        usdc.approve(address(vault), 10_000e6);
        uint256 shares = vault.deposit(10_000e6, user);
        assertEq(shares, 9_500e6, "5% deposit fee applied");

        vm.stopPrank();
    }

    /// @notice Test 7: Verify treasury can be changed via timelock
    function test_fee_treasury_can_be_changed() public {
        (uint16 depBefore, uint16 witBefore, address treasBefore) =
            IAdminModule(address(vault)).getFeeParams();
        assertEq(treasBefore, treasury, "Treasury should be set initially");

        // Change treasury via timelock
        _setFeeParams(depBefore, witBefore, newTreasury);

        (,, address treasAfter) = IAdminModule(address(vault)).getFeeParams();
        assertEq(treasAfter, newTreasury, "Treasury should be updated");
    }

    /// @notice Test 8: Verify zero fees work correctly
    function test_fee_zero_fees_no_treasury_minted() public {
        // Set zero fees
        _setFeeParams(0, 0, treasury);

        vm.startPrank(user);
        usdc.approve(address(vault), 10_000e6);

        uint256 treasurySharesBefore = vault.balanceOf(treasury);
        uint256 shares = vault.deposit(10_000e6, user);

        // No fee deducted
        assertEq(shares, 10_000e6, "No deposit fee");
        assertEq(vault.balanceOf(treasury), treasurySharesBefore, "Treasury unchanged");

        // Withdraw with zero fee via requestClaim
        uint256 sharesToClaim = vault.previewWithdraw(1_000e6);
        uint256 assetsBefore = usdc.balanceOf(user);
        uint256 treasurySharesMid = vault.balanceOf(treasury);
        IQueueModule(vaultAddr).requestClaim(true, sharesToClaim);
        uint256 assetsReceived = usdc.balanceOf(user) - assetsBefore;

        assertEq(assetsReceived, 1_000e6, "No withdraw fee");
        assertEq(vault.balanceOf(treasury), treasurySharesMid, "Treasury unchanged after withdraw");

        vm.stopPrank();
    }

    /// @notice Test 9: Fuzz test - fee BPS values within valid range (0-500)
    function testFuzz_fee_submitFeeParams_valid_range(uint16 depBps, uint16 witBps) public {
        // Use bound to limit to valid range (AdminModule MAX_FEE_BPS = 500)
        depBps = uint16(bound(depBps, 0, 500));
        witBps = uint16(bound(witBps, 0, 500));

        _setFeeParams(depBps, witBps, treasury);

        (uint16 dep, uint16 wit,) = IAdminModule(address(vault)).getFeeParams();
        assertEq(dep, depBps, "Deposit fee should match");
        assertEq(wit, witBps, "Withdraw fee should match");
    }

    /// @notice Test 10: Fuzz test - fee BPS values above 500 always revert
    function testFuzz_fee_submitFeeParams_above_cap_reverts(uint16 depBps, uint16 witBps) public {
        vm.assume(depBps > 500 || witBps > 500);

        vm.prank(owner);
        vm.expectRevert(AdminModule.FeeTooHigh.selector);
        IAdminModule(address(vault)).submitFeeParams(depBps, witBps, 0, 0, treasury);
    }

    /// @notice Test 11: Verify timelock must pass before accepting fee params
    /// @dev Skipped: paramMinDelay=0 in shadow deploy, so eta=block.timestamp and accept works immediately.
    ///      Timelock enforcement is tested in AdminModule-specific tests with nonzero delay.
    function test_fee_timelock_must_pass() public {
        // Submit new fee params
        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(200, 100, 0, 0, treasury);

        // Accept before eta should revert
        vm.prank(owner);
        vm.expectRevert();
        IAdminModule(address(vault)).acceptFeeParams();

        // Warp past timelock
        vm.warp(block.timestamp + 2 days + 1);

        // Now accept succeeds
        vm.prank(owner);
        IAdminModule(address(vault)).acceptFeeParams();
    }

    /// @notice Test 12: Verify pending fee params can be revoked
    function test_fee_pending_params_can_be_revoked() public {
        // Get initial params
        (uint16 initialDep, uint16 initialWit, address initialTreas) =
            IAdminModule(address(vault)).getFeeParams();

        // Submit new params
        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(300, 200, 0, 0, newTreasury);

        // Verify pending exists
        (,,,, bool exists) = IAdminModule(address(vault)).getPendingFeeParams();
        assertTrue(exists, "Pending params should exist");

        // Revoke
        vm.prank(owner);
        IAdminModule(address(vault)).revokeFeeParams();

        // Verify pending cleared
        (,,,, exists) = IAdminModule(address(vault)).getPendingFeeParams();
        assertFalse(exists, "Pending params should be cleared");

        // Verify original params unchanged
        (uint16 dep, uint16 wit, address treas) = IAdminModule(address(vault)).getFeeParams();
        assertEq(dep, initialDep, "Deposit fee unchanged");
        assertEq(wit, initialWit, "Withdraw fee unchanged");
        assertEq(treas, initialTreas, "Treasury unchanged");
    }

    /// @notice Test 13: Verify timelock window expiration
    function test_fee_timelock_window_expires() public {
        vm.prank(owner);
        IAdminModule(address(vault)).submitFeeParams(200, 100, 0, 0, treasury);

        // Warp past timelock AND past the max window (7 days)
        vm.warp(block.timestamp + 2 days + 7 days + 1);

        // Accept should fail (window expired)
        vm.prank(owner);
        vm.expectRevert(AdminModule.EtaExpired.selector);
        IAdminModule(address(vault)).acceptFeeParams();
    }
}
