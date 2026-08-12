// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// General correctness suite for EpochedQueueModule, complementing the historical
// regression suite in test/sprint-test/QueueEpochModule_WithdrawFlow_POC.t.sol
// (which stays scoped to its 4 originally-fixed bugs and is left untouched).
//
// Covers: the outstandingClaimCount dynamic-cap fix (the reason this suite
// exists), cancellation, EpochTooYoung, double-claim, multi-retry fundEpoch,
// and closing a zero-claim epoch.
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockUSDC } from "../../helpers/MockUSDC.sol";
import { ERC4626Module } from "../../../src/core/modules/ERC4626Module.sol";
import { EpochedQueueModule } from "../../../src/core/modules/EpochedQueueModule.sol";
import { EpochQueueStorage } from "../../../src/core/modules/EpochedQueueModule.sol";
import { MockQueueEpochParamsProvider } from "../../sprint-test/QueueEpochModule_WithdrawFlow_POC.t.sol";

contract EpochedQueueModule_Test is Test {
    address constant USDC_UNDERLYING = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address internal user;
    address internal userB;

    CoreHarness internal core;
    MockUSDC internal mock;
    MockQueueEpochParamsProvider internal params;

    function setUp() public {
        user = makeAddr("user");
        userB = makeAddr("userB");

        mock = new MockUSDC();
        vm.etch(USDC_UNDERLYING, address(mock).code);

        params = new MockQueueEpochParamsProvider();
        core = new CoreHarness(
            IERC20Metadata(USDC_UNDERLYING),
            "USDC Agg",
            "agUSDC",
            address(this),
            address(this),
            address(params)
        );

        core.setEpochDurationUnsafe(7 days);

        MockUSDC(USDC_UNDERLYING).mint(user, 10_000_000e6);
        MockUSDC(USDC_UNDERLYING).mint(userB, 10_000_000e6);
        vm.prank(user);
        IERC20(USDC_UNDERLYING).approve(address(core), type(uint256).max);
        vm.prank(userB);
        IERC20(USDC_UNDERLYING).approve(address(core), type(uint256).max);
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = ERC4626Module(address(core)).deposit(assets, who);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BUG FIX: outstandingClaimCount persists across epoch close (the reason
    // this suite exists) — dynamic cap stress must not reset just because a
    // fresh epoch opened while a claim from the closed epoch is still
    // unfunded/unclaimed.
    // ═══════════════════════════════════════════════════════════════════════

    function test_dynamicCap_staysTightened_afterEpochClose_withOutstandingClaim() public {
        params.setDynamicCap(true, 100, 2000, 1); // enabled, min 1%, max 20%, threshold 1
        uint256 sharesA = _deposit(user, 1_000_000e6);
        _deposit(userB, 10_000e6);

        // userB queues a small claim, then the epoch closes -- with the old
        // per-open-epoch claimCount signal, this would reset queueDepth to 0
        // and the dynamic cap would wrongly relax back to max (20%).
        vm.prank(userB);
        EpochedQueueModule(address(core)).requestEpochWithdrawal(1_000e6);

        vm.warp(block.timestamp + 7 days + 1);
        EpochedQueueModule(address(core)).closeCurrentEpoch();

        assertEq(
            EpochedQueueModule(address(core)).outstandingClaimCount(),
            1,
            "userB's claim is still outstanding (unfunded/unclaimed) after the epoch closed"
        );

        // userA now requests an instant withdrawal worth 5% of TVL -- exceeds
        // the 1%-under-stress dynamic cap. Must still be rejected.
        uint256 fivePctShares = sharesA / 20;
        vm.prank(user);
        (bool settledImmediately,,) =
            EpochedQueueModule(address(core)).requestInstantWithdrawal(fivePctShares);

        assertFalse(
            settledImmediately,
            "dynamic cap must stay tightened: outstanding claim from the closed epoch still counts as queue depth"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // cancelEpochWithdrawal
    // ═══════════════════════════════════════════════════════════════════════

    function test_cancelEpochWithdrawal_returnsShares_andDecrementsTotals() public {
        uint256 shares = _deposit(user, 1_000_000e6);

        vm.prank(user);
        (uint256 epochId, uint256 claimId) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(shares);

        assertEq(EpochedQueueModule(address(core)).outstandingClaimCount(), 1);
        assertEq(EpochedQueueModule(address(core)).totalEscrowedShares(), shares);

        vm.prank(user);
        EpochedQueueModule(address(core)).cancelEpochWithdrawal(epochId, claimId);

        assertEq(core.balanceOf(user), shares, "shares returned to user");
        assertEq(EpochedQueueModule(address(core)).outstandingClaimCount(), 0);
        assertEq(EpochedQueueModule(address(core)).totalEscrowedShares(), 0);

        EpochQueueStorage.EpochData memory epoch = EpochedQueueModule(address(core)).epochData(epochId);
        assertEq(epoch.claimCount, 0);
        assertEq(epoch.totalGrossShares, 0);
    }

    function test_cancelEpochWithdrawal_revertsForNonOwner() public {
        uint256 shares = _deposit(user, 1_000_000e6);
        vm.prank(user);
        (uint256 epochId, uint256 claimId) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(shares);

        vm.prank(userB);
        vm.expectRevert(EpochedQueueModule.NotClaimOwner.selector);
        EpochedQueueModule(address(core)).cancelEpochWithdrawal(epochId, claimId);
    }

    function test_cancelEpochWithdrawal_revertsIfAlreadyCancelled() public {
        uint256 shares = _deposit(user, 1_000_000e6);
        vm.prank(user);
        (uint256 epochId, uint256 claimId) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(shares);

        vm.prank(user);
        EpochedQueueModule(address(core)).cancelEpochWithdrawal(epochId, claimId);

        vm.prank(user);
        vm.expectRevert(EpochedQueueModule.ClaimAlreadySettled.selector);
        EpochedQueueModule(address(core)).cancelEpochWithdrawal(epochId, claimId);
    }

    function test_cancelEpochWithdrawal_revertsOnceEpochClosed() public {
        uint256 shares = _deposit(user, 1_000_000e6);
        vm.prank(user);
        (uint256 epochId, uint256 claimId) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(shares);

        vm.warp(block.timestamp + 7 days + 1);
        EpochedQueueModule(address(core)).closeCurrentEpoch();

        vm.prank(user);
        vm.expectRevert(EpochedQueueModule.EpochNotOpen.selector);
        EpochedQueueModule(address(core)).cancelEpochWithdrawal(epochId, claimId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EpochTooYoung
    // ═══════════════════════════════════════════════════════════════════════

    function test_closeCurrentEpoch_revertsBeforeMinDuration() public {
        _deposit(user, 1_000_000e6);
        vm.prank(user);
        EpochedQueueModule(address(core)).requestEpochWithdrawal(500_000e6);

        // No warp -- epoch just opened.
        vm.expectRevert(EpochedQueueModule.EpochTooYoung.selector);
        EpochedQueueModule(address(core)).closeCurrentEpoch();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Double-claim
    // ═══════════════════════════════════════════════════════════════════════

    function test_claimEpochAssets_revertsOnDoubleClaim() public {
        uint256 shares = _deposit(user, 1_000_000e6);
        vm.prank(user);
        (uint256 epochId, uint256 claimId) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(shares);

        vm.warp(block.timestamp + 7 days + 1);
        EpochedQueueModule(address(core)).closeCurrentEpoch();
        EpochedQueueModule(address(core)).fundEpoch(epochId);

        vm.prank(user);
        EpochedQueueModule(address(core)).claimEpochAssets(epochId, claimId);

        vm.prank(user);
        vm.expectRevert(EpochedQueueModule.ClaimAlreadySettled.selector);
        EpochedQueueModule(address(core)).claimEpochAssets(epochId, claimId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Multi-retry fundEpoch: partial funding across calls, no double-counting
    // ═══════════════════════════════════════════════════════════════════════

    function test_fundEpoch_staysClosedUntilFullyFunded_thenSucceedsOnRetry() public {
        uint256 shares = _deposit(user, 1_000_000e6);
        vm.prank(user);
        (uint256 epochId, uint256 claimId) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(shares);

        vm.warp(block.timestamp + 7 days + 1);
        EpochedQueueModule(address(core)).closeCurrentEpoch();

        // Simulate capital deployed elsewhere: drain the vault's hot balance
        // so fundEpoch() sees an unfundable deficit on the first call.
        vm.prank(address(core));
        IERC20(USDC_UNDERLYING).transfer(makeAddr("elsewhere"), 900_000e6);

        EpochedQueueModule(address(core)).fundEpoch(epochId);
        EpochQueueStorage.EpochData memory epochAfterFirst =
            EpochedQueueModule(address(core)).epochData(epochId);
        assertTrue(
            epochAfterFirst.state == EpochQueueStorage.EpochState.Closed,
            "epoch stays CLOSED: hot balance insufficient, no BufferManager/router to cover the gap"
        );

        // Liquidity arrives (e.g. strategy harvest returns funds).
        MockUSDC(USDC_UNDERLYING).mint(address(core), 900_000e6);

        EpochedQueueModule(address(core)).fundEpoch(epochId);
        EpochQueueStorage.EpochData memory epochAfterSecond =
            EpochedQueueModule(address(core)).epochData(epochId);
        assertTrue(
            epochAfterSecond.state == EpochQueueStorage.EpochState.Funded,
            "retry succeeds once hot balance covers totalNetAssets"
        );
        // No double counting: totalNetAssets is unchanged across retries.
        assertEq(epochAfterFirst.totalNetAssets, epochAfterSecond.totalNetAssets);

        vm.prank(user);
        uint256 assets = EpochedQueueModule(address(core)).claimEpochAssets(epochId, claimId);
        assertGt(assets, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Zero-claim epoch close
    // ═══════════════════════════════════════════════════════════════════════

    function test_closeCurrentEpoch_withNoClaims_computesSanely() public {
        // No deposits, no withdrawal requests at all -- epoch 0 was never
        // touched by _requestEpochWithdrawal, so openedAt defaults to 0.
        vm.warp(block.timestamp + 7 days + 1);

        EpochedQueueModule(address(core)).closeCurrentEpoch();

        EpochQueueStorage.EpochData memory epoch0 = EpochedQueueModule(address(core)).epochData(0);
        assertTrue(epoch0.state == EpochQueueStorage.EpochState.Closed);
        assertEq(epoch0.totalNetShares, 0);
        assertEq(epoch0.totalNetAssets, 0, "no division-by-zero weirdness: zero shares -> zero assets");
        assertEq(epoch0.ppsAtClose, 1e18, "empty-supply PPS defaults to WAD");

        assertEq(EpochedQueueModule(address(core)).currentEpochId(), 1, "next epoch opened");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // oldestUnfundedEpochId cursor (keeper-facing "what needs fundEpoch() next")
    // ═══════════════════════════════════════════════════════════════════════

    function test_oldestUnfundedEpochId_advancesInOrder() public {
        assertEq(EpochedQueueModule(address(core)).oldestUnfundedEpochId(), 0, "no backlog initially");

        _deposit(user, 1_000_000e6);
        vm.prank(user);
        (uint256 epoch0Id, uint256 claim0Id) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(200_000e6);

        vm.warp(block.timestamp + 7 days + 1);
        EpochedQueueModule(address(core)).closeCurrentEpoch(); // opens epoch 1

        assertEq(
            EpochedQueueModule(address(core)).oldestUnfundedEpochId(), epoch0Id,
            "epoch 0 is closed and unfunded -> cursor points at it"
        );

        EpochedQueueModule(address(core)).fundEpoch(epoch0Id);

        assertEq(
            EpochedQueueModule(address(core)).oldestUnfundedEpochId(),
            EpochedQueueModule(address(core)).currentEpochId(),
            "epoch 0 funded, epoch 1 still open -> cursor catches up to currentEpochId (no backlog)"
        );

        vm.prank(user);
        EpochedQueueModule(address(core)).claimEpochAssets(epoch0Id, claim0Id);
    }

    function test_oldestUnfundedEpochId_doesNotSkipPast_stillUnfundedEarlierEpoch() public {
        // Track time via a local counter -- block.timestamp is not reliably
        // re-readable mid-test through the CoreHarness delegatecall stack here
        // (same quirk worked around elsewhere in this suite/session).
        uint256 t = block.timestamp;

        _deposit(user, 1_000_000e6);

        // Epoch 0: userA's claim.
        vm.prank(user);
        (uint256 epoch0Id,) = EpochedQueueModule(address(core)).requestEpochWithdrawal(100_000e6);
        t += 7 days + 1;
        vm.warp(t);
        EpochedQueueModule(address(core)).closeCurrentEpoch(); // opens epoch 1

        // Drain hot so epoch 0 CANNOT be funded yet.
        vm.prank(address(core));
        IERC20(USDC_UNDERLYING).transfer(makeAddr("elsewhere"), 950_000e6);

        // Epoch 1: userB's claim, funded normally (ample remaining liquidity).
        _deposit(userB, 500_000e6);
        vm.prank(userB);
        EpochedQueueModule(address(core)).requestEpochWithdrawal(100_000e6);
        t += 7 days + 1;
        vm.warp(t);
        EpochedQueueModule(address(core)).closeCurrentEpoch(); // opens epoch 2

        uint256 epoch1Id = epoch0Id + 1;
        EpochedQueueModule(address(core)).fundEpoch(epoch1Id); // funds OUT OF ORDER

        EpochQueueStorage.EpochData memory e1 = EpochedQueueModule(address(core)).epochData(epoch1Id);
        assertTrue(e1.state == EpochQueueStorage.EpochState.Funded, "epoch 1 funded despite epoch 0 still pending");

        assertEq(
            EpochedQueueModule(address(core)).oldestUnfundedEpochId(),
            epoch0Id,
            "cursor must NOT skip past epoch 0 just because the later epoch 1 got funded first"
        );
    }
}
