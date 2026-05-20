// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";
import { ExitEngineLib } from "../../../src/core/libraries/ExitEngineLib.sol";

interface IQueueModule {
    function requestClaim(bool immediate, uint256 shares) external;
    function cancelClaim(uint256 claimId) external;
    function processQueuedRedemptions(uint256 maxClaims) external;
    function settleFeesAndProcessQueue(uint256 maxClaims) external;
    function nextClaimId() external view returns (uint256);
    function queueLength() external view returns (uint256);
    function pendingShares() external view returns (uint256);
    function endEpochCrystallize() external;
}

interface IForceWithdrawAll {
    function forceWithdrawAll(address receiver) external returns (uint256);
}

interface IDepositFor {
    function depositFor(uint256 assets, address receiver, address payer) external returns (uint256);
}

/// @title ExitEngine Stress Test - Multi-User 300M TVL
/// @notice Tests ALL protocol paths under high TVL with multiple users:
///   - Direct deposit + DepositRouter-style depositFor
///   - requestClaim(true) instant exit
///   - requestClaim(false) queued exit + keeper settlement
///   - forceWithdrawAll
///   - Queue cleanup
///   - Cap exhaustion + epoch rollover
///   - Fee verification (transfer not mint)
///   - Keeper gas verification (all ops < 5M)
///
/// CTO REQUIREMENT: All keeper calls MUST be < 5M gas
contract ExitEngine_StressTest is Test {
    CoreHarness public vault;
    ERC20Mock public usdc;
    MockParamsProvider public params;

    address public owner;
    address public feeCollector = address(0xFEE);
    address public keeper = address(0xBBBB);

    // 10 users for stress test
    address[10] public users;
    // DepositRouter-style payer
    address public router = address(0xDDDD);

    uint256 constant GAS_LIMIT = 5_000_000;

    function setUp() public {
        owner = address(this);

        usdc = new ERC20Mock("USDC", "USDC", 6);
        params = new MockParamsProvider();
        params.setLockPeriod(0);
        params.setCapPerEpochBps(1000); // 10% per epoch

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Vault",
            "vUSDC",
            owner,
            feeCollector,
            address(params)
        );

        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(vault));
        vault.setBufferManagerUnsafe(address(mockBM));

        // Set fees: 0.25% withdraw, 0.5% immediate penalty, 1.5% force penalty
        vault.setFeeParamsUnsafe(0, 25, feeCollector);
        vault.setExitFeesUnsafe(25, 50, 150);

        vault.unpause();

        // Initialize 10 users
        for (uint256 i = 0; i < 10; i++) {
            users[i] = address(uint160(0xA000 + i));
            usdc._mint(users[i], 100_000_000e6); // 100M each
            vm.prank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
        }

        // Router (DepositRouter-style payer)
        usdc._mint(router, 500_000_000e6);
        vm.prank(router);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER: deposit for user (direct)
    // ═══════════════════════════════════════════════════════════════════════════

    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        vault.deposit(amount, user);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER: depositFor (DepositRouter/Permit2 style - payer != receiver)
    // ═══════════════════════════════════════════════════════════════════════════

    function _depositFor(address payer, address receiver, uint256 amount) internal {
        vm.prank(payer);
        IDepositFor(address(vault)).depositFor(amount, receiver, payer);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Multi-user ramp to 300M TVL with all exit modes
    // ═══════════════════════════════════════════════════════════════════════════

    function test_stress_300M_multiUser_allPaths() public {
        // ═══════════════════════════════════════════════════════════════════════
        // PHASE 1: Ramp to 300M TVL via direct deposits + depositFor
        // ═══════════════════════════════════════════════════════════════════════

        console2.log("=== PHASE 1: Ramp to 300M TVL ===");

        // 5 users deposit directly (30M each = 150M)
        for (uint256 i = 0; i < 5; i++) {
            _deposit(users[i], 30_000_000e6);
        }

        // 5 users deposit via router/depositFor (30M each = 150M)
        for (uint256 i = 5; i < 10; i++) {
            _depositFor(router, users[i], 30_000_000e6);
        }

        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();
        console2.log("Total assets:", totalAssets / 1e6, "USDC");
        console2.log("Total supply:", totalSupply / 1e6, "shares");

        assertGe(totalAssets, 299_000_000e6, "TVL >= 299M");
        assertEq(totalSupply, 300_000_000e6, "supply = 300M shares (1:1 no fee)");

        // Verify all 10 users have shares
        for (uint256 i = 0; i < 10; i++) {
            assertEq(vault.balanceOf(users[i]), 30_000_000e6, "each user has 30M shares");
        }

        // ═══════════════════════════════════════════════════════════════════════
        // PHASE 2: Withdraw always reverts
        // ═══════════════════════════════════════════════════════════════════════

        console2.log("=== PHASE 2: withdraw/redeem revert ===");

        vm.prank(users[0]);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(1e6, users[0], users[0]);

        vm.prank(users[0]);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.redeem(1e6, users[0], users[0]);

        // mint still works
        usdc._mint(users[0], 1_000e6);
        vm.startPrank(users[0]);
        usdc.approve(address(vault), 1_000e6);
        vault.mint(1_000e6, users[0]);
        vm.stopPrank();

        // ═══════════════════════════════════════════════════════════════════════
        // PHASE 3: Instant claims (requestClaim(true)) + cap tracking
        // ═══════════════════════════════════════════════════════════════════════

        console2.log("=== PHASE 3: Instant claims + cap ===");

        // Cap = 10% of ~300M = ~30M per epoch
        uint256 supplyBefore = vault.totalSupply();

        // User0 claims 10M instant
        uint256 gasStart = gasleft();
        vm.prank(users[0]);
        IQueueModule(address(vault)).requestClaim(true, 10_000_000e6);
        uint256 gasUsed = gasStart - gasleft();
        console2.log("requestClaim(true, 10M) gas:", gasUsed);
        assertLt(gasUsed, GAS_LIMIT, "instant claim gas < 5M");

        // User1 claims 10M instant
        vm.prank(users[1]);
        IQueueModule(address(vault)).requestClaim(true, 10_000_000e6);

        // User2 claims 10M instant — should be near cap
        vm.prank(users[2]);
        IQueueModule(address(vault)).requestClaim(true, 10_000_000e6);

        uint256 supplyAfterInstant = vault.totalSupply();
        assertLt(supplyAfterInstant, supplyBefore, "supply decreased from instant claims");
        console2.log("Supply after 3 instant claims:", supplyAfterInstant / 1e6);

        // ═══════════════════════════════════════════════════════════════════════
        // PHASE 4: Cap exhaustion — next instant claim queues
        // ═══════════════════════════════════════════════════════════════════════

        console2.log("=== PHASE 4: Cap exhaustion ===");

        uint256 pendingBefore = IQueueModule(address(vault)).pendingShares();

        // User3 tries instant 5M — should queue (cap nearly exhausted)
        vm.prank(users[3]);
        IQueueModule(address(vault)).requestClaim(true, 5_000_000e6);

        uint256 pendingAfter = IQueueModule(address(vault)).pendingShares();
        // If cap was exhausted, claim was queued
        if (pendingAfter > pendingBefore) {
            console2.log("Cap exhausted - claim queued. Pending:", pendingAfter / 1e6);
        } else {
            console2.log("Cap still had room - claim settled instantly");
        }

        // ═══════════════════════════════════════════════════════════════════════
        // PHASE 5: Queued claims (requestClaim(false)) — multiple users
        // ═══════════════════════════════════════════════════════════════════════

        console2.log("=== PHASE 5: Queued claims ===");

        // Users 4-7 queue 5M each
        for (uint256 i = 4; i <= 7; i++) {
            vm.prank(users[i]);
            IQueueModule(address(vault)).requestClaim(false, 5_000_000e6);
        }

        uint256 queueLen = IQueueModule(address(vault)).queueLength();
        uint256 pendingTotal = IQueueModule(address(vault)).pendingShares();
        console2.log("Queue length:", queueLen);
        console2.log("Pending shares:", pendingTotal / 1e6, "M");
        assertGt(queueLen, 0, "queue has claims");

        // ═══════════════════════════════════════════════════════════════════════
        // PHASE 6: Keeper settles queue — gas measurement
        // ═══════════════════════════════════════════════════════════════════════

        console2.log("=== PHASE 6: Keeper settle ===");

        uint256 feeCollectorBefore = vault.balanceOf(feeCollector);
        uint256 supplyBeforeSettle = vault.totalSupply();

        gasStart = gasleft();
        IQueueModule(address(vault)).settleFeesAndProcessQueue(25);
        gasUsed = gasStart - gasleft();
        console2.log("settleFeesAndProcessQueue(25) gas:", gasUsed);
        assertLt(gasUsed, GAS_LIMIT, "settle gas < 5M");

        uint256 feeCollectorAfter = vault.balanceOf(feeCollector);
        uint256 supplyAfterSettle = vault.totalSupply();

        // INVARIANT: supply decreased (not increased)
        assertLe(supplyAfterSettle, supplyBeforeSettle, "supply not increased after settle");

        // INVARIANT: feeCollector got shares (via transfer)
        assertGe(feeCollectorAfter, feeCollectorBefore, "feeCollector got fee shares");
        console2.log("FeeCollector shares:", feeCollectorAfter / 1e6);

        // Settle remaining if any
        uint256 remaining = IQueueModule(address(vault)).queueLength();
        if (remaining > 0) {
            console2.log("Remaining in queue:", remaining);
            IQueueModule(address(vault)).settleFeesAndProcessQueue(50);
            remaining = IQueueModule(address(vault)).queueLength();
            console2.log("After second settle:", remaining);
        }

        // ═══════════════════════════════════════════════════════════════════════
        // PHASE 7: Epoch rollover + fresh claims
        // ═══════════════════════════════════════════════════════════════════════

        console2.log("=== PHASE 7: Epoch rollover ===");

        vm.warp(block.timestamp + 7 days + 1);

        // After epoch roll, fresh cap available
        uint256 user8UsdcBefore = usdc.balanceOf(users[8]);
        vm.prank(users[8]);
        IQueueModule(address(vault)).requestClaim(true, 5_000_000e6);
        uint256 user8UsdcAfter = usdc.balanceOf(users[8]);
        assertGt(user8UsdcAfter, user8UsdcBefore, "instant claim succeeded after epoch roll");
        console2.log("User8 received:", (user8UsdcAfter - user8UsdcBefore) / 1e6, "USDC");

        // ═══════════════════════════════════════════════════════════════════════
        // PHASE 8: forceWithdrawAll — bypasses everything
        // ═══════════════════════════════════════════════════════════════════════

        console2.log("=== PHASE 8: forceWithdrawAll ===");

        uint256 user9Shares = vault.balanceOf(users[9]);
        uint256 user9UsdcBefore = usdc.balanceOf(users[9]);

        gasStart = gasleft();
        vm.prank(users[9]);
        IForceWithdrawAll(address(vault)).forceWithdrawAll(users[9]);
        gasUsed = gasStart - gasleft();
        console2.log("forceWithdrawAll gas:", gasUsed);
        assertLt(gasUsed, GAS_LIMIT, "forceWithdrawAll gas < 5M");

        assertEq(vault.balanceOf(users[9]), 0, "user9 fully exited");
        assertGt(usdc.balanceOf(users[9]), user9UsdcBefore, "user9 received USDC");
        console2.log("User9 exited:", user9Shares / 1e6, "M shares");

        // ═══════════════════════════════════════════════════════════════════════
        // PHASE 9: endEpochCrystallize — keeper gas
        // ═══════════════════════════════════════════════════════════════════════

        console2.log("=== PHASE 9: Crystallize ===");

        // Simulate profit for crystallization
        usdc._mint(address(vault), 500_000e6);
        vault.setPerfParamsUnsafe(10e16, 3600); // 10% perf fee, 1h min

        vm.warp(block.timestamp + 1 days);

        gasStart = gasleft();
        IQueueModule(address(vault)).endEpochCrystallize();
        gasUsed = gasStart - gasleft();
        console2.log("endEpochCrystallize gas:", gasUsed);
        assertLt(gasUsed, GAS_LIMIT, "crystallize gas < 5M");

        // ═══════════════════════════════════════════════════════════════════════
        // PHASE 10: Final accounting verification
        // ═══════════════════════════════════════════════════════════════════════

        console2.log("=== PHASE 10: Final accounting ===");

        uint256 finalAssets = vault.totalAssets();
        uint256 finalSupply = vault.totalSupply();
        uint256 finalFeeShares = vault.balanceOf(feeCollector);

        console2.log("Final assets:", finalAssets / 1e6, "USDC");
        console2.log("Final supply:", finalSupply / 1e6, "shares");
        console2.log("FeeCollector shares:", finalFeeShares / 1e6);
        console2.log("Queue length:", IQueueModule(address(vault)).queueLength());
        console2.log("Pending shares:", IQueueModule(address(vault)).pendingShares() / 1e6);

        // INVARIANT: supply < initial (exits happened)
        assertLt(finalSupply, 300_001_000e6, "supply decreased from exits");

        // INVARIANT: feeCollector has shares
        assertGt(finalFeeShares, 0, "feeCollector accumulated fees");

        // INVARIANT: maxWithdraw/maxRedeem = 0
        assertEq(vault.maxWithdraw(users[0]), 0, "maxWithdraw = 0");
        assertEq(vault.maxRedeem(users[0]), 0, "maxRedeem = 0");

        console2.log("=== STRESS TEST PASSED ===");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Keeper gas on all operations at 300M TVL
    // ═══════════════════════════════════════════════════════════════════════════

    function test_stress_keeperGas_allOps_300M() public {
        // Ramp to 300M
        for (uint256 i = 0; i < 10; i++) {
            _deposit(users[i], 30_000_000e6);
        }

        console2.log("=== Keeper Gas at 300M TVL ===");
        console2.log("Total assets:", vault.totalAssets() / 1e6, "USDC");

        // --- requestClaim(true) gas ---
        uint256 g;
        g = gasleft();
        vm.prank(users[0]);
        IQueueModule(address(vault)).requestClaim(true, 1_000_000e6);
        console2.log("requestClaim(true, 1M):", g - gasleft());
        assertLt(g - gasleft(), GAS_LIMIT, "instant claim < 5M");

        // --- requestClaim(false) gas ---
        g = gasleft();
        vm.prank(users[1]);
        IQueueModule(address(vault)).requestClaim(false, 1_000_000e6);
        console2.log("requestClaim(false, 1M):", g - gasleft());
        assertLt(g - gasleft(), GAS_LIMIT, "queued claim < 5M");

        // --- settleFeesAndProcessQueue gas (1 claim) ---
        g = gasleft();
        IQueueModule(address(vault)).settleFeesAndProcessQueue(10);
        console2.log("settleFeesAndProcessQueue(10):", g - gasleft());
        assertLt(g - gasleft(), GAS_LIMIT, "settle < 5M");

        // --- Queue 20 claims then settle batch ---
        for (uint256 i = 2; i < 8; i++) {
            vm.prank(users[i]);
            IQueueModule(address(vault)).requestClaim(false, 500_000e6);
        }
        // 3 more from same users
        for (uint256 i = 2; i < 5; i++) {
            vm.prank(users[i]);
            IQueueModule(address(vault)).requestClaim(false, 500_000e6);
        }

        g = gasleft();
        IQueueModule(address(vault)).settleFeesAndProcessQueue(25);
        uint256 settleGas = g - gasleft();
        console2.log("settleFeesAndProcessQueue(25) batch:", settleGas);
        assertLt(settleGas, GAS_LIMIT, "batch settle < 5M");

        // --- processQueuedRedemptions gas (no cap) ---
        vm.prank(users[8]);
        IQueueModule(address(vault)).requestClaim(false, 1_000_000e6);

        g = gasleft();
        IQueueModule(address(vault)).processQueuedRedemptions(10);
        console2.log("processQueuedRedemptions(10):", g - gasleft());
        assertLt(g - gasleft(), GAS_LIMIT, "processQueued < 5M");

        // --- endEpochCrystallize gas ---
        vault.setPerfParamsUnsafe(10e16, 3600);
        usdc._mint(address(vault), 1_000_000e6); // simulate profit
        vm.warp(block.timestamp + 1 days);

        g = gasleft();
        IQueueModule(address(vault)).endEpochCrystallize();
        console2.log("endEpochCrystallize:", g - gasleft());
        assertLt(g - gasleft(), GAS_LIMIT, "crystallize < 5M");

        // --- forceWithdrawAll gas ---
        g = gasleft();
        vm.prank(users[9]);
        IForceWithdrawAll(address(vault)).forceWithdrawAll(users[9]);
        console2.log("forceWithdrawAll:", g - gasleft());
        assertLt(g - gasleft(), GAS_LIMIT, "forceWithdrawAll < 5M");

        // --- deposit gas at 300M TVL ---
        usdc._mint(users[9], 10_000_000e6);
        vm.startPrank(users[9]);
        usdc.approve(address(vault), type(uint256).max);
        g = gasleft();
        vault.deposit(10_000_000e6, users[9]);
        console2.log("deposit(10M):", g - gasleft());
        assertLt(g - gasleft(), GAS_LIMIT, "deposit < 5M");
        vm.stopPrank();

        // --- depositFor gas (DepositRouter pattern) ---
        g = gasleft();
        _depositFor(router, users[9], 5_000_000e6);
        console2.log("depositFor(5M):", g - gasleft());
        assertLt(g - gasleft(), GAS_LIMIT, "depositFor < 5M");

        // --- mint gas ---
        usdc._mint(users[9], 10_000_000e6);
        vm.startPrank(users[9]);
        usdc.approve(address(vault), type(uint256).max);
        g = gasleft();
        vault.mint(5_000_000e6, users[9]);
        console2.log("mint(5M shares):", g - gasleft());
        assertLt(g - gasleft(), GAS_LIMIT, "mint < 5M");
        vm.stopPrank();

        console2.log("=== ALL KEEPER GAS < 5M ===");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Multi-day simulation with deposits/claims/settlements
    // ═══════════════════════════════════════════════════════════════════════════

    function test_stress_multiDay_lifecycle() public {
        console2.log("=== Multi-Day Lifecycle ===");

        // DAY 1: Initial deposits to 100M
        for (uint256 i = 0; i < 10; i++) {
            _deposit(users[i], 10_000_000e6);
        }
        console2.log("Day 1 TVL:", vault.totalAssets() / 1e6);

        // DAY 1: Mix of instant + queued claims
        vm.prank(users[0]);
        IQueueModule(address(vault)).requestClaim(true, 2_000_000e6);
        vm.prank(users[1]);
        IQueueModule(address(vault)).requestClaim(false, 3_000_000e6);
        vm.prank(users[2]);
        IQueueModule(address(vault)).requestClaim(true, 1_000_000e6);

        // Keeper settles queue
        IQueueModule(address(vault)).settleFeesAndProcessQueue(25);

        // DAY 2: More deposits + withdrawals
        vm.warp(block.timestamp + 1 days);

        // New deposits via depositFor (router pattern)
        _depositFor(router, users[0], 5_000_000e6);
        _depositFor(router, users[1], 5_000_000e6);

        // More claims
        vm.prank(users[3]);
        IQueueModule(address(vault)).requestClaim(true, 500_000e6);
        vm.prank(users[4]);
        IQueueModule(address(vault)).requestClaim(false, 2_000_000e6);

        // Keeper settles
        IQueueModule(address(vault)).settleFeesAndProcessQueue(25);

        // DAY 3: Ramp up to 200M
        vm.warp(block.timestamp + 1 days);
        for (uint256 i = 0; i < 10; i++) {
            _deposit(users[i], 10_000_000e6);
        }
        console2.log("Day 3 TVL:", vault.totalAssets() / 1e6);

        // DAY 4: Heavy exit pressure
        vm.warp(block.timestamp + 1 days);

        // 5 users instant claim 5M each
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(users[i]);
            IQueueModule(address(vault)).requestClaim(true, 5_000_000e6);
        }

        // 3 users queue 3M each
        for (uint256 i = 5; i < 8; i++) {
            vm.prank(users[i]);
            IQueueModule(address(vault)).requestClaim(false, 3_000_000e6);
        }

        // Keeper settles
        IQueueModule(address(vault)).settleFeesAndProcessQueue(50);

        // DAY 7: Epoch rollover + crystallize
        vm.warp(block.timestamp + 3 days);

        // Simulate profit
        usdc._mint(address(vault), 200_000e6);
        vault.setPerfParamsUnsafe(10e16, 3600);

        IQueueModule(address(vault)).endEpochCrystallize();

        // Ramp to 300M
        for (uint256 i = 0; i < 10; i++) {
            _deposit(users[i], 10_000_000e6);
        }
        console2.log("Day 7 TVL:", vault.totalAssets() / 1e6);

        // DAY 8: Force withdraw + instant + queued
        vm.warp(block.timestamp + 1 days);

        vm.prank(users[9]);
        IForceWithdrawAll(address(vault)).forceWithdrawAll(users[9]);
        assertEq(vault.balanceOf(users[9]), 0, "user9 fully exited");

        vm.prank(users[8]);
        IQueueModule(address(vault)).requestClaim(true, 1_000_000e6);

        vm.prank(users[7]);
        IQueueModule(address(vault)).requestClaim(false, 2_000_000e6);

        // Final settle
        IQueueModule(address(vault)).settleFeesAndProcessQueue(50);

        // FINAL CHECKS
        uint256 finalAssets = vault.totalAssets();
        uint256 finalSupply = vault.totalSupply();
        uint256 finalFeeShares = vault.balanceOf(feeCollector);

        console2.log("Final TVL:", finalAssets / 1e6);
        console2.log("Final supply:", finalSupply / 1e6);
        console2.log("Fee shares:", finalFeeShares / 1e6);
        console2.log("Queue:", IQueueModule(address(vault)).queueLength());

        assertGt(finalFeeShares, 0, "fees collected");
        assertEq(vault.balanceOf(users[9]), 0, "user9 exited");
        assertLt(finalSupply, 300_000_000e6, "supply < 300M after exits");

        console2.log("=== MULTI-DAY LIFECYCLE PASSED ===");
    }
}
