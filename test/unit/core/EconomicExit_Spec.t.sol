// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// Withdrawal Model — Economic Exit at Request: acceptance suite.
//
// One test (or more) per invariant W-1..W-15 and per scenario of spec section 11.
// Numbers are chosen so the arithmetic is readable: USDC has 6 decimals, the
// vault mints shares 1:1 at the start, and "gain"/"loss" move the hot balance
// directly (the harness has no strategy, so hot == the portfolio).
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "lib/forge-std/src/Test.sol";
import { Vm } from "lib/forge-std/src/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockUSDC } from "../../helpers/MockUSDC.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";
import { ERC4626Module } from "../../../src/core/modules/ERC4626Module.sol";
import { EpochedQueueModule, EpochQueueStorage } from "../../../src/core/modules/EpochedQueueModule.sol";
import { MockQueueEpochParamsProvider } from "../../sprint-test/QueueEpochModule_WithdrawFlow_POC.t.sol";

contract EconomicExit_Spec_Test is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 constant WAD = 1e18;

    address internal alice;
    address internal bob;
    address internal carol;
    address internal dave;

    CoreHarness internal core;
    MockQueueEpochParamsProvider internal params;
    MockBufferManagerForTests internal bm;
    uint256 internal t; // local clock: block.timestamp is not reliably re-readable mid-test here

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dave = makeAddr("dave");

        MockUSDC mock = new MockUSDC();
        vm.etch(USDC, address(mock).code);

        params = new MockQueueEpochParamsProvider();
        core = new CoreHarness(
            IERC20Metadata(USDC), "USDC Agg", "agUSDC", address(this), address(this), address(params)
        );
        core.setEpochDurationUnsafe(7 days);
        bm = MockBufferManagerForTests(address(core.bufferManager()));
        t = block.timestamp;

        address[4] memory us = [alice, bob, carol, dave];
        for (uint256 i; i < us.length; i++) {
            MockUSDC(USDC).mint(us[i], 10_000_000e6);
            vm.prank(us[i]);
            IERC20(USDC).approve(address(core), type(uint256).max);
        }
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _q() internal view returns (EpochedQueueModule) {
        return EpochedQueueModule(address(core));
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = ERC4626Module(address(core)).deposit(assets, who);
    }

    function _request(address who, uint256 shares) internal returns (uint256 epochId, uint256 claimId) {
        vm.prank(who);
        (epochId, claimId) = _q().requestEpochWithdrawal(shares);
    }

    function _hot() internal view returns (uint256) {
        return IERC20(USDC).balanceOf(address(core));
    }

    function _gain(uint256 a) internal {
        MockUSDC(USDC).mint(address(core), a);
    }

    function _loss(uint256 a) internal {
        vm.prank(address(core));
        IERC20(USDC).transfer(address(0xdead), a);
    }

    function _pps() internal view returns (uint256) {
        uint256 ts = core.totalSupply();
        return ts == 0 ? WAD : core.totalAssets() * WAD / ts;
    }

    /// @dev Hot cash leaves the vault but stays in grossAssets (reported as warm NAV by the mock
    ///      BufferManager): the portfolio is unchanged, only its liquidity shrinks.
    function _moveHotToWarm(uint256 amount) internal {
        vm.prank(address(core));
        IERC20(USDC).transfer(makeAddr("warmAdapter"), amount);
        (uint256 nav,,) = bm.warmNavState();
        bm.setWarmNav(nav + amount, uint40(block.timestamp), true);
    }

    function _closeEpoch() internal {
        t += 7 days + 1;
        vm.warp(t);
        _q().closeCurrentEpoch();
    }

    function _claim(address who, uint256 epochId, uint256 claimId) internal returns (uint256 paid) {
        vm.prank(who);
        paid = _q().claimEpochAssets(epochId, claimId);
    }

    function _claimOf(uint256 e, uint256 c) internal view returns (EpochQueueStorage.EpochClaim memory) {
        return _q().epochClaim(e, c);
    }

    // ═════════════════════════ W-1  totalAssets == max(0, gross − owed) ═════════════════════════

    function test_W1_totalAssets_isGrossMinusOwed_saturating() public {
        uint256 s = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        assertEq(core.totalAssets(), core.grossAssets(), "no liabilities: NAV == gross");

        _request(alice, s);
        assertEq(core.totalOwed(), 1_000e6);
        assertEq(core.totalAssets(), core.grossAssets() - core.totalOwed(), "NAV nets the liability");
        assertEq(core.totalAssets(), 1_000e6);

        _loss(1_500e6); // gross 500 < owed 1000
        assertEq(core.totalAssets(), 0, "saturates at zero, never reverts");
        assertEq(core.totalAssets(), _max0(core.grossAssets(), core.totalOwed()));
    }

    function testFuzz_W1_totalAssets_neverRevertsAndMatchesFormula(uint96 gain, uint96 loss, uint96 exitPct) public {
        uint256 s = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        _request(alice, bound(exitPct, 1, 100) * s / 100);
        _gain(bound(gain, 0, 5_000e6));
        _loss(bound(loss, 0, _hot()));
        assertEq(core.totalAssets(), _max0(core.grossAssets(), core.totalOwed()));
    }

    function _max0(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    // ═════════════════════════ W-2  no pending-claim shares in totalSupply ═════════════════════════

    function test_W2_pendingClaimSharesLeaveTotalSupply() public {
        uint256 s = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        uint256 supplyBefore = core.totalSupply();

        _request(alice, s);

        assertEq(core.balanceOf(alice), 0, "alice holds no shares");
        assertEq(core.balanceOf(address(core)), 0, "nothing escrowed in the vault either");
        assertEq(core.totalSupply(), supplyBefore - s, "burned; no fee configured so all of it");
        assertEq(core.totalSupply(), core.balanceOf(bob), "supply is exactly the remaining holders");
    }

    function test_W2_feeSharesGoToFeeCollector_netSharesBurned() public {
        core.setExitFeesUnsafe(100, 0, 0); // 1%
        uint256 s = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        uint256 fcBefore = core.balanceOf(address(this));
        uint256 supplyBefore = core.totalSupply();

        (uint256 e, uint256 c) = _request(alice, s);

        uint256 fee = core.balanceOf(address(this)) - fcBefore;
        assertEq(fee, s / 100, "fee = witBps of the gross shares");
        assertEq(core.totalSupply(), supplyBefore - (s - fee), "only the NET shares are burned");
        assertEq(_claimOf(e, c).grossShares, s);
    }

    // ═════════════════════════ W-3  insolvency blocks deposits, mints, requests ═════════════════════════

    function _makeInsolvent() internal returns (uint256 e, uint256 c, uint256 shares) {
        shares = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        (e, c) = _request(alice, shares); // owes 1000
        _loss(1_500e6); // gross 500 < owed 1000
        assertTrue(core.isInsolvent());
    }

    function test_W3_insolvency_revertsDepositsMintsAndNewRequests() public {
        _makeInsolvent();
        assertEq(core.totalAssets(), 0);

        vm.prank(carol);
        vm.expectRevert(ERC4626Module.VaultInsolvent.selector);
        ERC4626Module(address(core)).deposit(100e6, carol);

        vm.prank(carol);
        vm.expectRevert(ERC4626Module.VaultInsolvent.selector);
        ERC4626Module(address(core)).mint(100e6, carol);

        vm.prank(carol);
        vm.expectRevert(ERC4626Module.VaultInsolvent.selector);
        ERC4626Module(address(core)).deposit(100e6, carol, 0);

        vm.prank(carol);
        vm.expectRevert(ERC4626Module.VaultInsolvent.selector);
        ERC4626Module(address(core)).mint(100e6, carol, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(EpochedQueueModule.VaultInsolvent.selector);
        _q().requestEpochWithdrawal(1e6);

        vm.prank(bob);
        vm.expectRevert(EpochedQueueModule.VaultInsolvent.selector);
        _q().requestInstantWithdrawal(1e6);

        assertEq(core.maxDeposit(carol), 0, "ERC-4626: maxDeposit is 0 while deposits revert");
    }

    /// @notice grossAssets == totalOwed is solvent but leaves ZERO shareholder equity:
    ///         totalAssets() == 0 there too, so pricing a deposit or an exit would be just as broken.
    function test_W3_zeroEquity_gross_equals_owed_alsoBlocksDepositsAndRequests() public {
        uint256 s = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        _request(alice, s); // owes 1000
        _loss(1_000e6);     // gross 1000 == owed 1000
        assertFalse(core.isInsolvent(), "not insolvent in the spec's sense: gross >= owed");
        assertEq(core.totalAssets(), 0, "but no equity");
        assertEq(core.liabilityIndex(), WAD);

        vm.prank(carol);
        vm.expectRevert(ERC4626Module.VaultInsolvent.selector);
        ERC4626Module(address(core)).deposit(100e6, carol);
        vm.prank(bob);
        vm.expectRevert(EpochedQueueModule.VaultInsolvent.selector);
        _q().requestEpochWithdrawal(1e6);

        // settlement still works and pays in full
        _closeEpoch();
        _q().fundEpoch(0);
        assertEq(_claim(alice, 0, 1), 1_000e6);
    }

    // ═════════════════════════ W-4  reservedForClaims ≤ totalOwed ═════════════════════════

    function test_W4_reservedNeverExceedsOwed_throughFullLifecycle() public {
        uint256 sa = _deposit(alice, 600e6);
        uint256 sb = _deposit(bob, 400e6);
        _deposit(carol, 1_000e6);

        (uint256 e0, uint256 ca) = _request(alice, sa);
        (, uint256 cb) = _request(bob, sb);
        assertLe(_q().reservedForClaims(), core.totalOwed());

        _closeEpoch();
        _q().fundEpoch(e0);
        assertEq(_q().reservedForClaims(), 1_000e6, "the whole epoch's nominal need is earmarked");
        assertLe(_q().reservedForClaims(), core.totalOwed());

        _claim(alice, e0, ca);
        assertLe(_q().reservedForClaims(), core.totalOwed());
        assertEq(_q().reservedForClaims(), 400e6);

        _claim(bob, e0, cb);
        assertEq(_q().reservedForClaims(), 0, "exact round trip: a drained epoch releases exactly what it reserved");
        assertEq(core.totalOwed(), 0);
    }

    // ═════════════════════════ W-5  totalOwed == Σ assetsOwed over unclaimed claims ═════════════════════════

    function test_W5_totalOwed_equalsSumOfUnclaimedAssetsOwed() public {
        uint256 sa = _deposit(alice, 700e6);
        uint256 sb = _deposit(bob, 300e6);
        _deposit(carol, 1_000e6);

        (uint256 e0, uint256 ca) = _request(alice, sa);
        _gain(100e6); // second claim priced at a different price
        (, uint256 cb) = _request(bob, sb);
        _assertOwedMatches(e0, 2);

        _closeEpoch();
        _q().fundEpoch(e0);
        _claim(alice, e0, ca);
        _assertOwedMatches(e0, 2);

        _claim(bob, e0, cb);
        _assertOwedMatches(e0, 2);
        assertEq(core.totalOwed(), 0);
    }

    function _assertOwedMatches(uint256 e, uint256 nClaims) internal view {
        uint256 sum;
        for (uint256 c = 1; c <= nClaims; c++) {
            EpochQueueStorage.EpochClaim memory cl = _claimOf(e, c);
            if (cl.user != address(0) && !cl.claimed) sum += cl.assetsOwed;
        }
        assertEq(core.totalOwed(), sum, "W-5");
    }

    // ═════════════════════════ W-6  an exit does not move the price for remaining holders ═════════════════════════

    function test_W6_exitDoesNotMovePriceForRemainingHolders() public {
        _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        _gain(200e6); // price 1.10
        uint256 ppsBefore = _pps();

        _request(alice, core.balanceOf(alice) / 2);

        // Rounding is in the vault's favour: the remaining holders' price may only tick UP, by dust.
        uint256 ppsAfter = _pps();
        assertGe(ppsAfter, ppsBefore, "price never drops for remaining holders");
        assertLe(ppsAfter - ppsBefore, 1e12, "and moves by rounding dust only");
    }

    /// @notice Order of operations: assetsOwed is computed BEFORE the burn. If the
    ///         burn came first the price would be re-derived from a smaller supply
    ///         (before totalOwed is bumped) and the exiting user would be handed
    ///         MORE than their share. This test fails in that case.
    function test_W6_orderOfOperations_assetsOwedIsPricedBeforeTheBurn() public {
        _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        _gain(200e6); // NAV 2200 over 2000 shares: price 1.10, so a wrong order is visible

        uint256 half = core.balanceOf(alice) / 2;
        uint256 quotedBeforeBurn = core.convertToAssets(half); // ~550 at the pre-request price
        assertApproxEqAbs(quotedBeforeBurn, 550e6, 2);

        (uint256 e, uint256 c) = _request(alice, half);

        assertEq(_claimOf(e, c).assetsOwed, quotedBeforeBurn, "priced at the pre-burn price");
        assertEq(core.totalOwed(), quotedBeforeBurn);

        // Had the burn come first: price would be 2200/1500 = 1.4667 -> 733. Guard the gap explicitly.
        assertLt(_claimOf(e, c).assetsOwed, 700e6, "would be ~733 if the burn preceded the pricing");
    }

    // ═════════════════════════ W-7 / W-8  post-request NAV moves accrue to remaining holders only ═════════════════════════

    function test_W7_gainAfterRequest_accruesOnlyToRemainingHolders() public {
        _deposit(alice, 100e6);
        uint256 sb = _deposit(bob, 100e6);
        (uint256 e, uint256 c) = _request(alice, core.balanceOf(alice)); // exits at 1.0 with 100 owed

        _gain(20e6); // vault gains 20

        // Bob (the only remaining holder) captures all of it: 200 gross - 100 owed = 120 for his shares.
        assertApproxEqAbs(core.convertToAssets(sb), 120e6, 2, "remaining holder owns the whole gain");

        _closeEpoch();
        _q().fundEpoch(e);
        assertEq(_claim(alice, e, c), 100e6, "the exited user is paid the fixed amount, not a cent of the gain");
    }

    function test_W8_lossAfterRequest_isBorneOnlyByRemainingHolders_whileSolvent() public {
        _deposit(alice, 100e6);
        uint256 sb = _deposit(bob, 100e6);
        (uint256 e, uint256 c) = _request(alice, core.balanceOf(alice));

        _loss(30e6); // 200 -> 170, still >= owed 100: solvent

        assertFalse(core.isInsolvent());
        assertEq(core.liabilityIndex(), WAD, "solvent: index is exactly 1e18");
        assertApproxEqAbs(core.convertToAssets(sb), 70e6, 2, "remaining holder absorbs the whole loss");

        _closeEpoch();
        _q().fundEpoch(e);
        assertEq(_claim(alice, e, c), 100e6, "exited user still paid in full");
    }

    /// @notice The example of spec section 2: 100 USDC / 100 shares, 50 exit, vault gains 10.
    function test_spec_section2_example_publishedPriceIsNowTheRealPrice() public {
        _deposit(alice, 50e6);
        _deposit(bob, 50e6);
        _request(alice, core.balanceOf(alice)); // 50 owed
        _gain(10e6);

        // Old model published 1.10 while the real price for the 50 remaining holders was 1.20.
        assertEq(_pps(), 1.2e18, "published price == real price for the remaining holders");
    }

    // ═════════════════════════ W-9  assetsOwed never changes after request ═════════════════════════

    function test_W9_assetsOwed_isImmutableAcrossNavMovesCloseFundAndPartialClaims() public {
        _deposit(alice, 500e6);
        _deposit(bob, 500e6);
        (uint256 e, uint256 c) = _request(alice, core.balanceOf(alice));
        uint256 owed0 = _claimOf(e, c).assetsOwed;

        _gain(300e6);
        assertEq(_claimOf(e, c).assetsOwed, owed0);
        _loss(200e6);
        assertEq(_claimOf(e, c).assetsOwed, owed0);
        _closeEpoch();
        assertEq(_claimOf(e, c).assetsOwed, owed0);
        _q().fundEpoch(e);
        assertEq(_claimOf(e, c).assetsOwed, owed0);
        assertEq(_claim(alice, e, c), owed0);
        assertEq(_claimOf(e, c).assetsOwed, owed0, "record survives the claim");
    }

    // ═════════════════════════ W-10  no cancel / modify / transfer / re-price ═════════════════════════

    function test_W10_everyFormerCancelPathReverts() public {
        uint256 s = _deposit(alice, 1_000e6);
        (uint256 e, uint256 c) = _request(alice, s);

        // Open epoch, closed epoch, funded epoch: the selector is gone in all of them.
        _assertCancelReverts(alice, e, c);
        _closeEpoch();
        _assertCancelReverts(alice, e, c);
        _q().fundEpoch(e);
        _assertCancelReverts(alice, e, c);
        // Nor does a queued-request pause reopen a path.
        core.pauseQueuedRequestOnly(true);
        _assertCancelReverts(alice, e, c);

        assertEq(core.balanceOf(alice), 0);
        assertEq(core.totalOwed(), 1_000e6);
    }

    function _assertCancelReverts(address who, uint256 e, uint256 c) internal {
        vm.prank(who);
        (bool ok,) = address(core).call(abi.encodeWithSignature("cancelEpochWithdrawal(uint256,uint256)", e, c));
        assertFalse(ok, "cancelEpochWithdrawal must not exist");
    }

    function test_W10_acceptedClaimCannotBeTakenOrReplayedByAnyoneElse() public {
        uint256 s = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        (uint256 e, uint256 c) = _request(alice, s);
        _closeEpoch();
        _q().fundEpoch(e);

        vm.prank(bob);
        vm.expectRevert(EpochedQueueModule.NotClaimOwner.selector);
        _q().claimEpochAssets(e, c);

        _claim(alice, e, c);
        vm.prank(alice);
        vm.expectRevert(EpochedQueueModule.ClaimAlreadySettled.selector);
        _q().claimEpochAssets(e, c);
    }

    // ═════════════════════════ W-11  views never revert on underflow, in any state ═════════════════════════

    function test_W11_viewsNeverRevert_inInsolvency() public {
        (, , uint256 s) = _makeInsolvent();
        assertEq(core.totalAssets(), 0);
        core.convertToShares(1_000e6);
        core.convertToAssets(s);
        core.previewDeposit(1_000e6);
        core.previewMint(1_000e6);
        core.previewWithdraw(1_000e6);
        core.previewRedeem(s);
        core.maxDeposit(bob);
        core.maxMint(bob);
        core.grossAssets();
        core.totalOwed();
        core.liabilityIndex();
        core.isInsolvent();
        core.totalAssetsBreakdown();
        core.canRealize();
        core.canCrystallize();
    }

    function testFuzz_W11_viewsNeverRevert(uint96 loss, uint96 amount) public {
        _deposit(alice, 1_000e6);
        uint256 sb = _deposit(bob, 1_000e6);
        _request(alice, core.balanceOf(alice));
        _loss(bound(loss, 0, _hot()));
        uint256 a = bound(amount, 0, 1_000_000e6);
        core.totalAssets();
        core.convertToShares(a);
        core.convertToAssets(a);
        core.previewDeposit(a);
        core.previewMint(a);
        core.previewWithdraw(a);
        core.previewRedeem(sb);
    }

    // ═════════════════════════ W-12  same request, same assetsOwed: instant or queued ═════════════════════════

    function test_W12_sameAssetsOwed_whetherSettledInstantlyOrQueued() public {
        core.setExitFeesUnsafe(100, 0, 0);
        uint256 s = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        _gain(100e6);
        uint256 snap = vm.snapshotState();

        // (a) standard queue
        (uint256 e, uint256 c) = _request(alice, s / 2);
        uint256 queuedOwed = _claimOf(e, c).assetsOwed;

        // (b) instant, settles immediately
        vm.revertToState(snap);
        vm.prank(alice);
        (bool instant,,) = _q().requestInstantWithdrawal(s / 2);
        assertTrue(instant);
        uint256 paidNow = IERC20(USDC).balanceOf(alice) - (10_000_000e6 - 1_000e6);
        assertEq(paidNow, queuedOwed, "instant pays exactly the amount a queued request would owe");
        assertEq(core.totalOwed(), 0, "and the liability is discharged in the same tx");

        // (c) instant that falls back into the queue. Deposit lock is now a hard revert on
        // both exit paths (review: Pier), so an exhausted cap forces the fallback instead.
        vm.revertToState(snap);
        params.setCapPerEpochBps(1);
        vm.prank(alice);
        (bool instant2, uint256 fe, uint256 fc) = _q().requestInstantWithdrawal(s / 2);
        assertFalse(instant2);
        assertEq(_claimOf(fe, fc).assetsOwed, queuedOwed, "fallback carries exactly the request-time assetsOwed");
    }

    /// @notice The fee tier is decided BEFORE crystallizing (review: Stefano), so a request
    ///         that falls back into the queue pays the STANDARD fee, not the instant one --
    ///         unlike the previous behaviour (documented as a deliberate deviation), which
    ///         always crystallized as INSTANT first and so overcharged every fallback.
    function test_W12_fallback_paysTheStandardFee_notTheInstantOne() public {
        core.setExitFeesUnsafe(100, 500, 0); // witBps 1%, instant penalty +5%, no force penalty
        uint256 s = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        params.setCapPerEpochBps(1); // exhausted: every instant call falls back

        vm.prank(alice);
        (bool settled, uint256 e, uint256 c) = _q().requestInstantWithdrawal(s / 2);
        assertFalse(settled, "cap exhausted -> fallback");

        uint256 owed = _claimOf(e, c).assetsOwed;
        // At 1% (standard) the net is ~99% of gross; at 6% (instant tier) it would be ~94%.
        // A fallback that had wrongly crystallized as INSTANT would owe visibly less.
        assertApproxEqAbs(owed, 495e6, 2e6, "priced at the STANDARD 1% fee, not the INSTANT 6%");
    }

    // ═════════════════════════ W-13 / W-14 pro-rata index ═════════════════════════

    /// @dev alice 600 (epoch 0) and bob 400 + carol 100 (epoch 1), all funded while solvent; then a loss.
    /// @dev Both epochs are closed but NOT YET funded when the loss lands. Only e0 is funded
    ///      here: Option A's crystallization writes e0's haircut out of totalOwed the instant it
    ///      is funded, which makes e1's live-index-based target OVERSHOOT the shared physical
    ///      pool (still unmoved -- nothing has been claimed yet) until e0's cash is actually
    ///      paid out. e1 can only be funded, by the caller, after alice claims e0.
    function _fundedThenLoss()
        internal
        returns (uint256 e0, uint256 ca, uint256 e1, uint256 cb, uint256 cc)
    {
        uint256 sa = _deposit(alice, 600e6);
        uint256 sb = _deposit(bob, 400e6);
        uint256 sc = _deposit(carol, 100e6);
        _deposit(dave, 900e6);

        (e0, ca) = _request(alice, sa);
        _closeEpoch();

        (e1, cb) = _request(bob, sb);
        uint256 e1b;
        (e1b, cc) = _request(carol, sc);
        assertEq(e1, e1b);
        _closeEpoch();

        _loss(1_400e6); // hot 2000 -> 600 vs owed 1100, before either epoch is funded/crystallized
        assertTrue(core.isInsolvent());

        _q().fundEpoch(e0);
        assertTrue(_q().epochData(e0).state == EpochQueueStorage.EpochState.Funded);
    }

    /// @notice Option A: each epoch crystallizes its OWN recoveryIndex, at fund time, from what
    ///         was actually available then -- not one shared global index (see
    ///         test_s11_insolvency_fullScenario for a case where two epochs' ratios diverge
    ///         further). Here e1 can only fund once alice's claim has actually released e0's
    ///         cash, at which point the SAME ratio recurs (algebraically exact with only two
    ///         parties sharing one pool). W-13: claiming from a cohort never moves its
    ///         (immutable) index. W-14: every claim WITHIN the same epoch pays that epoch's
    ///         identical index.
    function test_W13_W14_fundedClaimsAcrossEpochs_getTheSameIndex_andClaimingDoesNotMoveIt() public {
        (uint256 e0, uint256 ca, uint256 e1, uint256 cb, uint256 cc) = _fundedThenLoss();

        uint256 index0 = _q().epochData(e0).recoveryIndex;
        // Two floors deep (target sizing, then the ratio derived from what was actually
        // reserved), so this lands a hair under the pure division, never over.
        assertApproxEqAbs(index0, 600e6 * WAD / 1_100e6, 1e9, "crystallized from the pre-crystallization global ratio");
        assertLt(index0, WAD);

        uint256 paidA = _claim(alice, e0, ca);
        assertEq(paidA, 600e6 * index0 / WAD, "alice (epoch 0) paid at epoch 0's crystallized index");
        assertEq(_q().epochData(e0).recoveryIndex, index0, "W-13: claiming does not move the index");

        // Only now can epoch 1 fund: its target overshot the shared pool while alice's
        // crystallized-but-unclaimed liability was still counted in totalOwed (see
        // _fundedThenLoss).
        _q().fundEpoch(e1);
        assertTrue(_q().epochData(e1).state == EpochQueueStorage.EpochState.Funded);
        uint256 index1 = _q().epochData(e1).recoveryIndex;
        assertApproxEqAbs(index1, index0, 1e9, "the same ratio recurs once e0's cash actually left");

        uint256 paidB = _claim(bob, e1, cb);
        assertApproxEqAbs(paidB, 400e6 * index0 / WAD, 1e3, "bob (epoch 1) paid at epoch 1's crystallized index");
        assertEq(_q().epochData(e1).recoveryIndex, index1, "W-13 again after the second claim");

        uint256 paidC = _claim(carol, e1, cc);
        // W-14: within the SAME epoch (cohort), every claim pays the identical crystallized index.
        assertApproxEqAbs(paidB, 400e6 * index0 / WAD, 1e3, "epoch 1");
        assertApproxEqAbs(paidC, 100e6 * index0 / WAD, 1e3, "epoch 1, second claim");
        assertEq(core.totalOwed(), 0);
    }

    function test_W13_batchClaim_paysEveryClaimAtOneIndex() public {
        (uint256 e0, uint256 ca, uint256 e1, uint256 cb, uint256 cc) = _fundedThenLoss();
        // e1 can only fund once alice's claim on e0 has actually released its cash (see
        // _fundedThenLoss); do that first, exactly as test_W13_W14_... does.
        _claim(alice, e0, ca);
        _q().fundEpoch(e1);
        assertTrue(_q().epochData(e1).state == EpochQueueStorage.EpochState.Funded);
        uint256 index1 = _q().epochData(e1).recoveryIndex;

        // bob & carol are different users: batch only claims the caller's own; claim bob's via batch
        uint256[] memory ids = new uint256[](1);
        ids[0] = cb;
        vm.prank(bob);
        uint256 paid = _q().batchClaimEpochAssets(e1, ids);
        assertEq(paid, 400e6 * index1 / WAD);
        assertEq(_q().epochData(e1).recoveryIndex, index1, "W-13 batch: claiming does not move the immutable index");
        cc;
    }

    // ═════════════════════════ W-15  no module reconstructs NAV locally ═════════════════════════

    function test_W15_consumersReadThePrimitives_grossAndNetAgree() public {
        uint256 s = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        _request(alice, s);

        (uint256 nav, uint256 hot, uint256 warm) = core.totalAssetsBreakdown();
        assertEq(nav, core.grossAssets(), "breakdown.nav is the class-A primitive");
        assertEq(nav, hot + warm, "no strategy in the harness");
        assertLt(core.totalAssets(), core.grossAssets(), "and it is NOT net of totalOwed");
    }

    /// @notice The single-source-of-truth rule, checked mechanically: the physical
    ///         portfolio is only ever summed (hot + strategies + warm) inside the
    ///         CoreVault shell; no module sums it, and none subtracts totalOwed.
    function test_W15_noModuleReconstructsNavLocally() public view {
        string[13] memory modules = [
            "AdminModule", "BatchGuardrails", "BufferManager", "EpochedQueueModule", "ERC4626Module",
            "ExecutionMemory", "FeeCollector", "FixedMaturityModule", "Incentives", "IncentivesEngine",
            "LiquidityOpsModule", "StrategyRouter", "PriceOracleMiddleware"
        ];
        for (uint256 i; i < modules.length; i++) {
            string memory src = vm.readFile(string.concat("src/core/modules/", modules[i], ".sol"));
            assertFalse(_contains(src, "hot + strat + warm"), string.concat(modules[i], ": sums the portfolio locally"));
            // StrategyRouter is where strategy NAV is defined; everyone else must go through the vault.
            if (i != 11) {
                assertFalse(_contains(src, "totalStrategyAssetsSafe"), string.concat(modules[i], ": reads strategy NAV directly"));
            }
        }
        string memory vault = vm.readFile("src/core/CoreVault.sol");
        assertTrue(_contains(vault, "hot + strat + warm"), "the shell is the one place it is defined");
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    // ═════════════════════════ Section 11 scenarios ═════════════════════════

    function test_s11_depositDuringPendingExits_newDepositorGetsSharesAtTheCorrectPrice() public {
        _deposit(alice, 50e6);
        _deposit(bob, 50e6);
        _request(alice, core.balanceOf(alice)); // 50 owed
        _gain(10e6); // price for the 50 remaining shares: (110 - 50) / 50 = 1.20

        uint256 shares = _deposit(carol, 60e6);
        assertEq(shares, 50e6, "60 USDC at price 1.20 buys 50 shares, not 54.5 at the old 1.10");
        assertEq(_pps(), 1.2e18, "and the price is unchanged by the deposit");
    }

    function test_s11_performanceFee_crystallisesOnNavNetOfTotalOwed() public {
        core.setPerfParamsUnsafe(2_000e14, 0); // 20% performance fee, no min interval
        _deposit(alice, 50e6);
        _deposit(bob, 50e6);
        _request(alice, core.balanceOf(alice)); // 50 owed: NAV net = 50 for 50 shares
        _gain(10e6); // real profit for the remaining holders: 10

        uint256 fcBefore = core.balanceOf(address(this));
        vm.recordLogs();
        _q().endEpochCrystallize();

        // profit is measured on (110 - 50) - 1.0 * 50 = 10, NOT on 110 - 50 = 60 (gross NAV vs old HWM).
        uint256 feeShares = core.balanceOf(address(this)) - fcBefore;
        uint256 feeAssets = core.convertToAssets(feeShares);
        // 20% of the 10 USDC profit, diluted by its own minting (~1.94). Had it read gross NAV the
        // profit would have been 60 and the fee ~12.
        assertGt(feeAssets, 1.5e6);
        assertLt(feeAssets, 2.5e6);
    }

    /// @notice A request attempts a best-effort self-heal (same as deposit/mint) before the
    ///         strict age check. That must not make the gate toothless: if the keeper is
    ///         genuinely dead -- here, the refresh call itself fails, standing in for a broken
    ///         adapter or a reverting BufferManager -- the cache stays exactly as stale as it
    ///         was, and the request still correctly reverts on age.
    function test_s11_staleNav_requestRevertsEvenWhenWarmNavValidIsTrue() public {
        uint256 s = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);

        // valid == true, but the cache is 16 minutes old (MAX_WARM_NAV_AGE is 15), and the
        // keeper is unable to fix it (refresh itself fails -- swallowed by the try/catch).
        t += 16 minutes;
        vm.warp(t);
        bm.setWarmNav(0, uint40(t - 16 minutes), true);
        bm.setRefreshShouldRevert(true);
        (, uint40 ts, bool valid) = bm.warmNavState();
        assertTrue(valid);
        assertGt(block.timestamp - ts, 15 minutes);

        vm.prank(alice);
        vm.expectRevert(EpochedQueueModule.NavStale.selector);
        _q().requestEpochWithdrawal(s);

        vm.prank(alice);
        vm.expectRevert(EpochedQueueModule.NavStale.selector);
        _q().requestInstantWithdrawal(s);

        // The cache being merely stale-but-fixable is different: here the keeper CAN refresh
        // (the request's own soft-refresh attempt succeeds), so it is accepted without anyone
        // needing to call refreshWarmNav() separately first.
        bm.setRefreshShouldRevert(false);
        bm.setRefreshResult(0, uint40(t), true);
        _request(alice, s);
    }

    function test_s11_invalidNav_requestReverts() public {
        uint256 s = _deposit(alice, 1_000e6);
        bm.setWarmNav(0, uint40(block.timestamp), false);
        vm.prank(alice);
        vm.expectRevert(EpochedQueueModule.NavInvalid.selector);
        _q().requestEpochWithdrawal(s);
    }

    /// @notice Option A (review: Multyr, PR #19 second round -- "creditor parity after
    ///         recovery"): a cohort funded WHILE SOLVENT crystallizes recoveryIndex = 1e18 and is
    ///         immutable from then on -- it is immune to a loss that lands afterward. Alice's
    ///         epoch is funded before the loss and is paid in full; carol's epoch, still closed
    ///         when the loss lands, absorbs the entire remaining shortfall alone once it is
    ///         funded afterward.
    function test_s11_insolvency_fullScenario() public {
        // alice 600 -> epoch 0 (funded while solvent)
        uint256 sa = _deposit(alice, 600e6);
        uint256 sd = _deposit(dave, 1_400e6);
        _deposit(carol, 200e6);
        (uint256 e0, uint256 ca) = _request(alice, sa);
        _closeEpoch();
        _q().fundEpoch(e0);
        assertEq(_q().epochData(e0).recoveryIndex, WAD, "funded while solvent: full nominal crystallized");

        // carol 200 -> epoch 1 (closed, not yet funded)
        (uint256 e1, uint256 cc) = _request(carol, core.balanceOf(carol));
        _closeEpoch();

        // loss of 1500: gross 2200 -> 700 < owed 800
        _loss(1_500e6);
        assertTrue(core.isInsolvent());
        assertEq(core.totalAssets(), 0, "totalAssets() == 0 without reverting");
        assertEq(core.grossAssets(), 700e6);

        // deposits and requests revert
        vm.prank(bob);
        vm.expectRevert(ERC4626Module.VaultInsolvent.selector);
        ERC4626Module(address(core)).deposit(10e6, bob);
        vm.prank(dave);
        vm.expectRevert(EpochedQueueModule.VaultInsolvent.selector);
        _q().requestEpochWithdrawal(sd);

        // settlement keeps working. Epoch 1 needs 200 * liveIndex = 175, but alice's epoch still
        // holds its untouchable 600 earmark, so it cannot be funded yet (no revert, just not yet).
        _q().fundEpoch(e1);
        assertTrue(_q().epochData(e1).state == EpochQueueStorage.EpochState.Closed);
        vm.prank(carol);
        vm.expectRevert(EpochedQueueModule.EpochNotFunded.selector);
        _q().claimEpochAssets(e1, cc);

        // alice (funded while solvent, recoveryIndex crystallized at 1e18) is immune to the loss:
        // paid in full, and her whole earmark is released once claimed.
        uint256 paid = _claim(alice, e0, ca);
        assertEq(paid, 600e6, "funded-while-solvent cohort is immune to a loss that lands afterward");
        assertEq(_q().epochData(e0).recoveryIndex, WAD, "W-13: immutable");
        assertEq(_q().reservedForClaims(), 0, "her whole earmark was released");

        // Only now does anything remain for carol's epoch to fund from: gross fell to whatever
        // alice's full payout left behind, and carol's 200 nominal absorbs the shortfall alone.
        _q().fundEpoch(e1);
        assertTrue(_q().epochData(e1).state == EpochQueueStorage.EpochState.Funded, "funds at whatever recovery ratio is left");
        uint256 carolIndex = _q().epochData(e1).recoveryIndex;
        assertLt(carolIndex, WAD, "carol absorbs the loss alice was protected from");

        uint256 paidC = _claim(carol, e1, cc);
        assertApproxEqRel(paidC, 200e6 * carolIndex / WAD, 1e12);
        assertEq(_q().epochData(e1).recoveryIndex, carolIndex, "W-13: immutable");
        assertEq(core.totalOwed(), 0);
    }

    /// @notice Option A: once a cohort is crystallized, a recovery afterward is NOT owed to it --
    ///         it flows to remaining shareholders instead. A claim funded at a low index still
    ///         pays exactly that crystallized ratio even after assets fully come back; nothing
    ///         is topped up.
    function test_s11_recoveryAfterFunding_doesNotTopUp() public {
        uint256 sa = _deposit(alice, 600e6);
        _deposit(dave, 1_400e6);
        (uint256 e0, uint256 ca) = _request(alice, sa);
        _closeEpoch();
        _loss(1_700e6); // gross 300 < owed 600: index 0.5
        assertEq(core.liabilityIndex(), WAD / 2);

        _q().fundEpoch(e0); // crystallizes recoveryIndex = 0.5 * 600 = 300, not an impossible 600
        assertTrue(_q().epochData(e0).state == EpochQueueStorage.EpochState.Funded);
        assertEq(_q().reservedForClaims(), 300e6);
        assertEq(_q().epochData(e0).recoveryIndex, WAD / 2);

        _gain(1_000e6); // a recovery -- NOT owed to this already-crystallized cohort
        assertFalse(core.isInsolvent());
        assertEq(_q().epochData(e0).recoveryIndex, WAD / 2, "immutable: never re-crystallized");
        assertEq(_claim(alice, e0, ca), 300e6, "paid the crystallized share, not topped up to nominal");
        assertEq(_q().reservedForClaims(), 0);
    }

    /// @notice The example from the design discussion: owed 50, assets 30 -> every claim gets 60%,
    ///         whatever the claim order, with no first-claimer advantage.
    function test_s11_insolvency_proRata_orderIndependent() public {
        uint256 sa = _deposit(alice, 30e6);
        uint256 sb = _deposit(bob, 20e6);
        _deposit(dave, 50e6);
        (uint256 e, uint256 ca) = _request(alice, sa);
        (, uint256 cb) = _request(bob, sb); // same epoch, owed 30 + 20 = 50
        _closeEpoch();
        _loss(70e6); // gross 100 -> 30 < owed 50
        assertEq(core.liabilityIndex(), 30e6 * WAD / 50e6);

        _q().fundEpoch(e); // funds at 30, not the impossible 50
        assertTrue(_q().epochData(e).state == EpochQueueStorage.EpochState.Funded);

        // bob (the smaller, LATER claim) goes first
        uint256 paidB = _claim(bob, e, cb);
        uint256 paidA = _claim(alice, e, ca);
        assertApproxEqAbs(paidB, 12e6, 2, "20 * 60%");
        assertApproxEqAbs(paidA, 18e6, 2, "30 * 60%");
        assertApproxEqAbs(paidA + paidB, 30e6, 4, "everything available, nothing more");
    }

    /// @notice Real lending adapters cannot return the last wei of a position (fork finding: a
    ///         1,218,285-unit realise returned 1,213,315). In insolvency the whole portfolio is owed,
    ///         so a strict "hot >= need" would leave the epoch unfundable by dust. A shortfall within
    ///         INSOLVENCY_FUNDING_DUST_BPS (10 bps) funds; a real illiquid remainder does not.
    function test_s11_insolvencyFunding_toleratesDust_butNotARealIlliquidRemainder() public {
        uint256 sa = _deposit(alice, 600e6);
        _deposit(dave, 1_400e6);
        (uint256 e, uint256 c) = _request(alice, sa);
        _closeEpoch();
        _loss(1_700e6); // gross 300 vs owed 600: index 0.5

        // 0.05% of the portfolio is stuck outside hot (warm/strategy dust): within tolerance
        _moveHotToWarm(0.15e6);
        _q().fundEpoch(e);
        assertTrue(_q().epochData(e).state == EpochQueueStorage.EpochState.Funded, "dust shortfall funds");
        assertLe(_q().reservedForClaims(), _hot(), "the earmark never promises cash that is not there");
        uint256 paid = _claim(alice, e, c);
        assertApproxEqAbs(paid, 300e6, 0.2e6, "paid the recovery ratio, short by at most the dust");
    }

    /// @notice Review (Stefano): measures the WORST-CASE dust drift precisely, in bps, so
    ///         Multyr can sign off on the exact number INSOLVENCY_FUNDING_DUST_BPS = 10 allows.
    ///         At the boundary -- hot short by exactly 0.1% of the epoch's target reserve --
    ///         funding still succeeds, and the claimant realizes exactly 10 bps less than the
    ///         formula `assetsOwed * grossAssets / totalOwed` would give them. Any shortfall
    ///         one wei larger stays unfunded (proven by the sibling test right below).
    /// @notice Review ("to complete", scenario with five claimants): the same pro-rata
    ///         guarantee tested with 2 claimants elsewhere holds at 5 -- every claimant gets the
    ///         identical recovery ratio regardless of claim size or the order they claim in.
    function test_s11_insolvency_fiveClaimants_allGetTheIdenticalRatio_anyOrder() public {
        address e1 = makeAddr("e1");
        address e2 = makeAddr("e2");
        address e3 = makeAddr("e3");
        address e4 = makeAddr("e4");
        address e5 = makeAddr("e5");
        uint256[5] memory amts = [uint256(500e6), 300e6, 1_200e6, 50e6, 950e6]; // sum = 3,000
        address[5] memory us = [e1, e2, e3, e4, e5];
        uint256[5] memory shares;
        uint256[5] memory owed;
        uint256[5] memory claimIds;
        uint256 epochId;

        for (uint256 i; i < 5; i++) {
            MockUSDC(USDC).mint(us[i], amts[i] + 1);
            vm.prank(us[i]);
            IERC20(USDC).approve(address(core), type(uint256).max);
            shares[i] = _deposit(us[i], amts[i]);
        }
        _deposit(dave, 7_000e6); // stays in, absorbs the eventual loss

        for (uint256 i; i < 5; i++) {
            (epochId, claimIds[i]) = _request(us[i], shares[i]);
            owed[i] = _q().epochClaim(epochId, claimIds[i]).assetsOwed;
        }
        uint256 totalOwedAtRequest = owed[0] + owed[1] + owed[2] + owed[3] + owed[4];
        assertApproxEqAbs(totalOwedAtRequest, 3_000e6, 5, "sum of the five claims");
        _closeEpoch();

        // Catastrophic loss: 40% recovery ratio.
        uint256 gross0 = core.grossAssets();
        _loss(gross0 - totalOwedAtRequest * 4 / 10);
        assertTrue(core.isInsolvent());
        uint256 index = core.liabilityIndex();
        assertApproxEqRel(index, 0.4e18, 1e12);

        _q().fundEpoch(epochId);
        assertTrue(_q().epochData(epochId).state == EpochQueueStorage.EpochState.Funded);

        // Claim in a deliberately scrambled order: 3rd, 1st, 5th, 2nd, 4th.
        uint256[5] memory claimOrder = [uint256(2), 0, 4, 1, 3];
        for (uint256 k; k < 5; k++) {
            uint256 i = claimOrder[k];
            uint256 paid = _claim(us[i], epochId, claimIds[i]);
            assertApproxEqRel(paid, owed[i] * index / WAD, 1e12, "every claimant, any position in the order, gets the same ratio");
        }
        assertEq(core.totalOwed(), 0);
        assertEq(_q().reservedForClaims(), 0);
    }

    function test_s11_insolvencyFunding_dustTolerance_worstCaseDriftIsExactlyTenBps() public {
        uint256 sa = _deposit(alice, 1_000_000e6);
        _deposit(dave, 1_000_000e6);
        (uint256 e, uint256 c) = _request(alice, sa); // owed 1,000,000
        _closeEpoch();
        _loss(1_500_000e6); // gross 500,000 vs owed 1,000,000: exact index 0.5

        uint256 idealPayout = 1_000_000e6 * 5 / 10; // 500,000, at the exact (undropped) index
        // Read the constant off a bare (unwired) module instance -- constants are the same
        // regardless of deployment, and this avoids needing the selector routed through the
        // vault's dispatch just for this one read.
        uint256 dustBps = (new EpochedQueueModule()).INSOLVENCY_FUNDING_DUST_BPS();
        uint256 worstCaseShortfall = idealPayout * dustBps / 10_000; // 500
        assertEq(worstCaseShortfall, 500e6, "10 bps of the 500,000 target is exactly 500");

        // Push hot down to precisely the boundary the dust tolerance allows.
        _moveHotToWarm(worstCaseShortfall);

        _q().fundEpoch(e);
        assertTrue(_q().epochData(e).state == EpochQueueStorage.EpochState.Funded, "funds exactly at the boundary");
        assertEq(_q().reservedForClaims(), idealPayout - worstCaseShortfall, "earmark short by exactly the dust");

        uint256 paid = _claim(alice, e, c);
        assertEq(paid, idealPayout - worstCaseShortfall, "paid short by exactly the dust, not a wei more");

        // State the drift the way Multyr needs to sign off on it: in basis points of the
        // amount the pro-rata formula would otherwise have given this claimant.
        uint256 driftBps = (idealPayout - paid) * 10_000 / idealPayout;
        assertEq(driftBps, dustBps, "worst-case realized drift == INSOLVENCY_FUNDING_DUST_BPS, exactly");
    }

    function test_s11_insolvencyFunding_illiquidRemainderBeyondTolerance_staysClosed() public {
        uint256 sa = _deposit(alice, 600e6);
        _deposit(dave, 1_400e6);
        (uint256 e,) = _request(alice, sa);
        _closeEpoch();
        _loss(1_700e6);

        _moveHotToWarm(30e6); // 10% of the remaining portfolio is illiquid: a real shortfall
        _q().fundEpoch(e);
        assertTrue(_q().epochData(e).state == EpochQueueStorage.EpochState.Closed, "a real shortfall does not fund");
    }

    function test_s11_forceExit_inInsolvency_returnsNothing_burnsNothing_revertsForNoOtherReason() public {
        _makeInsolvent();
        uint256 bobShares = core.balanceOf(bob);
        uint256 supply = core.totalSupply();

        vm.prank(bob);
        uint256 got = ERC4626Module(address(core)).forceWithdrawAll(bob, 0);
        assertEq(got, 0, "nothing to withdraw");
        assertEq(core.balanceOf(bob), bobShares, "bob's residual shares are untouched");
        assertEq(core.totalSupply(), supply, "nothing burned, no fee taken");

        // asking for a non-zero minimum is the caller's own slippage bound
        vm.prank(bob);
        vm.expectRevert(ERC4626Module.SlippageExceeded.selector);
        ERC4626Module(address(core)).forceWithdrawAll(bob, 1);
    }

    function test_s11_insolvencyEvents_enteredAndExited() public {
        (uint256 e,) = (0, 0);
        uint256 s = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        (e,) = _request(alice, s);
        _loss(1_500e6);

        vm.expectEmit(false, false, false, true, address(core));
        emit EpochedQueueModule.InsolvencyEntered(500e6, 1_000e6, 500e6 * WAD / 1_000e6);
        _q().syncInsolvencyState();

        _gain(1_000e6);
        vm.expectEmit(false, false, false, true, address(core));
        emit EpochedQueueModule.InsolvencyExited(1_500e6, 1_000e6);
        _q().syncInsolvencyState();
        e;
    }

    function test_s11_closeAndFundSetNoPrice_epochCarriesNoPps() public {
        _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        (uint256 e, uint256 c) = _request(alice, 500e6);
        uint256 owed = _claimOf(e, c).assetsOwed;
        _gain(500e6); // a NAV move between request and close must not touch the claim

        _closeEpoch();
        EpochQueueStorage.EpochData memory ed = _q().epochData(e);
        assertEq(ed.totalAssetsOwed, owed, "the bucket sums request-time liabilities; nothing was re-priced at close");

        _q().fundEpoch(e);
        assertEq(_q().reservedForClaims(), owed);
    }

    function test_s11_noWithdrawalMinimum() public {
        params.setMinClaimAmount(1_000e6); // ignored: the minimum applies to deposits only
        uint256 s = _deposit(alice, 1_000e6);
        _request(alice, 1);
        _request(alice, s / 2);
    }

    // ═════════════════════ NAV validity gate: the WHOLE economic NAV, not one timestamp ═════════════════════

    function _withRouter(uint256 assets, uint8 issue) internal returns (MockNavRouter r) {
        r = new MockNavRouter(assets, issue);
        core.setStrategyRouterUnsafe(address(r));
    }

    function test_navGate_validInputs_requestAccepted() public {
        uint256 s = _deposit(alice, 1_000e6);
        _withRouter(0, 0);
        (bool valid, uint8 reason) = core.navStatus();
        assertTrue(valid);
        assertEq(reason, 0);
        _request(alice, s);
    }

    function test_navGate_strategyValuationFailed_rejectsStandardAndInstant() public {
        uint256 s = _deposit(alice, 1_000e6);
        _withRouter(0, 4); // e.g. an adapter's totalAssets() reverts: NAV would be understated
        (bool valid, uint8 reason) = core.navStatus();
        assertFalse(valid);
        assertEq(reason, 4);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EpochedQueueModule.NavInputInvalid.selector, uint8(4)));
        _q().requestEpochWithdrawal(s);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EpochedQueueModule.NavInputInvalid.selector, uint8(4)));
        _q().requestInstantWithdrawal(s);
        assertEq(core.totalOwed(), 0, "no liability was crystallized");
        assertEq(core.balanceOf(alice), s, "and the user is still a shareholder");
    }

    function test_navGate_unhealthyStrategy_rejects() public {
        uint256 s = _deposit(alice, 1_000e6);
        _withRouter(0, 5);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EpochedQueueModule.NavInputInvalid.selector, uint8(5)));
        _q().requestEpochWithdrawal(s);
    }

    function test_navGate_invalidOracle_rejects() public {
        uint256 s = _deposit(alice, 1_000e6);
        _withRouter(0, 6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EpochedQueueModule.NavInputInvalid.selector, uint8(6)));
        _q().requestEpochWithdrawal(s);
    }

    function test_navGate_incompleteWarmNav_rejects_evenIfFresh() public {
        uint256 s = _deposit(alice, 1_000e6);
        bm.setWarmNav(0, uint40(block.timestamp), false); // an adapter failed: warm NAV incomplete
        vm.prank(alice);
        vm.expectRevert(EpochedQueueModule.NavInvalid.selector);
        _q().requestEpochWithdrawal(s);
    }

    function test_navGate_doesNotBlockSettlementOrClaims() public {
        uint256 s = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        (uint256 e, uint256 c) = _request(alice, s);
        _withRouter(0, 4); // NAV inputs become untrustworthy AFTER acceptance
        _closeEpoch();
        _q().fundEpoch(e);
        assertEq(_claim(alice, e, c), 1_000e6, "an accepted claim is never repriced or blocked by later NAV doubt");
    }
}

contract MockNavRouter {
    uint256 public assets;
    uint8 public issue;

    constructor(uint256 a, uint8 i) {
        assets = a;
        issue = i;
    }

    function totalStrategyAssetsSafe() external view returns (uint256) {
        return assets;
    }

    function navValidity() external view returns (uint256, uint8) {
        return (assets, issue);
    }
}
