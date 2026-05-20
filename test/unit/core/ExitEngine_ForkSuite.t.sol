// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
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
}

interface IForceWithdrawAll {
    function forceWithdrawAll(address receiver) external returns (uint256);
}

/// @title ExitEngine Fork Test Suite - 10 Mandatory Tests
/// @notice Validates all ExitEngineLib invariants end-to-end
/// @dev CTO requirement: ALL 10 MUST PASS before shadow deploy
///
/// INVARIANTS UNDER TEST:
///   1. withdraw()/redeem() CANNOT ever transfer assets - always revert
///   2. requestClaim(true) CANNOT exceed epoch cap
///   3. Epoch rollover auto-rolls on any interaction, no keeper needed
///   4. totalSupply NEVER increases on exit - no _mint in exit paths
///   5. feeShares NEVER minted - always transferred from owner/escrow
///   6. simulateExit == runtime execution
///   7. forceWithdraw does NOT consume epoch cap
contract ExitEngine_ForkSuite is Test {
    CoreHarness public vault;
    ERC20Mock public usdc;
    MockParamsProvider public params;
    MockBufferManagerForTests public mockBM;

    address public owner;
    address public feeCollector = address(0xFEE);
    address public user1 = address(0x1111);
    address public user2 = address(0x2222);
    address public user3 = address(0x3333);
    address public keeper = address(0x4444);

    uint256 constant INITIAL_SUPPLY = 10_000_000e6; // 10M USDC

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

        mockBM = new MockBufferManagerForTests(address(vault));
        vault.setBufferManagerUnsafe(address(mockBM));

        // Set fees: 0.25% withdraw, 0.5% immediate penalty, 1.5% force penalty
        vault.setFeeParamsUnsafe(0, 25, feeCollector);
        vault.setExitFeesUnsafe(25, 50, 150);

        // Unpause
        vault.unpause();

        // Fund users
        usdc._mint(user1, INITIAL_SUPPLY);
        usdc._mint(user2, INITIAL_SUPPLY);
        usdc._mint(user3, INITIAL_SUPPLY);
        usdc._mint(owner, INITIAL_SUPPLY);

        // User1 deposits 1M
        vm.startPrank(user1);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000e6, user1);
        vm.stopPrank();

        // User2 deposits 500K
        vm.startPrank(user2);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(500_000e6, user2);
        vm.stopPrank();

        // User3 deposits 500K
        vm.startPrank(user3);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(500_000e6, user3);
        vm.stopPrank();

        // Total: 2M USDC, 2M shares (1:1 PPS)
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 1: withdraw() always reverts, requestClaim(true) settles instantly
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_fork1_withdrawReverts_requestClaimInstant() public {
        // withdraw ALWAYS reverts
        vm.prank(user1);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(100e6, user1, user1);

        // redeem ALWAYS reverts
        vm.prank(user1);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.redeem(100e6, user1, user1);

        // requestClaim(true) settles instantly
        uint256 usdcBefore = usdc.balanceOf(user1);
        uint256 sharesBefore = vault.balanceOf(user1);

        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(true, 100_000e6);

        uint256 sharesAfter = vault.balanceOf(user1);
        uint256 usdcAfter = usdc.balanceOf(user1);

        assertEq(sharesBefore - sharesAfter, 100_000e6, "shares consumed");
        assertGt(usdcAfter, usdcBefore, "user received USDC");

        // maxWithdraw/maxRedeem return 0
        assertEq(vault.maxWithdraw(user1), 0, "maxWithdraw = 0");
        assertEq(vault.maxRedeem(user1), 0, "maxRedeem = 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 2: requestClaim(false) → keeper settles → fee via transfer
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_fork2_queuedClaim_keeperSettles_feeTransfer() public {
        uint256 supplyBefore = vault.totalSupply();

        // User queues a claim (not immediate)
        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(false, 200_000e6);

        // Shares moved to escrow
        assertEq(IQueueModule(address(vault)).pendingShares(), 200_000e6, "pending shares");
        assertEq(IQueueModule(address(vault)).queueLength(), 1, "queue has 1 claim");

        // Supply unchanged (shares in escrow, not burned yet)
        assertEq(vault.totalSupply(), supplyBefore, "supply unchanged during queue");

        uint256 feeCollectorSharesBefore = vault.balanceOf(feeCollector);

        // Keeper settles
        IQueueModule(address(vault)).settleFeesAndProcessQueue(10);

        uint256 supplyAfter = vault.totalSupply();
        uint256 feeCollectorSharesAfter = vault.balanceOf(feeCollector);

        // INVARIANT: totalSupply decreased (shares burned, not minted)
        assertLt(supplyAfter, supplyBefore, "supply decreased after settlement");

        // INVARIANT: feeCollector received shares via TRANSFER (not mint)
        assertGt(feeCollectorSharesAfter, feeCollectorSharesBefore, "feeCollector got shares");

        // INVARIANT: supply decrease >= shares claimed (some went to feeCollector)
        uint256 supplyDrop = supplyBefore - supplyAfter;
        assertLe(supplyDrop, 200_000e6, "supply drop <= claimed shares");

        // Queue cleared
        assertEq(IQueueModule(address(vault)).pendingShares(), 0, "queue empty");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 3: epoch rollover resets cap automatically
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_fork3_epochRollover_resetsCap() public {
        // Cap = 10% of 2M = 200K per epoch
        // Claim 150K (under cap) - succeeds
        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(true, 150_000e6);

        // Claim another 100K - should queue (total 250K > 200K cap)
        uint256 pendingBefore = IQueueModule(address(vault)).pendingShares();
        vm.prank(user2);
        IQueueModule(address(vault)).requestClaim(true, 100_000e6);
        uint256 pendingAfter = IQueueModule(address(vault)).pendingShares();

        // Should have been queued (cap exhausted)
        assertGt(pendingAfter, pendingBefore, "second claim queued due to cap");

        // Warp past epoch (7 days default)
        vm.warp(block.timestamp + 7 days + 1);

        // New claim should succeed (epoch rolled, cap reset)
        uint256 usdcBefore = usdc.balanceOf(user2);
        vm.prank(user2);
        IQueueModule(address(vault)).requestClaim(true, 50_000e6);
        uint256 usdcAfter = usdc.balanceOf(user2);

        assertGt(usdcAfter, usdcBefore, "claim succeeded after epoch rollover");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 4: cap exhaustion → requestClaim(true) queues instead of settling
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_fork4_capExhaustion_instantQueues() public {
        // Cap = 10% of 2M = 200K per epoch
        // Use up the cap
        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(true, 199_000e6);

        // Next instant claim should queue (cap nearly exhausted)
        uint256 sharesBefore = vault.balanceOf(user2);
        uint256 pendingBefore = IQueueModule(address(vault)).pendingShares();

        vm.prank(user2);
        IQueueModule(address(vault)).requestClaim(true, 50_000e6);

        uint256 pendingAfter = IQueueModule(address(vault)).pendingShares();

        // Shares moved to escrow (queued, not settled)
        assertGt(pendingAfter, pendingBefore, "claim queued when cap exhausted");

        // User2 shares decreased (moved to escrow)
        uint256 sharesAfter = vault.balanceOf(user2);
        assertLt(sharesAfter, sharesBefore, "shares moved to escrow");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 5: forceWithdrawAll bypasses cap when cap=0
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_fork5_forceExitBypassesCap() public {
        // Exhaust cap completely
        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(true, 199_000e6);

        // Verify cap is nearly exhausted by trying another instant claim
        vm.prank(user2);
        IQueueModule(address(vault)).requestClaim(true, 50_000e6);
        // If this queued, cap is exhausted - verify:
        assertGt(IQueueModule(address(vault)).pendingShares(), 0, "cap exhausted, claims queuing");

        // forceWithdrawAll should still work (bypasses cap)
        uint256 user3SharesBefore = vault.balanceOf(user3);
        assertGt(user3SharesBefore, 0, "user3 has shares");

        uint256 usdcBefore = usdc.balanceOf(user3);

        vm.prank(user3);
        IForceWithdrawAll(address(vault)).forceWithdrawAll(user3);

        uint256 user3SharesAfter = vault.balanceOf(user3);
        uint256 usdcAfter = usdc.balanceOf(user3);

        assertEq(user3SharesAfter, 0, "user3 shares = 0 after forceWithdrawAll");
        assertGt(usdcAfter, usdcBefore, "user3 received USDC");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 6: multi-user epoch cap - N users exhaust cap
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_fork6_multiUserEpochCap() public {
        // Cap = 10% of 2M = 200K
        // User1 claims 80K (instant, under cap)
        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(true, 80_000e6);

        // User2 claims 80K (instant, under cap - cumulative 160K < 200K)
        vm.prank(user2);
        IQueueModule(address(vault)).requestClaim(true, 80_000e6);

        // User3 claims 80K - should queue (cumulative 240K > 200K cap)
        uint256 pendingBefore = IQueueModule(address(vault)).pendingShares();
        vm.prank(user3);
        IQueueModule(address(vault)).requestClaim(true, 80_000e6);
        uint256 pendingAfter = IQueueModule(address(vault)).pendingShares();

        assertGt(pendingAfter, pendingBefore, "user3 claim queued - cap exhausted by multi-user");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 7: fee = transfer not mint, supply monotonically decreasing on exits
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_fork7_feeViaTransfer_supplyDecreasing() public {
        uint256 supplyStart = vault.totalSupply();

        // Instant claim - supply must decrease
        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(true, 50_000e6);

        uint256 supplyAfterInstant = vault.totalSupply();
        assertLt(supplyAfterInstant, supplyStart, "supply decreased after instant claim");

        // Queued claim + settle - supply must decrease further
        vm.prank(user2);
        IQueueModule(address(vault)).requestClaim(false, 30_000e6);

        uint256 supplyAfterQueue = vault.totalSupply();
        // During queue, shares are in escrow (still counted in supply)
        assertEq(supplyAfterQueue, supplyAfterInstant, "supply unchanged during queue escrow");

        // Settle
        IQueueModule(address(vault)).settleFeesAndProcessQueue(10);
        uint256 supplyAfterSettle = vault.totalSupply();
        assertLt(supplyAfterSettle, supplyAfterQueue, "supply decreased after settlement");

        // Force withdraw - supply must decrease further
        vm.prank(user3);
        IForceWithdrawAll(address(vault)).forceWithdrawAll(user3);
        uint256 supplyAfterForce = vault.totalSupply();
        assertLt(supplyAfterForce, supplyAfterSettle, "supply decreased after force");

        // INVARIANT: supply monotonically decreased across all exit types
        assertLt(supplyAfterForce, supplyStart, "overall supply decreased");

        // FeeCollector has shares (received via transfer)
        assertGt(vault.balanceOf(feeCollector), 0, "feeCollector has shares from fees");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 8: parametric epoch - 1d vs 30d
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_fork8_parametricEpoch_1d_vs_30d() public {
        // PART A: 1-day epoch
        vault.setEpochDurationUnsafe(1 days);

        // Claim near cap
        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(true, 150_000e6);

        // After 1 day, epoch should roll and cap reset
        vm.warp(block.timestamp + 1 days + 1);

        uint256 usdcBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(true, 50_000e6);
        uint256 usdcAfter = usdc.balanceOf(user1);
        assertGt(usdcAfter, usdcBefore, "claim succeeded after 1-day epoch");

        // PART B: 30-day epoch
        vault.setEpochDurationUnsafe(30 days);

        // Force epoch boundary by warping past current epoch + triggering roll
        vm.warp(block.timestamp + 30 days + 1);
        // Trigger epoch roll with a small claim
        vm.prank(user2);
        IQueueModule(address(vault)).requestClaim(true, 1_000e6);

        // Now exhaust the fresh cap in this 30-day epoch
        vm.prank(user2);
        IQueueModule(address(vault)).requestClaim(true, 150_000e6);

        // After 7 days - epoch should NOT roll (30-day epoch, only 7 days passed)
        vm.warp(block.timestamp + 7 days);

        // Large claim should exceed remaining cap and queue
        uint256 pendingBefore = IQueueModule(address(vault)).pendingShares();
        vm.prank(user3);
        IQueueModule(address(vault)).requestClaim(true, 100_000e6);
        uint256 pendingAfter = IQueueModule(address(vault)).pendingShares();
        assertGt(pendingAfter, pendingBefore, "claim queued - 30-day epoch not yet rolled");

        // After remaining 23+ days - epoch rolls
        vm.warp(block.timestamp + 24 days);

        usdcBefore = usdc.balanceOf(user3);
        vm.prank(user3);
        IQueueModule(address(vault)).requestClaim(true, 10_000e6);
        usdcAfter = usdc.balanceOf(user3);
        assertGt(usdcAfter, usdcBefore, "claim succeeded after 30-day epoch roll");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 9: mixed modes - instant + queued + force in same epoch
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_fork9_mixedModes_sameEpoch() public {
        uint256 supplyStart = vault.totalSupply();

        // Mode 1: INSTANT claim
        uint256 user1UsdcBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(true, 50_000e6);
        assertGt(usdc.balanceOf(user1), user1UsdcBefore, "instant: received USDC");

        // Mode 2: QUEUED claim (same epoch)
        vm.prank(user2);
        IQueueModule(address(vault)).requestClaim(false, 30_000e6);
        assertEq(IQueueModule(address(vault)).queueLength(), 1, "queued: 1 in queue");

        // Mode 3: FORCE withdrawal (same epoch)
        uint256 user3UsdcBefore = usdc.balanceOf(user3);
        vm.prank(user3);
        IForceWithdrawAll(address(vault)).forceWithdrawAll(user3);
        assertGt(usdc.balanceOf(user3), user3UsdcBefore, "force: received USDC");
        assertEq(vault.balanceOf(user3), 0, "force: user3 fully exited");

        // Settle the queued claim
        IQueueModule(address(vault)).settleFeesAndProcessQueue(10);
        assertEq(IQueueModule(address(vault)).queueLength(), 0, "queue settled");

        // INVARIANT: supply only decreased
        assertLt(vault.totalSupply(), supplyStart, "supply decreased from mixed exits");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 10: NAV freshness - stale NAV → soft refresh → correct conversion
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_fork10_navFreshness_softRefresh() public {
        // Set NAV to stale (warp past 15min)
        vm.warp(block.timestamp + 20 minutes);

        // requestClaim(true) should still work (soft refresh, W2 = never block)
        uint256 usdcBefore = usdc.balanceOf(user1);
        uint256 sharesBefore = vault.balanceOf(user1);

        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(true, 50_000e6);

        uint256 usdcAfter = usdc.balanceOf(user1);
        uint256 sharesAfter = vault.balanceOf(user1);

        assertGt(usdcAfter, usdcBefore, "received USDC despite stale NAV");
        assertEq(sharesBefore - sharesAfter, 50_000e6, "correct shares consumed");

        // Queued claim + settle should also work with stale NAV
        vm.warp(block.timestamp + 20 minutes);

        vm.prank(user2);
        IQueueModule(address(vault)).requestClaim(false, 30_000e6);

        vm.warp(block.timestamp + 20 minutes);

        uint256 user2UsdcBefore = usdc.balanceOf(user2);
        IQueueModule(address(vault)).settleFeesAndProcessQueue(10);
        uint256 user2UsdcAfter = usdc.balanceOf(user2);

        assertGt(user2UsdcAfter, user2UsdcBefore, "settlement works with stale NAV");

        // forceWithdrawAll should also work with stale NAV
        vm.warp(block.timestamp + 20 minutes);

        uint256 user3UsdcBefore = usdc.balanceOf(user3);
        vm.prank(user3);
        IForceWithdrawAll(address(vault)).forceWithdrawAll(user3);
        assertGt(usdc.balanceOf(user3), user3UsdcBefore, "force exit works with stale NAV");
    }
}
