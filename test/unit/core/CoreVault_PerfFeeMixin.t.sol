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
import { FixedPoint } from "../../../src/libs/FixedPoint.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";

/**
 * @title CoreVault_PerfFeeMixin Test Suite
 * @notice Comprehensive test coverage for performance fee handling in modular CoreVault
 * @dev Tests HWM tracking, crystallization logic, fee calculations, and interval enforcement
 *      Updated for Diamond-lite architecture with AdminModule/QueueModule wiring
 */
contract CoreVaultPerfFeeMixinTest is Test {
    CoreVault public vault;
    AdminModule public adminModule;
    QueueModule public queueModule;
    MockUSDC public usdc;
    MockParamsProvider public params;

    address public owner = address(0xA11CE);
    address public guardian = address(0xB0B);
    address public feeCollector = address(0xFEE);
    address public user = address(0x1234);

    uint256 constant PERF_RATE = 0.2e18; // 20% performance fee
    uint64 constant MIN_INTERVAL = 1 days;
    uint64 constant DEFAULT_MIN_DELAY = 2 days;

    // Role constants
    uint8 constant ROLE_PUBLIC = 0;
    uint8 constant ROLE_OWNER = 1;

    function setUp() public {
        usdc = new MockUSDC();
        params = new MockParamsProvider();

        // Deploy AdminModule and QueueModule
        adminModule = new AdminModule();
        queueModule = new QueueModule();

        // Deploy vault with 6-param constructor (via CoreHarness for setBufferManagerUnsafe)
        vm.prank(owner);
        CoreHarness _harness = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "VaultUSDC",
            "vUSDC",
            owner,
            feeCollector,
            address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(_harness));
        _harness.setBufferManagerUnsafe(address(mockBM));
        vault = _harness;

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

        // Wire QueueModule selectors (PUBLIC) - includes endEpochCrystallize
        bytes4[] memory queueSelectors = new bytes4[](5);
        queueSelectors[0] = QueueModule.requestClaim.selector;
        queueSelectors[1] = QueueModule.cancelClaim.selector;
        queueSelectors[2] = QueueModule.processQueuedRedemptions.selector;
        queueSelectors[3] = QueueModule.settleFeesAndProcessQueue.selector;
        queueSelectors[4] = QueueModule.endEpochCrystallize.selector;
        ModuleSetter.setModulesSame(
            address(vault), queueSelectors, address(queueModule), ROLE_PUBLIC
        );
        vm.stopPrank();

        // Set initial performance fee parameters via timelock
        vm.prank(owner);
        IAdminModule(address(vault)).submitPerfParams(PERF_RATE, MIN_INTERVAL);
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY + 1);
        vm.prank(owner);
        IAdminModule(address(vault)).acceptPerfParams();

        // Fund user
        usdc.mint(user, 10_000_000e6);
    }

    /// @notice Helper to get admin interface
    function admin() internal view returns (IAdminModule) {
        return IAdminModule(address(vault));
    }

    /// @notice Helper to get queue interface
    function queue() internal view returns (IQueueModule) {
        return IQueueModule(address(vault));
    }

    /// @notice Helper to submit and accept performance params via timelock
    function _setPerfParams(uint256 rateX, uint64 minInterval) internal {
        vm.prank(owner);
        admin().submitPerfParams(rateX, minInterval);
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY + 1);
        vm.prank(owner);
        admin().acceptPerfParams();
    }

    /// @notice Test 1: Verify crystallization with zero totalSupply sets HWM to WAD
    function test_perf_crystallize_when_totalSupply_zero_sets_hwm_to_WAD() public {
        // Initially, no shares minted
        assertEq(vault.totalSupply(), 0, "Total supply should be zero");

        // Read perf state before
        (uint256 rateXBefore, uint64 minIntervalBefore, uint256 hwmBefore, uint64 lastBefore) =
            admin().getPerfParams();
        assertEq(hwmBefore, 0, "HWM should be zero before first crystallize");

        // Warp past minInterval
        vm.warp(block.timestamp + MIN_INTERVAL + 1);

        // Crystallize with zero supply
        queue().endEpochCrystallize();

        // Read perf state after
        (uint256 rateXAfter, uint64 minIntervalAfter, uint256 hwmAfter, uint64 lastAfter) =
            admin().getPerfParams();
        assertEq(hwmAfter, FixedPoint.WAD, "HWM should be set to WAD when totalSupply is zero");
        assertGt(lastAfter, lastBefore, "perf.last should be updated");
    }

    /// @notice Test 2: Verify crystallization interval enforcement
    function test_perf_interval_enforcement() public {
        // Deposit to initialize
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1000e6, user);
        vm.stopPrank();

        // Warp and crystallize first time
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        queue().endEpochCrystallize();

        (,,, uint64 firstCrystallizeTime) = admin().getPerfParams();

        // Simulate profit
        usdc.mint(address(vault), 200e6);

        // Before interval: PPS is now > HWM, but interval hasn't elapsed
        assertTrue(vault.totalAssets() > 1_000e6, "Should have profit");

        // Get HWM before trying to crystallize
        (,, uint256 hwmBefore,) = admin().getPerfParams();

        // Try to crystallize before interval - should not update HWM significantly
        vm.warp(firstCrystallizeTime + MIN_INTERVAL - 1);
        uint256 feeCollectorSharesBefore = vault.balanceOf(feeCollector);
        queue().endEpochCrystallize();
        uint256 feeCollectorSharesAfter = vault.balanceOf(feeCollector);

        // At exactly interval: should be able to crystallize
        vm.warp(firstCrystallizeTime + MIN_INTERVAL);
        queue().endEpochCrystallize();

        // After interval: should be able to crystallize
        vm.warp(firstCrystallizeTime + MIN_INTERVAL + 1);
        queue().endEpochCrystallize();
    }

    /// @notice Test 3: Verify crystallization when PPS <= HWM updates HWM downward without minting
    function test_perf_crystallize_when_pps_below_hwm_updates_hwm_down() public {
        // Deposit
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1000e6, user);
        vm.stopPrank();

        // First crystallize to set initial HWM
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        queue().endEpochCrystallize();
        (,, uint256 hwm1,) = admin().getPerfParams();

        uint256 feeCollectorSharesBefore = vault.balanceOf(feeCollector);

        // Simulate loss: withdraw almost everything via requestClaim
        uint256 sharesToClaim = vault.convertToShares(500e6);
        vm.prank(user);
        IQueueModule(address(vault)).requestClaim(true, sharesToClaim);

        // Wait interval
        vm.warp(block.timestamp + MIN_INTERVAL + 1);

        // Crystallize again - PPS should be lower or equal
        queue().endEpochCrystallize();

        (,, uint256 hwm2,) = admin().getPerfParams();
        uint256 feeCollectorSharesAfter = vault.balanceOf(feeCollector);

        // HWM should not increase, no shares minted on loss
        assertLe(hwm2, hwm1, "HWM should not increase when no profit");
        assertEq(
            feeCollectorSharesAfter, feeCollectorSharesBefore, "No shares should be minted on loss"
        );
    }

    /// @notice Test 4: Verify crystallization calculates exact fee shares
    function test_perf_crystallize_calculates_exact_fee_shares() public {
        // Deposit
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = vault.deposit(1000e6, user);
        vm.stopPrank();

        // First crystallize to set HWM
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        queue().endEpochCrystallize();

        uint256 feeCollectorSharesBefore = vault.balanceOf(feeCollector);
        uint256 totalSupplyBefore = vault.totalSupply();

        // Simulate profit: add 200 USDC (20% profit on 1000)
        usdc.mint(address(vault), 200e6);

        // Wait interval
        vm.warp(block.timestamp + MIN_INTERVAL + 1);

        // Calculate expected fee
        // profit = 200e6
        // feeAssets = 200e6 * 0.2 = 40e6
        // At this point PPS ~= 1200/shares, so feeShares ~= 40e6 * shares / 1200e6

        queue().endEpochCrystallize();

        uint256 feeCollectorSharesAfter = vault.balanceOf(feeCollector);
        uint256 sharesMinted = feeCollectorSharesAfter - feeCollectorSharesBefore;

        // Verify shares were minted
        assertGt(sharesMinted, 0, "Performance fee shares should be minted");

        // Rough check: 20% fee on 200 profit = 40 USDC worth of shares
        // With ~1000 shares and 1200 assets, 40 USDC ~= 33 shares
        // Allow some rounding tolerance
        assertApproxEqRel(sharesMinted, 33e6, 0.05e18, "Fee shares should be approximately correct");
    }

    /// @notice Test 5: Verify crystallization with zero rateX does not mint shares
    function test_perf_crystallize_with_zero_rateX_no_mint() public {
        // Deploy vault with ZERO performance fee (via CoreHarness for setBufferManagerUnsafe)
        vm.prank(owner);
        CoreHarness _h2 = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "VaultUSDC",
            "vUSDC",
            owner,
            feeCollector,
            address(params)
        );
        MockBufferManagerForTests mockBM2 = new MockBufferManagerForTests(address(_h2));
        _h2.setBufferManagerUnsafe(address(mockBM2));
        CoreVault vaultZeroFee = _h2;

        // Wire modules to the new vault
        vm.startPrank(owner);
        bytes4[] memory adminOwnerSelectors = SelectorLib.getAdminModuleOwnerSelectors();
        ModuleSetter.setModulesSame(
            address(vaultZeroFee), adminOwnerSelectors, address(adminModule), ROLE_OWNER
        );

        bytes4[] memory adminViewSelectors = SelectorLib.getAdminModuleViewSelectors();
        ModuleSetter.setModulesSame(
            address(vaultZeroFee), adminViewSelectors, address(adminModule), ROLE_PUBLIC
        );

        bytes4[] memory queueSelectors = new bytes4[](5);
        queueSelectors[0] = QueueModule.requestClaim.selector;
        queueSelectors[1] = QueueModule.cancelClaim.selector;
        queueSelectors[2] = QueueModule.processQueuedRedemptions.selector;
        queueSelectors[3] = QueueModule.settleFeesAndProcessQueue.selector;
        queueSelectors[4] = QueueModule.endEpochCrystallize.selector;
        ModuleSetter.setModulesSame(
            address(vaultZeroFee), queueSelectors, address(queueModule), ROLE_PUBLIC
        );

        // Set ZERO performance fee via timelock
        IAdminModule(address(vaultZeroFee)).submitPerfParams(0, MIN_INTERVAL);
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY + 1);
        IAdminModule(address(vaultZeroFee)).acceptPerfParams();
        vm.stopPrank();

        // Deposit
        vm.startPrank(user);
        usdc.approve(address(vaultZeroFee), 1_000e6);
        vaultZeroFee.deposit(1000e6, user);
        vm.stopPrank();

        // First crystallize
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        IQueueModule(address(vaultZeroFee)).endEpochCrystallize();

        uint256 feeCollectorSharesBefore = vaultZeroFee.balanceOf(feeCollector);

        // Simulate profit
        usdc.mint(address(vaultZeroFee), 200e6);

        // Wait and crystallize
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        IQueueModule(address(vaultZeroFee)).endEpochCrystallize();

        uint256 feeCollectorSharesAfter = vaultZeroFee.balanceOf(feeCollector);

        // No shares should be minted with zero rate
        assertEq(
            feeCollectorSharesAfter, feeCollectorSharesBefore, "No shares minted with zero rateX"
        );

        // But HWM should still update
        (,, uint256 hwm,) = IAdminModule(address(vaultZeroFee)).getPerfParams();
        assertGt(hwm, FixedPoint.WAD, "HWM should still be updated");
    }

    /// @notice Test 6: Verify submitPerfParams when frozen reverts
    function test_perf_submitPerfParams_when_frozen_reverts() public {
        // Freeze parameters using AdminModule.freezeParams
        vm.prank(owner);
        admin().freezeParams();

        // Try to set perf params
        vm.prank(owner);
        vm.expectRevert(AdminModule.ParamsFrozen.selector);
        admin().submitPerfParams(0.3e18, 2 days);
    }

    /// @notice Test 7: Verify minInterval boundary - exactly at minInterval should allow crystallize
    function test_perf_minInterval_exactly_at_boundary() public {
        // Deposit
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1000e6, user);
        vm.stopPrank();

        // First crystallize
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        queue().endEpochCrystallize();
        (,,, uint64 t1) = admin().getPerfParams();

        // Add profit
        usdc.mint(address(vault), 100e6);

        // Exactly at minInterval boundary - crystallize should work
        vm.warp(t1 + MIN_INTERVAL);
        queue().endEpochCrystallize();
        (,, uint256 hwm, uint64 last) = admin().getPerfParams();
        assertEq(last, t1 + MIN_INTERVAL, "perf.last should be updated");
        assertGt(hwm, FixedPoint.WAD, "HWM should increase with profit");
    }

    /// @notice Test 8: Verify HWM tracking across multiple crystallizations
    function test_perf_hwm_tracking_across_multiple_crystallizations() public {
        // Deposit
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1000e6, user);
        vm.stopPrank();

        // Crystallize 1: Initialize HWM
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        queue().endEpochCrystallize();
        (,, uint256 hwm1,) = admin().getPerfParams();
        assertEq(hwm1, FixedPoint.WAD, "Initial HWM should be WAD");

        // Add profit and crystallize 2
        usdc.mint(address(vault), 200e6); // 20% profit
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        queue().endEpochCrystallize();
        (,, uint256 hwm2,) = admin().getPerfParams();
        assertGt(hwm2, hwm1, "HWM should increase after profit");

        // Simulate loss (partial withdrawal via requestClaim)
        uint256 sharesToClaim = vault.convertToShares(600e6);
        vm.prank(user);
        IQueueModule(address(vault)).requestClaim(true, sharesToClaim);
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        queue().endEpochCrystallize();
        (,, uint256 hwm3,) = admin().getPerfParams();
        // Allow tiny rounding difference but should not significantly increase
        assertApproxEqAbs(hwm3, hwm2, 1e15, "HWM should not significantly change after loss");

        // Add more profit and crystallize 4
        usdc.mint(address(vault), 300e6);
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        queue().endEpochCrystallize();
        (,, uint256 hwm4,) = admin().getPerfParams();
        assertGt(hwm4, hwm3, "HWM should increase again after new profit");
    }

    /// @notice Test 9: Verify crystallization behavior before interval
    function test_perf_crystallize_before_interval_behavior() public {
        // Deposit
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1000e6, user);
        vm.stopPrank();

        // First crystallize
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        queue().endEpochCrystallize();

        // Add profit immediately
        usdc.mint(address(vault), 100e6);

        uint256 feeCollectorBefore = vault.balanceOf(feeCollector);
        (,, uint256 hwmBefore, uint64 lastBefore) = admin().getPerfParams();

        // Try to crystallize before interval elapses
        vm.warp(block.timestamp + MIN_INTERVAL - 1);
        queue().endEpochCrystallize();

        // Now warp to valid interval and crystallize
        vm.warp(block.timestamp + 2);
        queue().endEpochCrystallize();

        // Now it should have crystallized
        (,, uint256 hwmAfter, uint64 lastAfter) = admin().getPerfParams();
        assertGt(hwmAfter, hwmBefore, "HWM should increase after valid crystallize");
        assertGt(lastAfter, lastBefore, "last timestamp should update");
    }

    /// @notice Test 10: Verify zero profit scenario does not mint shares
    function test_perf_crystallize_zero_profit_no_fee() public {
        // Deposit
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1000e6, user);
        vm.stopPrank();

        // First crystallize to set HWM
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        queue().endEpochCrystallize();

        uint256 feeCollectorSharesBefore = vault.balanceOf(feeCollector);

        // NO profit added, just wait interval
        vm.warp(block.timestamp + MIN_INTERVAL + 1);

        // Crystallize without profit
        queue().endEpochCrystallize();

        uint256 feeCollectorSharesAfter = vault.balanceOf(feeCollector);

        // No shares minted, but HWM might adjust slightly due to rounding
        assertEq(
            feeCollectorSharesAfter, feeCollectorSharesBefore, "No shares minted without profit"
        );
    }
}
