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

        // (c) instant that falls back into the queue (lock period)
        vm.revertToState(snap);
        params.setLockPeriod(1 days);
        vm.prank(alice);
        (bool instant2, uint256 fe, uint256 fc) = _q().requestInstantWithdrawal(s / 2);
        assertFalse(instant2);
        assertEq(_claimOf(fe, fc).assetsOwed, queuedOwed, "fallback carries exactly the request-time assetsOwed");
    }

    // ═════════════════════════ W-13 / W-14 pro-rata index ═════════════════════════

    /// @dev alice 600 (epoch 0) and bob 400 + carol 100 (epoch 1), all funded while solvent; then a loss.
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
        _q().fundEpoch(e0);

        (e1, cb) = _request(bob, sb);
        uint256 e1b;
        (e1b, cc) = _request(carol, sc);
        assertEq(e1, e1b);
        _closeEpoch();
        _q().fundEpoch(e1);
        assertEq(_q().reservedForClaims(), 1_100e6);

        _loss(1_400e6); // hot 2000 -> 600 vs owed 1100
        assertTrue(core.isInsolvent());
    }

    function test_W13_W14_fundedClaimsAcrossEpochs_getTheSameIndex_andClaimingDoesNotMoveIt() public {
        (uint256 e0, uint256 ca, uint256 e1, uint256 cb, uint256 cc) = _fundedThenLoss();

        uint256 index0 = core.liabilityIndex();
        assertEq(index0, 600e6 * WAD / 1_100e6, "index = gross / owed");
        assertLt(index0, WAD);

        uint256 paidA = _claim(alice, e0, ca);
        assertEq(paidA, 600e6 * index0 / WAD, "alice (epoch 0) paid at the index");
        _assertIndexHeld(index0, "W-13: claiming does not move the index");

        uint256 paidB = _claim(bob, e1, cb);
        assertApproxEqAbs(paidB, 400e6 * index0 / WAD, 1e3, "bob (epoch 1) paid at the same index");
        _assertIndexHeld(index0, "W-13 again after the second claim");

        uint256 paidC = _claim(carol, e1, cc);
        // W-14: whichever epoch a claim sits in, funded earlier or later, the same index applies.
        assertApproxEqAbs(paidA, 600e6 * index0 / WAD, 1e3, "epoch 0");
        assertApproxEqAbs(paidB, 400e6 * index0 / WAD, 1e3, "epoch 1");
        assertApproxEqAbs(paidC, 100e6 * index0 / WAD, 1e3, "epoch 1, second claim");
        assertEq(core.totalOwed(), 0);
    }

    /// @dev Paying assetsOwed*index/1e18 (rounded down) removes value from gross and owed in the
    ///      same proportion, so the index cannot move except by that rounding dust, and only UPWARD
    ///      (never in the claimant's favour at the expense of the claimants still waiting).
    function _assertIndexHeld(uint256 before, string memory why) internal view {
        uint256 nowIdx = core.liabilityIndex();
        assertGe(nowIdx, before, why);
        assertLe(nowIdx - before, 1e12, why);
    }

    function test_W13_batchClaim_paysEveryClaimAtOneIndex() public {
        (, , uint256 e1, uint256 cb, uint256 cc) = _fundedThenLoss();
        uint256 index0 = core.liabilityIndex();
        // bob & carol are different users: batch only claims the caller's own; claim bob's via batch
        uint256[] memory ids = new uint256[](1);
        ids[0] = cb;
        vm.prank(bob);
        uint256 paid = _q().batchClaimEpochAssets(e1, ids);
        assertEq(paid, 400e6 * index0 / WAD);
        _assertIndexHeld(index0, "W-13 batch");
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

    function test_s11_staleNav_requestRevertsEvenWhenWarmNavValidIsTrue() public {
        uint256 s = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);

        // valid == true, but the cache is 16 minutes old (MAX_WARM_NAV_AGE is 15).
        t += 16 minutes;
        vm.warp(t);
        bm.setWarmNav(0, uint40(t - 16 minutes), true);
        (, uint40 ts, bool valid) = bm.warmNavState();
        assertTrue(valid);
        assertGt(block.timestamp - ts, 15 minutes);

        vm.prank(alice);
        vm.expectRevert(EpochedQueueModule.NavStale.selector);
        _q().requestEpochWithdrawal(s);

        vm.prank(alice);
        vm.expectRevert(EpochedQueueModule.NavStale.selector);
        _q().requestInstantWithdrawal(s);

        // A fresh cache (keeper ran) lets the same request through.
        bm.setWarmNav(0, uint40(t), true);
        _request(alice, s);
    }

    function test_s11_invalidNav_requestReverts() public {
        uint256 s = _deposit(alice, 1_000e6);
        bm.setWarmNav(0, uint40(block.timestamp), false);
        vm.prank(alice);
        vm.expectRevert(EpochedQueueModule.NavInvalid.selector);
        _q().requestEpochWithdrawal(s);
    }

    function test_s11_insolvency_fullScenario() public {
        // alice 600 -> epoch 0 (funded while solvent)
        uint256 sa = _deposit(alice, 600e6);
        uint256 sd = _deposit(dave, 1_400e6);
        _deposit(carol, 200e6);
        (uint256 e0, uint256 ca) = _request(alice, sa);
        _closeEpoch();
        _q().fundEpoch(e0);

        // carol 200 -> epoch 1 (closed, not yet funded)
        (uint256 e1, uint256 cc) = _request(carol, core.balanceOf(carol));
        _closeEpoch();

        // loss of 1500: gross 2200 -> 700 < owed 800
        _loss(1_500e6);
        assertTrue(core.isInsolvent());
        assertEq(core.totalAssets(), 0, "totalAssets() == 0 without reverting");
        assertEq(core.grossAssets(), 700e6);
        uint256 index = core.liabilityIndex();
        assertEq(index, 700e6 * WAD / 800e6);

        // deposits and requests revert
        vm.prank(bob);
        vm.expectRevert(ERC4626Module.VaultInsolvent.selector);
        ERC4626Module(address(core)).deposit(10e6, bob);
        vm.prank(dave);
        vm.expectRevert(EpochedQueueModule.VaultInsolvent.selector);
        _q().requestEpochWithdrawal(sd);

        // settlement keeps working. Epoch 1 needs 200 * index = 175, but alice's epoch still
        // holds a 600 earmark, so it cannot be funded yet (no revert, just not yet).
        _q().fundEpoch(e1);
        assertTrue(_q().epochData(e1).state == EpochQueueStorage.EpochState.Closed);
        vm.prank(carol);
        vm.expectRevert(EpochedQueueModule.EpochNotFunded.selector);
        _q().claimEpochAssets(e1, cc);

        // alice (funded while solvent) is paid pro-rata at the index; claiming does not move it,
        // and the surplus of her nominal earmark (600 - 525) is released to everyone else.
        uint256 paid = _claim(alice, e0, ca);
        assertEq(paid, 600e6 * index / WAD, "pro-rata, not nominal");
        assertLt(paid, 600e6);
        _assertIndexHeld(index, "claiming does not move the index");
        assertEq(_q().reservedForClaims(), 0, "her whole earmark was released");

        // NO full nominal coverage is demanded: epoch 1 now funds at the SAME ratio (175 <= 175 hot)
        _q().fundEpoch(e1);
        assertTrue(_q().epochData(e1).state == EpochQueueStorage.EpochState.Funded, "funded at nominal * index");
        assertApproxEqAbs(_q().reservedForClaims(), 200e6 * index / WAD, 2);

        // carol is paid the same fraction alice got
        uint256 paidC = _claim(carol, e1, cc);
        assertApproxEqAbs(paidC, 200e6 * index / WAD, 1e3);
        assertApproxEqRel(paidC * WAD / 200e6, paid * WAD / 600e6, 1e9, "same recovery ratio for every claim");
        assertEq(core.totalOwed(), 0);
    }

    /// @notice Recovery AFTER funding is not a permanent haircut: a claim funded at a low index and
    ///         claimed after assets came back pays the full nominal, topped up from free liquidity.
    function test_s11_recoveryAfterFunding_claimPaysFullNominal() public {
        uint256 sa = _deposit(alice, 600e6);
        _deposit(dave, 1_400e6);
        (uint256 e0, uint256 ca) = _request(alice, sa);
        _closeEpoch();
        _loss(1_700e6); // gross 300 < owed 600: index 0.5
        assertEq(core.liabilityIndex(), WAD / 2);

        _q().fundEpoch(e0); // funds at 0.5 * 600 = 300, not at an impossible 600
        assertTrue(_q().epochData(e0).state == EpochQueueStorage.EpochState.Funded);
        assertEq(_q().reservedForClaims(), 300e6);

        _gain(1_000e6); // recovery: index back to 1e18
        assertEq(core.liabilityIndex(), WAD);
        assertEq(_claim(alice, e0, ca), 600e6, "full nominal: no permanent haircut");
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
