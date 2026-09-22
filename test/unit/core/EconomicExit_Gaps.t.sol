// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Coverage gaps found after the main suites: things that only matter when something goes wrong.

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockUSDC } from "../../helpers/MockUSDC.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";
import { ERC4626Module } from "../../../src/core/modules/ERC4626Module.sol";
import { EpochedQueueModule, EpochQueueStorage } from "../../../src/core/modules/EpochedQueueModule.sol";
import { MockQueueEpochParamsProvider } from "../../sprint-test/QueueEpochModule_WithdrawFlow_POC.t.sol";
import { MockNavRouter } from "./EconomicExit_Spec.t.sol";

contract EconomicExit_Gaps_Test is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 constant WAD = 1e18;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    CoreHarness core;
    MockBufferManagerForTests bm;
    uint256 t;

    function setUp() public {
        vm.etch(USDC, address(new MockUSDC()).code);
        MockQueueEpochParamsProvider params = new MockQueueEpochParamsProvider();
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

    function _q() internal view returns (EpochedQueueModule) {
        return EpochedQueueModule(address(core));
    }

    function _deposit(address who, uint256 a) internal returns (uint256 s) {
        vm.prank(who);
        s = ERC4626Module(address(core)).deposit(a, who);
    }

    function _request(address who, uint256 shares) internal returns (uint256 e, uint256 c) {
        vm.prank(who);
        (e, c) = _q().requestEpochWithdrawal(shares);
    }

    function _hot() internal view returns (uint256) {
        return IERC20(USDC).balanceOf(address(core));
    }

    function _lose(uint256 a) internal {
        vm.prank(address(core));
        IERC20(USDC).transfer(address(0xdead), a);
    }

    function _gain(uint256 a) internal {
        MockUSDC(USDC).mint(address(core), a);
    }

    function _close() internal {
        t += 7 days + 1;
        vm.warp(t);
        _q().closeCurrentEpoch();
    }

    function _claim(address who, uint256 e, uint256 c) internal returns (uint256) {
        vm.prank(who);
        return _q().claimEpochAssets(e, c);
    }

    function _moveHotToWarm(uint256 amount) internal {
        vm.prank(address(core));
        IERC20(USDC).transfer(makeAddr("warmAdapter"), amount);
        (uint256 nav,,) = bm.warmNavState();
        bm.setWarmNav(nav + amount, uint40(block.timestamp), true);
    }

    function _moveWarmToHot(uint256 amount) internal {
        vm.prank(makeAddr("warmAdapter"));
        IERC20(USDC).transfer(address(core), amount);
        (uint256 nav,,) = bm.warmNavState();
        bm.setWarmNav(nav - amount, uint40(block.timestamp), true);
    }

    // ═════ 1. the gate closing during a hack must not trap users ═════

    /// @notice While a strategy is unhealthy the NAV gate refuses NEW requests (it cannot trust the price).
    ///         That must not leave holders with no way out: force exit still works, at the shareholder NAV.
    function test_gateClosedDuringHack_requestsRejected_butForceExitStillOpen() public {
        uint256 sa = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        core.setStrategyRouterUnsafe(address(new MockNavRouter(0, 5))); // a strategy is DEGRADED

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EpochedQueueModule.NavInputInvalid.selector, uint8(5)));
        _q().requestEpochWithdrawal(sa);

        uint256 before = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 got = ERC4626Module(address(core)).forceWithdrawAll(alice, 0);
        assertGt(got, 0, "alice can still get out through the force path");
        assertEq(IERC20(USDC).balanceOf(alice) - before, got);
        assertEq(core.balanceOf(alice), 0, "her shares were burned for it");
    }

    /// @notice Already-accepted claims are unaffected by the gate closing.
    function test_gateClosedDuringHack_doesNotStopSettlementOfAcceptedClaims() public {
        uint256 sa = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        (uint256 e, uint256 c) = _request(alice, sa);
        core.setStrategyRouterUnsafe(address(new MockNavRouter(0, 4)));
        _close();
        _q().fundEpoch(e);
        assertEq(_claim(alice, e, c), 1_000e6);
    }

    // ═════ 2. fuzz: whatever the loss, claims are pro-rata, never over-paid, never blocked ═════

    function testFuzz_anyHackSize_claimsPayProRata_neverMoreThanExists_neverBlocked(
        uint96 lossPct,
        bool aliceFirst
    ) public {
        uint256 sa = _deposit(alice, 600e6);
        uint256 sc = _deposit(carol, 400e6);
        _deposit(dave, 1_000e6);
        (uint256 e, uint256 ca) = _request(alice, sa);
        (, uint256 cc) = _request(carol, sc);
        uint256 owedA = _q().epochClaim(e, ca).assetsOwed;
        uint256 owedC = _q().epochClaim(e, cc).assetsOwed;
        _close();

        _lose(_hot() * bound(lossPct, 0, 100) / 100);
        uint256 gross = core.grossAssets();
        uint256 owed = owedA + owedC;

        _q().fundEpoch(e);
        assertTrue(
            _q().epochData(e).state == EpochQueueStorage.EpochState.Funded, "an epoch that has the cash is never blocked"
        );

        uint256 paidA;
        uint256 paidC;
        if (aliceFirst) {
            paidA = _claim(alice, e, ca);
            paidC = _claim(carol, e, cc);
        } else {
            paidC = _claim(carol, e, cc);
            paidA = _claim(alice, e, ca);
        }

        assertLe(paidA + paidC, gross, "never more than exists");
        if (gross >= owed) {
            assertEq(paidA, owedA, "solvent: nominal");
            assertEq(paidC, owedC);
        } else {
            uint256 idx = gross * WAD / owed;
            assertApproxEqRel(paidA, owedA * idx / WAD, 1e15, "alice at the index");
            assertApproxEqRel(paidC, owedC * idx / WAD, 1e15, "carol at the SAME index, whoever went first");
        }
        assertEq(core.totalOwed(), 0);
        assertEq(_q().reservedForClaims(), 0, "earmark fully released");
    }

    // ═════ 3. the top-up path ═════

    function test_topUp_claimRevertsWhenFreeCashShort_thenPaysFullAfterLiquidityReturns() public {
        uint256 sa = _deposit(alice, 600e6);
        _deposit(dave, 1_400e6);
        (uint256 e, uint256 c) = _request(alice, sa);
        _close();
        _lose(1_700e6); // gross 300 vs owed 600: index 0.5
        _q().fundEpoch(e); // earmarks 300
        assertEq(_q().reservedForClaims(), 300e6);

        _gain(1_000e6); // assets recover: index 1e18, payout is now the full 600
        _moveHotToWarm(_hot() - 300e6); // ...but the recovered money is illiquid: only the 300 earmark is on hand
        assertEq(core.liabilityIndex(), WAD);

        vm.prank(alice);
        vm.expectRevert(EpochedQueueModule.InsufficientFreeLiquidity.selector);
        _q().claimEpochAssets(e, c);
        assertFalse(_q().epochClaim(e, c).claimed, "nothing was paid short, nothing was consumed");

        _moveWarmToHot(1_000e6); // liquidity comes back
        assertEq(_claim(alice, e, c), 600e6, "paid the full nominal: a transient loss is not a haircut");
    }

    // ═════ 4. everything else must keep working in insolvency ═════

    function test_perfFeeCrystallisation_inInsolvency_doesNotRevert_andTakesNoFee() public {
        core.setPerfParamsUnsafe(2_000e14, 0);
        uint256 sa = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        _request(alice, sa);
        _lose(1_500e6);
        assertTrue(core.isInsolvent());
        uint256 feeBefore = core.balanceOf(address(this));

        _q().endEpochCrystallize(); // price is 0: must be a clean no-op

        assertEq(core.balanceOf(address(this)), feeBefore, "no performance fee on a worthless share price");
    }

    function test_depositsWorkAgainAfterRecovery_atASanePrice() public {
        uint256 sa = _deposit(alice, 1_000e6);
        uint256 sb = _deposit(bob, 1_000e6);
        _request(alice, sa);
        _lose(1_500e6);
        assertTrue(core.isInsolvent());
        vm.prank(carol);
        vm.expectRevert(ERC4626Module.VaultInsolvent.selector);
        ERC4626Module(address(core)).deposit(100e6, carol);

        _gain(2_000e6); // recovery: gross 2500 vs owed 1000: equity 1500 for bob's shares
        assertFalse(core.isInsolvent());
        uint256 bobValue = core.convertToAssets(sb);
        assertApproxEqRel(bobValue, 1_500e6, 0.001e18);

        uint256 shares = _deposit(carol, 750e6);
        assertApproxEqRel(core.convertToAssets(shares), 750e6, 0.001e18, "carol buys at the recovered price");
        assertApproxEqRel(core.convertToAssets(sb), bobValue, 1e12, "and bob is not diluted");
    }

    // ═════ 5. dust: many tiny claims must drain the books exactly ═════

    function test_manyDustClaims_insolvent_drainTotalOwedAndEarmarkExactly() public {
        uint256 n = 25;
        address[] memory us = new address[](n);
        uint256[] memory cids = new uint256[](n);
        uint256 e;
        for (uint256 i; i < n; i++) {
            us[i] = makeAddr(string.concat("dust", vm.toString(i)));
            MockUSDC(USDC).mint(us[i], 1_000e6);
            vm.prank(us[i]);
            IERC20(USDC).approve(address(core), type(uint256).max);
            uint256 amt = 100e6 + i * 7_919; // odd amounts so nothing divides evenly
            uint256 s = _deposit(us[i], amt);
            (e, cids[i]) = _request(us[i], s);
        }
        _deposit(dave, 5_000e6);
        _close();
        _lose(_hot() * 80 / 100); // deep loss: ~1.5k left against ~2.5k owed
        assertTrue(core.isInsolvent());

        _q().fundEpoch(e);
        assertTrue(_q().epochData(e).state == EpochQueueStorage.EpochState.Funded);
        uint256 paidTotal;
        for (uint256 i; i < n; i++) {
            paidTotal += _claim(us[i], e, cids[i]);
        }
        assertEq(core.totalOwed(), 0, "every wei of liability discharged");
        assertEq(_q().reservedForClaims(), 0, "every wei of earmark released");
        assertEq(_q().outstandingClaimCount(), 0);
        assertLe(paidTotal, IERC20(USDC).balanceOf(address(core)) + paidTotal, "paid out of real cash");
    }
    // ═════ 6. several hacks, several epochs, mixed claim order ═════

    /// @notice e0 funded while solvent, e1 closed but unfunded, then a catastrophic loss, some claims,
    ///         a SECOND hack, more claims. Every claim is paid at the index of the moment it is claimed,
    ///         claiming never moves the index, nothing is over-paid, and the books end at zero.
    function test_multiEpoch_twoSuccessiveHacks_mixedOrder_booksBalance() public {
        uint256 sa = _deposit(alice, 400e6);
        uint256 sb = _deposit(bob, 300e6);
        _deposit(dave, 2_300e6);

        (uint256 e0, uint256 ca) = _request(alice, sa); // owes 400
        _close();
        _q().fundEpoch(e0); // funded while solvent: earmark 400
        (uint256 e1, uint256 cb) = _request(bob, sb); // owes 300
        _close(); // e1 closed, NOT funded
        assertEq(core.totalOwed(), 700e6);

        _lose(2_600e6); // hack 1: gross 3000 -> 400 vs 700 owed
        assertTrue(core.isInsolvent());
        uint256 idx1 = core.liabilityIndex();
        assertApproxEqRel(idx1, 400e6 * WAD / 700e6, 1e12);

        uint256 paidA = _claim(alice, e0, ca); // funded epoch claims first
        assertApproxEqRel(paidA, 400e6 * idx1 / WAD, 1e12, "alice at index 1");
        assertGe(core.liabilityIndex(), idx1, "claiming did not lower the index");

        _lose(30e6); // hack 2, while bob's epoch is still unfunded
        uint256 idx2 = core.liabilityIndex();
        assertLt(idx2, idx1, "the second loss lowers the recovery ratio for everyone still owed");

        _q().fundEpoch(e1); // funds at 300 * idx2, not at an impossible 300
        assertTrue(_q().epochData(e1).state == EpochQueueStorage.EpochState.Funded);
        uint256 paidB = _claim(bob, e1, cb);
        assertLe(paidB, 300e6 * idx2 / WAD + 1, "bob at index 2");
        assertGt(paidB, 300e6 * idx2 / WAD - 1e6);

        assertEq(core.totalOwed(), 0);
        assertEq(_q().reservedForClaims(), 0);
        assertLe(paidA + paidB, 400e6, "never more than the assets that were left after hack 1");
    }

    // ═════ 7. adversarial ═════

    /// @notice Inflating the vault with a donation right before exiting must not profit the exiter.
    function test_adversarial_donationBeforeRequest_isALossForTheDonor() public {
        uint256 sa = _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        uint256 aliceStart = IERC20(USDC).balanceOf(alice);

        vm.prank(alice);
        IERC20(USDC).transfer(address(core), 100e6); // donate 100 to the vault
        (uint256 e, uint256 c) = _request(alice, sa);
        _close();
        _q().fundEpoch(e);
        uint256 got = _claim(alice, e, c);

        assertLt(got, 100e6 + 1_000e6, "she gets back her deposit plus only her half of the donation");
        assertLt(IERC20(USDC).balanceOf(alice) + 0, aliceStart + 1_000e6, "and is net-negative overall");
        assertApproxEqAbs(got, 1_050e6, 2e6);
    }

    /// @notice Front-running a known loss (spec D4, accepted): the exiter escapes the loss but pays the
    ///         withdraw fee, and the escaped loss lands on the remaining holders.
    function test_adversarial_frontRunKnownLoss_escapesTheLoss_butPaysTheFee() public {
        core.setExitFeesUnsafe(100, 0, 0); // 1% withdraw fee
        uint256 sa = _deposit(alice, 1_000e6);
        uint256 sb = _deposit(bob, 1_000e6);

        (uint256 e, uint256 c) = _request(alice, sa); // sees the loss coming and leaves first
        uint256 owed = _q().epochClaim(e, c).assetsOwed;
        assertApproxEqAbs(owed, 990e6, 2, "1% fee taken");

        _lose(600e6); // the loss lands afterwards
        _close();
        _q().fundEpoch(e);
        assertEq(_claim(alice, e, c), owed, "she escaped it");
        assertLt(core.convertToAssets(sb), 1_000e6 - 500e6, "the remaining holder carries all of it");
    }

    /// @notice Spamming one-wei requests (there is no minimum any more) must not block close or funding.
    function test_adversarial_dustRequestSpam_doesNotBlockCloseFundOrRealClaims() public {
        uint256 sa = _deposit(alice, 1_000e6);
        uint256 spam = _deposit(bob, 1_000e6);
        for (uint256 i; i < 150; i++) {
            _request(bob, 1);
        }
        (uint256 e, uint256 c) = _request(alice, sa);
        assertEq(_q().outstandingClaimCount(), 151);
        _close();
        _q().fundEpoch(e);
        assertEq(_claim(alice, e, c), 1_000e6, "the real claim is unaffected");
        spam;
    }

    /// @notice When the index recovers after funding, free cash for the top-up is first come, first
    ///         served. The later claimant is not paid short: it reverts and is paid in full once liquidity
    ///         returns (the ordering effect is temporary, never a permanent loss).
    function test_adversarial_topUpRace_laterClaimantIsNotPaidShort() public {
        uint256 sa = _deposit(alice, 300e6);
        uint256 sc = _deposit(carol, 300e6);
        _deposit(dave, 1_400e6);
        (uint256 e, uint256 ca) = _request(alice, sa);
        (, uint256 cc) = _request(carol, sc);
        _close();
        _lose(1_400e6); // gross 600 vs owed 600... push below: lose 300 more
        _lose(300e6); // gross 300 vs 600 owed: index 0.5
        _q().fundEpoch(e); // earmark 300

        _gain(1_500e6); // full recovery
        // each claim owes 300 but its half of the earmark releases only 150, so each needs a 150 top-up.
        // Leave free cash (hot - earmark) for exactly ONE of them.
        _moveHotToWarm(_hot() - 300e6 - 150e6);
        assertEq(core.liabilityIndex(), WAD);

        uint256 first = _claim(alice, e, ca);
        assertEq(first, 300e6, "first claimant paid in full");

        vm.prank(carol);
        vm.expectRevert(EpochedQueueModule.InsufficientFreeLiquidity.selector);
        _q().claimEpochAssets(e, cc);

        _moveWarmToHot(150e6); // liquidity returns
        assertEq(_claim(carol, e, cc), 300e6, "the later claimant is paid in full, never short");
    }
}
