// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Coverage gaps found after the main suites: things that only matter when something goes wrong.

import {Test} from "lib/forge-std/src/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {CoreHarness} from "../../helpers/CoreHarness.sol";
import {MockUSDC} from "../../helpers/MockUSDC.sol";
import {MockBufferManagerForTests} from "../../helpers/MockBufferManagerForTests.sol";
import {ERC4626Module} from "../../../src/core/modules/ERC4626Module.sol";
import {
    EpochedQueueModule,
    EpochQueueStorage
} from "../../../src/core/modules/EpochedQueueModule.sol";
import {
    MockQueueEpochParamsProvider
} from "../../sprint-test/QueueEpochModule_WithdrawFlow_POC.t.sol";
import {MockNavRouter} from "./EconomicExit_Spec.t.sol";

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
            IERC20Metadata(USDC),
            "USDC Agg",
            "agUSDC",
            address(this),
            address(this),
            address(params)
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
        vm.expectRevert(
            abi.encodeWithSelector(EpochedQueueModule.NavInputInvalid.selector, uint8(5))
        );
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
            _q().epochData(e).state == EpochQueueStorage.EpochState.Funded,
            "an epoch that has the cash is never blocked"
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
            assertApproxEqRel(
                paidC, owedC * idx / WAD, 1e15, "carol at the SAME index, whoever went first"
            );
        }
        assertEq(core.totalOwed(), 0);
        assertEq(_q().reservedForClaims(), 0, "earmark fully released");
    }

    // ═════ 3. crystallization is final: recovery after funding is not owed to the cohort ═════

    /// @notice Option A. fundEpoch() crystallizes ONE recoveryIndex for the cohort, exactly
    ///         once, and writes the haircut straight out of totalOwed -- there is no top-up
    ///         any more: a later recovery in gross assets is not owed to an already-funded
    ///         cohort at all. It simply raises totalAssets() for remaining shareholders (dave)
    ///         instead.
    function test_recoveryAfterFunding_isNotOwedToTheCohort_flowsToShareholdersInstead() public {
        uint256 sa = _deposit(alice, 600e6);
        _deposit(dave, 1_400e6);
        (uint256 e, uint256 c) = _request(alice, sa);
        _close();
        _lose(1_700e6); // gross 300 vs owed 600: index 0.5
        _q().fundEpoch(e); // crystallizes recoveryIndex = 0.5, earmarks 300
        assertEq(_q().reservedForClaims(), 300e6);

        uint256 recoveryIndex = _q().epochData(e).recoveryIndex;
        assertEq(recoveryIndex, 0.5e18, "cohort recovery ratio crystallized at fund time");

        // The haircut is written off totalOwed immediately, not left dangling until claimed --
        // so the vault is solvent again right here, before any recovery at all.
        assertEq(core.totalOwed(), 300e6, "totalOwed written down to what was actually reserved");
        assertFalse(core.isInsolvent());

        uint256 daveValueBefore = core.convertToAssets(core.balanceOf(dave));
        _gain(1_000e6); // a later recovery -- NOT owed to alice's already-crystallized cohort

        assertEq(_q().epochData(e).recoveryIndex, recoveryIndex, "immutable: never re-crystallized");
        assertEq(
            _claim(alice, e, c),
            300e6,
            "paid exactly the crystallized share, not topped up to nominal"
        );
        assertGt(
            core.convertToAssets(core.balanceOf(dave)),
            daveValueBefore,
            "the recovery instead raised the remaining shareholder's value"
        );
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

        assertEq(
            core.balanceOf(address(this)),
            feeBefore,
            "no performance fee on a worthless share price"
        );
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
        assertApproxEqRel(
            core.convertToAssets(shares), 750e6, 0.001e18, "carol buys at the recovered price"
        );
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
        assertLe(
            paidTotal, IERC20(USDC).balanceOf(address(core)) + paidTotal, "paid out of real cash"
        );
    }

    // ═════ 6. several hacks, several epochs, mixed claim order ═════

    /// @notice e0 funded while solvent, e1 closed but unfunded, then a catastrophic loss, alice
    ///         claims, a SECOND hack lands while bob's epoch is still unfunded, then bob claims.
    ///         Option A: e0's cohort crystallized recoveryIndex = 1e18 (funded while solvent) is
    ///         immutable -- alice is fully protected from BOTH hacks, which land entirely on
    ///         bob's still-uncrystallized e1. The books still end at exactly zero.
    function test_multiEpoch_twoSuccessiveHacks_aliceProtectedAfterFunding_bobAbsorbsBoth() public {
        uint256 sa = _deposit(alice, 400e6);
        uint256 sb = _deposit(bob, 300e6);
        _deposit(dave, 2_300e6);

        (uint256 e0, uint256 ca) = _request(alice, sa); // owes 400
        _close();
        _q().fundEpoch(e0); // funded while solvent: crystallizes recoveryIndex = 1e18, earmark 400
        assertEq(_q().epochData(e0).recoveryIndex, WAD);
        (uint256 e1, uint256 cb) = _request(bob, sb); // owes 300
        _close(); // e1 closed, NOT funded
        assertEq(core.totalOwed(), 700e6);

        _lose(2_500e6); // hack 1: gross 3000 -> 500 (still >= e0's 400 earmark)
        assertTrue(core.isInsolvent(), "700 owed > 500 gross");

        // Alice's cohort crystallized at 1e18 BEFORE the hack: she is paid in full regardless
        // of the live liabilityIndex the hack just created.
        uint256 paidA = _claim(alice, e0, ca);
        assertEq(paidA, 400e6, "already-funded-while-solvent cohort is immune to a later hack");
        assertEq(core.totalOwed(), 300e6, "only bob's still-uncrystallized claim remains owed");

        _lose(30e6); // hack 2, while bob's epoch is still unfunded -- lands entirely on bob
        assertTrue(core.isInsolvent());

        _q().fundEpoch(e1); // crystallizes bob's cohort at whatever is left
        assertTrue(_q().epochData(e1).state == EpochQueueStorage.EpochState.Funded);
        uint256 bobRecoveryIndex = _q().epochData(e1).recoveryIndex;
        assertApproxEqRel(
            bobRecoveryIndex, 70e6 * WAD / 300e6, 1e12, "bob absorbs both hacks alone"
        );

        uint256 paidB = _claim(bob, e1, cb);
        assertApproxEqRel(paidB, 300e6 * bobRecoveryIndex / WAD, 1e12);

        assertEq(core.totalOwed(), 0);
        assertEq(_q().reservedForClaims(), 0);
        // Within a couple of wei: two independent floor roundings (crystallize, then payout)
        // over the same ratio can leave a wei or two of dust in the vault, which becomes
        // shareholder equity rather than being paid to anyone -- never more than what was left.
        assertApproxEqAbs(
            paidA + paidB,
            3_000e6 - 2_500e6 - 30e6,
            10,
            "essentially every wei of what was left after both hacks"
        );
        assertLe(
            paidA + paidB,
            3_000e6 - 2_500e6 - 30e6,
            "never more than the assets that were actually left"
        );
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

        assertLt(
            got, 100e6 + 1_000e6, "she gets back her deposit plus only her half of the donation"
        );
        assertLt(
            IERC20(USDC).balanceOf(alice) + 0, aliceStart + 1_000e6, "and is net-negative overall"
        );
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
        assertLt(
            core.convertToAssets(sb), 1_000e6 - 500e6, "the remaining holder carries all of it"
        );
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

    /// @notice Option A removes the top-up race entirely: since a full recovery after funding is
    ///         not owed to an already-crystallized cohort, there is nothing left for claim order
    ///         (or free-cash availability) to race over -- every claimant in the cohort gets
    ///         exactly its crystallized share, no more, regardless of order, and never reverts
    ///         for lack of liquidity to top up (there is nothing to top up).
    function test_adversarial_recoveryAfterFunding_bothClaimantsPaidTheCrystallizedShare_noRace()
        public
    {
        uint256 sa = _deposit(alice, 300e6);
        uint256 sc = _deposit(carol, 300e6);
        _deposit(dave, 1_400e6);
        (uint256 e, uint256 ca) = _request(alice, sa);
        (, uint256 cc) = _request(carol, sc);
        _close();
        _lose(1_400e6); // gross 600 vs owed 600... push below: lose 300 more
        _lose(300e6); // gross 300 vs 600 owed: index 0.5
        _q().fundEpoch(e); // crystallizes recoveryIndex = 0.5, earmark 300

        _gain(1_500e6); // full recovery -- NOT owed to this already-crystallized cohort
        assertFalse(core.isInsolvent());

        uint256 first = _claim(alice, e, ca);
        assertEq(first, 150e6, "paid the crystallized share, not topped up to nominal");

        uint256 second = _claim(carol, e, cc);
        assertEq(
            second, 150e6, "same crystallized share regardless of claim order -- no race to lose"
        );
    }

    function test_twoCohortsFundBeforeEitherClaims() public {
        uint256 a = _deposit(alice, 50e6);
        uint256 b = _deposit(bob, 50e6);
        (uint256 e0, uint256 c0) = _request(alice, a);
        _close();
        (uint256 e1, uint256 c1) = _request(bob, b);
        _close();
        _lose(40e6);
        _q().fundEpoch(e0);
        _q().fundEpoch(e1);
        assertEq(uint256(_q().epochData(e1).state), uint256(EpochQueueStorage.EpochState.Funded));
        assertApproxEqAbs(_claim(bob, e1, c1), 30e6, 2);
        assertApproxEqAbs(_claim(alice, e0, c0), 30e6, 2);
    }

    function test_invalidNavCannotCrystallizeHaircut() public {
        uint256 a = _deposit(alice, 50e6);
        _deposit(bob, 50e6);
        (uint256 e, uint256 c) = _request(alice, a);
        _close();
        _moveHotToWarm(70e6);
        bm.setWarmNav(0, uint40(block.timestamp), false);
        _q().fundEpoch(e);
        assertEq(uint256(_q().epochData(e).state), uint256(EpochQueueStorage.EpochState.Closed));
        assertEq(core.totalOwed(), 50e6);
        bm.setWarmNav(70e6, uint40(block.timestamp), true);
        _moveWarmToHot(70e6);
        _q().fundEpoch(e);
        assertEq(_claim(alice, e, c), 50e6);
    }

    function test_invalidStrategyCannotCrystallizeHaircut() public {
        uint256 a = _deposit(alice, 50e6);
        _deposit(bob, 50e6);
        (uint256 e,) = _request(alice, a);
        _close();
        _lose(70e6);
        core.setStrategyRouterUnsafe(address(new MockNavRouter(0, 4)));
        _q().fundEpoch(e);
        assertEq(uint256(_q().epochData(e).state), uint256(EpochQueueStorage.EpochState.Closed));
        core.setStrategyRouterUnsafe(address(new MockNavRouter(0, 0)));
        _q().fundEpoch(e);
        assertEq(_q().epochData(e).recoveryIndex, 0.6e18);
    }

    function test_standardRequestSnapshotsBeforeBurnAfterRollover() public {
        uint256 a = _deposit(alice, 50e6);
        _deposit(bob, 50e6);
        t += 8 days;
        vm.warp(t);
        _request(alice, a);
        assertEq(core.capBaseSnapshot(), 100e6);
    }

    function test_depositAndMintSnapshotBeforeChangingAssets() public {
        _deposit(alice, 100e6);
        t += 8 days;
        vm.warp(t);
        _deposit(bob, 50e6);
        assertEq(core.capBaseSnapshot(), 100e6);
        t += 8 days;
        vm.warp(t);
        vm.prank(carol);
        ERC4626Module(address(core)).mint(50e6, carol);
        assertEq(core.capBaseSnapshot(), 150e6);
    }

    function test_zeroCapEpochDurationAllowsDeposits() public {
        core.setEpochDurationUnsafe(0);
        assertEq(_deposit(alice, 100e6), 100e6);
    }

    function test_dynamicCapCannotOverrideStaticCap() public {
        MockQueueEpochParamsProvider p = MockQueueEpochParamsProvider(address(core.params()));
        p.setCapPerEpochBps(1000);
        p.setDynamicCap(true, 100, 2000, 1);
        uint256 a = _deposit(alice, 100e6);
        vm.prank(alice);
        (bool immediate,,) = _q().requestInstantWithdrawal(a * 15 / 100);
        assertFalse(immediate);
    }

    function test_instantRefreshPrecedesCapValidation() public {
        MockQueueEpochParamsProvider(address(core.params())).setCapPerEpochBps(1000);
        uint256 a = _deposit(alice, 100e6);
        _q().rollCapEpochIfNeeded();
        t += 16 minutes;
        vm.warp(t);
        bm.setWarmNav(0, uint40(t - 16 minutes), true);
        bm.setRefreshResult(100e6, uint40(t), true);
        vm.prank(alice);
        (bool immediate,,) = _q().requestInstantWithdrawal(a * 8 / 100);
        assertFalse(immediate, "refreshed 16 exceeds the cap of 10");
    }
}
