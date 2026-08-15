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
import { Vm } from "lib/forge-std/src/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockUSDC } from "../../helpers/MockUSDC.sol";
import { ERC4626Module } from "../../../src/core/modules/ERC4626Module.sol";
import { EpochedQueueModule } from "../../../src/core/modules/EpochedQueueModule.sol";
import { EpochQueueStorage } from "../../../src/core/modules/EpochedQueueModule.sol";
import { CoreStorage } from "../../../src/core/storage/CoreStorage.sol";
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

    // ═══════════════════════════════════════════════════════════════════════
    // BUG FIX (PR #13 review, critical): a FUNDED epoch is a real claim on
    // assets, not a snapshot. Funding a LATER epoch must never spend cash
    // already reserved for an EARLIER funded-but-unclaimed epoch, and an
    // instant exit must never dip into it either. Reproduces the reviewer's
    // PoC: Alice's epoch funds at pps 1.0 for 1M against 2M hot; NAV drops
    // 50%; epoch N+1 closes at pps 0.5 and must NOT be fundable out of
    // Alice's reserved cash.
    // ═══════════════════════════════════════════════════════════════════════

    function test_fundEpoch_cannotFundLaterEpoch_outOfEarlierFundedEpochsReservedCash() public {
        // Track time via a local counter -- block.timestamp is not reliably
        // re-readable mid-test through the CoreHarness delegatecall stack here
        // (same quirk worked around elsewhere in this suite).
        uint256 t = block.timestamp;

        uint256 aliceShares = _deposit(user, 1_000_000e6);
        _deposit(userB, 1_000_000e6); // 2M hot, 2M supply, pps 1.0

        vm.prank(user);
        (uint256 epoch0Id, uint256 aliceClaimId) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(aliceShares);

        t += 7 days + 1;
        vm.warp(t);
        EpochedQueueModule(address(core)).closeCurrentEpoch(); // opens epoch 1

        EpochedQueueModule(address(core)).fundEpoch(epoch0Id);
        EpochQueueStorage.EpochData memory e0 = EpochedQueueModule(address(core)).epochData(epoch0Id);
        assertTrue(e0.state == EpochQueueStorage.EpochState.Funded, "epoch 0 funded out of the 2M hot");
        assertEq(
            EpochedQueueModule(address(core)).reservedForClaims(), 1_000_000e6,
            "Alice's payout is now reserved"
        );

        // NAV drops 50% (e.g. a strategy loss) -- drain hot directly by
        // exactly what's reserved for Alice, leaving hot == reservedForClaims.
        vm.prank(address(core));
        IERC20(USDC_UNDERLYING).transfer(makeAddr("elsewhere"), 1_000_000e6);

        vm.prank(userB);
        EpochedQueueModule(address(core)).requestEpochWithdrawal(500_000e6);

        t += 7 days + 1;
        vm.warp(t);
        EpochedQueueModule(address(core)).closeCurrentEpoch(); // opens epoch 2
        uint256 epoch1Id = epoch0Id + 1;
        EpochQueueStorage.EpochData memory e1Closed = EpochedQueueModule(address(core)).epochData(epoch1Id);
        assertEq(e1Closed.ppsAtClose, 0.5e18, "NAV halved relative to unchanged supply");

        // Pre-fix, fundEpoch compared hot(1,000,000) >= totalNetAssets(250,000)
        // directly and would have wrongly marked epoch 1 Funded out of
        // Alice's reserved cash. Post-fix it must stay CLOSED.
        EpochedQueueModule(address(core)).fundEpoch(epoch1Id);
        EpochQueueStorage.EpochData memory e1After = EpochedQueueModule(address(core)).epochData(epoch1Id);
        assertTrue(
            e1After.state == EpochQueueStorage.EpochState.Closed,
            "epoch 1 must stay CLOSED: hot is fully reserved for epoch 0, no spare liquidity"
        );

        // Alice's original Funded claim is still fully payable.
        vm.prank(user);
        uint256 assets = EpochedQueueModule(address(core)).claimEpochAssets(epoch0Id, aliceClaimId);
        assertEq(assets, 1_000_000e6, "Alice paid in full despite the later NAV drop and funding attempt");
    }

    function test_canInstant_rejectsExit_thatWouldDipIntoReservedForClaims() public {
        uint256 aliceShares = _deposit(user, 1_000_000e6);
        _deposit(userB, 1_000_000e6);

        vm.prank(user);
        (uint256 epoch0Id, uint256 aliceClaimId) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(aliceShares);

        vm.warp(block.timestamp + 7 days + 1);
        EpochedQueueModule(address(core)).closeCurrentEpoch();
        EpochedQueueModule(address(core)).fundEpoch(epoch0Id);
        assertEq(EpochedQueueModule(address(core)).reservedForClaims(), 1_000_000e6);

        // Drain hot down to exactly reservedForClaims -- zero free liquidity.
        vm.prank(address(core));
        IERC20(USDC_UNDERLYING).transfer(makeAddr("elsewhere"), 1_000_000e6);

        // Pre-fix, _canInstant compared raw hot(1,000,000) >= gross and would
        // have let this through, spending into Alice's reserved payout.
        vm.prank(userB);
        (bool settledImmediately,,) =
            EpochedQueueModule(address(core)).requestInstantWithdrawal(1_000e6);

        assertFalse(settledImmediately, "instant exit must not dip into cash reserved for a funded epoch");

        // Alice's reservation is untouched, still fully payable at her locked
        // ppsAtClose (unaffected by the live-pps drop from the drain above).
        vm.prank(user);
        uint256 assets = EpochedQueueModule(address(core)).claimEpochAssets(epoch0Id, aliceClaimId);
        assertEq(assets, 1_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BUG FIX (PR #13 review): the oldestUnfundedEpochId cursor could wedge.
    // The bounded advance scan can leave the cursor parked on an epoch that is
    // already FUNDED; fundEpoch() used to revert EpochAlreadyFunded on it,
    // every cycle, with no administrative reset. It now syncs the cursor and
    // returns, so the state is always recoverable permissionlessly.
    // ═══════════════════════════════════════════════════════════════════════

    event EpochFundSkipped(uint256 indexed epochId, uint256 cursorBefore, uint256 cursorAfter);

    /// @notice The no-op must stay observable: a moved cursor means the
    ///         self-heal fired, an unmoved one means the caller picked the
    ///         wrong epoch. Both are silent without this event.
    function test_fundEpoch_onAlreadyFundedEpoch_emitsSkippedWithCursorDelta() public {
        uint256 t = block.timestamp;
        _deposit(user, 1_000_000e6);

        vm.prank(user);
        (uint256 epoch0Id,) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(100_000e6);
        t += 7 days + 1;
        vm.warp(t);
        EpochedQueueModule(address(core)).closeCurrentEpoch();
        EpochedQueueModule(address(core)).fundEpoch(epoch0Id);

        uint256 healthy = EpochedQueueModule(address(core)).oldestUnfundedEpochId();

        // Caller picked the wrong epoch: cursor does not move.
        vm.expectEmit(true, false, false, true, address(core));
        emit EpochFundSkipped(epoch0Id, healthy, healthy);
        EpochedQueueModule(address(core)).fundEpoch(epoch0Id);

        // Cursor stale on a funded epoch: the same call repairs it, and says so.
        _forceCursor(epoch0Id);
        vm.expectEmit(true, false, false, true, address(core));
        emit EpochFundSkipped(epoch0Id, epoch0Id, healthy);
        EpochedQueueModule(address(core)).fundEpoch(epoch0Id);
    }

    /// @notice And it must NOT fire on the keeper's normal path, or it is noise.
    function test_fundEpoch_normalKeeperCycle_emitsNoSkip() public {
        uint256 t = block.timestamp;
        _deposit(user, 1_000_000e6);

        vm.prank(user);
        (uint256 epochId,) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(100_000e6);
        t += 7 days + 1;
        vm.warp(t);
        EpochedQueueModule(address(core)).closeCurrentEpoch();

        // Exactly what the keeper does: read the cursor, fund what it points at.
        uint256 cursor = EpochedQueueModule(address(core)).oldestUnfundedEpochId();
        assertEq(cursor, epochId, "cursor points at the closed epoch");

        vm.recordLogs();
        EpochedQueueModule(address(core)).fundEpoch(cursor);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("EpochFundSkipped(uint256,uint256,uint256)");
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) seen++;
        }
        assertEq(seen, 0, "no skip event on the normal keeper cycle");
    }

    function test_fundEpoch_onAlreadyFundedEpoch_syncsCursorInsteadOfReverting() public {
        uint256 t = block.timestamp;
        _deposit(user, 1_000_000e6);

        vm.prank(user);
        (uint256 epoch0Id, uint256 claim0Id) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(100_000e6);
        t += 7 days + 1;
        vm.warp(t);
        EpochedQueueModule(address(core)).closeCurrentEpoch();
        EpochedQueueModule(address(core)).fundEpoch(epoch0Id);

        // Force the cursor back onto the now-FUNDED epoch, reproducing the
        // state the bounded scan can leave behind.
        _forceCursor(epoch0Id);
        assertEq(EpochedQueueModule(address(core)).oldestUnfundedEpochId(), epoch0Id);

        // Must not revert, and must leave the cursor past the funded epoch.
        EpochedQueueModule(address(core)).fundEpoch(epoch0Id);
        assertEq(
            EpochedQueueModule(address(core)).oldestUnfundedEpochId(),
            EpochedQueueModule(address(core)).currentEpochId(),
            "cursor self-healed past the already-funded epoch"
        );

        // And the claim behind it is still payable.
        vm.prank(user);
        uint256 assets = EpochedQueueModule(address(core)).claimEpochAssets(epoch0Id, claim0Id);
        assertGt(assets, 0, "claimant unaffected by the cursor repair");
    }

    function test_syncOldestUnfundedEpoch_isPermissionlessAndIdempotent() public {
        uint256 t = block.timestamp;
        _deposit(user, 1_000_000e6);

        vm.prank(user);
        (uint256 epoch0Id,) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(100_000e6);
        t += 7 days + 1;
        vm.warp(t);
        EpochedQueueModule(address(core)).closeCurrentEpoch();
        EpochedQueueModule(address(core)).fundEpoch(epoch0Id);

        _forceCursor(epoch0Id);

        vm.prank(makeAddr("anyone"));
        EpochedQueueModule(address(core)).syncOldestUnfundedEpoch();
        uint256 healed = EpochedQueueModule(address(core)).oldestUnfundedEpochId();
        assertEq(healed, EpochedQueueModule(address(core)).currentEpochId(), "cursor advanced");

        vm.prank(makeAddr("anyone"));
        EpochedQueueModule(address(core)).syncOldestUnfundedEpoch();
        assertEq(
            EpochedQueueModule(address(core)).oldestUnfundedEpochId(), healed,
            "second call is a no-op"
        );
    }

    /// @dev Write oldestUnfundedEpochId directly. The field sits at offset 6 of
    ///      EpochQueueStorage.Layout (currentEpochId, three mappings,
    ///      escrowedShares, outstandingClaimCount, then this one).
    function _forceCursor(uint256 value) internal {
        vm.store(address(core), bytes32(uint256(EpochQueueStorage.SLOT) + 6), bytes32(value));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // FUNDING OBSERVABILITY: a failed or partial fundEpoch() used to emit
    // nothing, so a stalled epoch was invisible until a user complained.
    // ═══════════════════════════════════════════════════════════════════════

    event EpochFundingShortfall(
        uint256 indexed epochId,
        uint256 needed,
        uint256 freeLiquidity,
        uint256 shortfall
    );
    event EpochFundAttempt(
        uint256 indexed epochId,
        uint256 needed,
        uint256 hotBefore,
        uint256 hotAfter
    );

    function test_fundEpoch_emitsShortfallWhenItCannotFund() public {
        uint256 t = block.timestamp;
        _deposit(user, 1_000_000e6);

        vm.prank(user);
        (uint256 epochId,) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(1_000_000e6);
        t += 7 days + 1;
        vm.warp(t);
        EpochedQueueModule(address(core)).closeCurrentEpoch();

        uint256 owed = EpochedQueueModule(address(core)).epochData(epochId).totalNetAssets;

        // Drain most of the hot balance so the epoch cannot be funded.
        vm.prank(address(core));
        IERC20(USDC_UNDERLYING).transfer(makeAddr("elsewhere"), 900_000e6);
        uint256 hotLeft = IERC20(USDC_UNDERLYING).balanceOf(address(core));

        vm.expectEmit(true, false, false, true, address(core));
        emit EpochFundingShortfall(epochId, owed, hotLeft, owed - hotLeft);
        EpochedQueueModule(address(core)).fundEpoch(epochId);

        assertTrue(
            EpochedQueueModule(address(core)).epochData(epochId).state
                == EpochQueueStorage.EpochState.Closed,
            "epoch stayed closed, and said so"
        );
    }

    function test_fundEpoch_emitsOneAttemptEventWithBothBalances() public {
        uint256 t = block.timestamp;
        _deposit(user, 1_000_000e6);

        vm.prank(user);
        (uint256 epochId,) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(100_000e6);
        t += 7 days + 1;
        vm.warp(t);
        EpochedQueueModule(address(core)).closeCurrentEpoch();

        uint256 owed = EpochedQueueModule(address(core)).epochData(epochId).totalNetAssets;
        uint256 hot = IERC20(USDC_UNDERLYING).balanceOf(address(core));

        vm.recordLogs();
        EpochedQueueModule(address(core)).fundEpoch(epochId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("EpochFundAttempt(uint256,uint256,uint256,uint256)");
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                seen++;
                (uint256 needed, uint256 hotBefore, uint256 hotAfter) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(needed, owed, "needed reported");
                assertEq(hotBefore, hot, "hotBefore populated, not zeroed");
                assertEq(hotAfter, hot, "hotAfter populated, not zeroed");
            }
        }
        assertEq(seen, 1, "exactly one attempt event per call");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // REENTRANCY: every state-changing entry point takes the same guard.
    // fundEpoch in particular calls out to the buffer manager and the router
    // and then re-reads the hot balance to decide whether to mark the epoch
    // FUNDED, so a reentrant call landing in between is the shape that matters.
    // ═══════════════════════════════════════════════════════════════════════

    function test_stateChangingEntryPoints_areAllGuarded() public {
        uint256 t = block.timestamp;
        _deposit(user, 1_000_000e6);

        vm.prank(user);
        (uint256 epochId, uint256 claimId) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(100_000e6);

        // Force the guard flag on, as a reentrant caller would find it.
        _setReentrancyLock(true);

        vm.prank(user);
        vm.expectRevert(EpochedQueueModule.ReentrancyGuardLocked.selector);
        EpochedQueueModule(address(core)).cancelEpochWithdrawal(epochId, claimId);

        vm.expectRevert(EpochedQueueModule.ReentrancyGuardLocked.selector);
        EpochedQueueModule(address(core)).closeCurrentEpoch();

        vm.expectRevert(EpochedQueueModule.ReentrancyGuardLocked.selector);
        EpochedQueueModule(address(core)).fundEpoch(epochId);

        // Released again, the same calls go through.
        _setReentrancyLock(false);
        t += 7 days + 1;
        vm.warp(t);
        EpochedQueueModule(address(core)).closeCurrentEpoch();
        EpochedQueueModule(address(core)).fundEpoch(epochId);

        vm.prank(user);
        uint256 assets = EpochedQueueModule(address(core)).claimEpochAssets(epochId, claimId);
        assertGt(assets, 0, "guard releases cleanly, the claim still pays out");
    }

    /// @dev packedFlags sits at offset 10 of CoreStorage.Layout, after the ten
    ///      one-slot address fields. If that ever shifts, the guard assertions
    ///      below fail rather than passing silently.
    function _setReentrancyLock(bool locked) internal {
        bytes32 slot = bytes32(uint256(CoreStorage.SLOT) + 10);
        uint256 flags = uint256(vm.load(address(core), slot));
        uint256 bit = CoreStorage.FLAG_REENTRANCY_LOCKED;
        vm.store(address(core), slot, bytes32(locked ? flags | bit : flags & ~bit));
    }
}
