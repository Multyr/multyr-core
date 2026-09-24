// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// What happens when a strategy adapter (say Fluid) is hacked and money is really lost?
//
// "OLD" = price fixed at epoch close, user exposed until then. "NEW" = price fixed at
// request. The OLD numbers are stated in comments (that code no longer exists); every
// NEW number is asserted. The strategy here is a real registered strategy behind the
// real StrategyRouter, and "hacked" means its USDC is really gone.
//
//   Alice and Bob each deposit 50. Alice exits all of hers: 50 owed.  Fluid loses 20.
//     OLD: Alice 40, Bob 40 (both share the loss before close).
//     NEW: Alice 50 (fixed), Bob 30 (remaining holders absorb it).
//
// Timing:  loss BEFORE the request  -> both use the reduced valuation
//          loss AFTER epoch close   -> the claim is already fixed
//          loss AFTER payment       -> nobody claws anything back
//          UNRECOGNISED loss        -> the request locks an overpriced claim; the residual
//                                      timing risk is the protocol's, never repriced against
//                                      the user, and only the insolvency mechanism applies
//
// And the "major issue": 30 left against 50 owed must NOT block withdrawals. Claims are
// paid at the recovery ratio (60%), funded at nominal x index, same for every claimant.
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockUSDC } from "../../helpers/MockUSDC.sol";
import { StrategyMock } from "../../helpers/StrategyMock.sol";
import { ERC4626Module } from "../../../src/core/modules/ERC4626Module.sol";
import { EpochedQueueModule, EpochQueueStorage } from "../../../src/core/modules/EpochedQueueModule.sol";
import { MockQueueEpochParamsProvider } from "../../sprint-test/QueueEpochModule_WithdrawFlow_POC.t.sol";

contract AdapterHack_Scenarios_Test is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 constant WAD = 1e18;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    CoreHarness core;
    StrategyMock fluid; // the strategy/adapter that gets hacked
    uint256 t;

    function setUp() public {
        vm.etch(USDC, address(new MockUSDC()).code);
        MockQueueEpochParamsProvider params = new MockQueueEpochParamsProvider();
        core = new CoreHarness(
            IERC20Metadata(USDC), "USDC Agg", "agUSDC", address(this), address(this), address(params)
        );
        core.setEpochDurationUnsafe(7 days);
        fluid = new StrategyMock(USDC);
        core.addStrategyUnsafe(address(fluid)); // registered behind the REAL StrategyRouter
        t = block.timestamp;

        address[3] memory us = [alice, bob, carol];
        for (uint256 i; i < us.length; i++) {
            MockUSDC(USDC).mint(us[i], 1_000_000e6);
            vm.prank(us[i]);
            IERC20(USDC).approve(address(core), type(uint256).max);
        }
    }

    // ───────────── helpers ─────────────

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

    /// @dev cash the vault sends into the strategy/adapter (a deploy)
    function _deployToFluid(uint256 a) internal {
        vm.prank(address(core));
        IERC20(USDC).transfer(address(fluid), a);
    }

    /// @dev the hack: `a` of the adapter's USDC is really gone
    function _hackFluid(uint256 a) internal {
        vm.prank(address(fluid));
        IERC20(USDC).transfer(address(0xdead), a);
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

    function _value(address who) internal view returns (uint256) {
        return core.convertToAssets(core.balanceOf(who));
    }

    /// @dev Alice 50, Bob 50, 40 of it sitting in Fluid, 60 hot. Alice exits all of hers (50 owed).
    function _scenario() internal returns (uint256 sa, uint256 sb) {
        sa = _deposit(alice, 50e6);
        sb = _deposit(bob, 50e6);
        _deployToFluid(40e6);
    }

    // ═════════════ the headline example ═════════════

    function test_hack_example_aliceKeepsHerFixed50_bobAbsorbsTheWhole20() public {
        (uint256 sa,) = _scenario();
        (uint256 e, uint256 c) = _request(alice, sa);
        assertEq(core.totalOwed(), 50e6, "Alice is owed 50");

        _hackFluid(20e6); // Fluid loses 20: gross 100 -> 80

        assertEq(core.grossAssets(), 80e6);
        assertFalse(core.isInsolvent(), "80 gross vs 50 owed is NOT insolvency");
        assertEq(core.totalAssets(), 30e6, "remaining shareholders hold 30");
        assertApproxEqAbs(_value(bob), 30e6, 2, "Bob absorbed the entire loss (OLD model: 40)");

        _close();
        _q().fundEpoch(e);
        assertEq(_claim(alice, e, c), 50e6, "Alice is paid her full 50 (OLD model: 40)");
        assertApproxEqAbs(_value(bob), 30e6, 2, "and Bob still holds 30");
        assertEq(core.totalOwed(), 0);
    }

    // ═════════════ timing ═════════════

    function test_timing_lossBeforeRequest_isRecognised_bothUseTheReducedValuation() public {
        (uint256 sa,) = _scenario();
        _hackFluid(20e6); // recognised BEFORE Alice requests: NAV is 80 for 100 shares

        (uint256 e, uint256 c) = _request(alice, sa);
        assertApproxEqAbs(_q().epochClaim(e, c).assetsOwed, 40e6, 2, "Alice is priced at the reduced NAV: 40");
        assertApproxEqAbs(_value(bob), 40e6, 2, "and Bob holds 40: they share it");

        _close();
        _q().fundEpoch(e);
        assertApproxEqAbs(_claim(alice, e, c), 40e6, 2);
    }

    function test_timing_lossAfterEpochClose_claimIsAlreadyFixed() public {
        (uint256 sa,) = _scenario();
        (uint256 e, uint256 c) = _request(alice, sa);
        _close();

        _hackFluid(20e6); // after the close, before funding

        _q().fundEpoch(e);
        assertTrue(_q().epochData(e).state == EpochQueueStorage.EpochState.Funded);
        assertEq(_claim(alice, e, c), 50e6, "fixed: the hack changes nothing for Alice");
        assertApproxEqAbs(_value(bob), 30e6, 2);
    }

    function test_timing_lossAfterFunding_fundedClaimIsStillHonoured() public {
        (uint256 sa,) = _scenario();
        (uint256 e, uint256 c) = _request(alice, sa);
        _close();
        _q().fundEpoch(e); // 50 earmarked out of the 60 hot
        assertEq(_q().reservedForClaims(), 50e6);

        _hackFluid(20e6);

        assertEq(_claim(alice, e, c), 50e6, "the earmark protects her");
    }

    function test_timing_lossAfterPayment_nothingIsClawedBack() public {
        (uint256 sa,) = _scenario();
        (uint256 e, uint256 c) = _request(alice, sa);
        _close();
        _q().fundEpoch(e);
        uint256 paid = _claim(alice, e, c);
        assertEq(paid, 50e6);
        uint256 aliceUsdc = IERC20(USDC).balanceOf(alice);

        _hackFluid(20e6); // AFTER payment

        assertEq(IERC20(USDC).balanceOf(alice), aliceUsdc, "Alice keeps every cent she was paid");
        assertEq(core.totalOwed(), 0, "and owes nothing back");
        assertApproxEqAbs(_value(bob), 30e6, 2, "Bob bears the loss, exactly as if Alice had never been there");
    }

    // ═════════════ the unrecognised loss (the residual protocol risk) ═════════════

    /// @notice The adapter has lost 20 but the valuation the protocol can see still says 40. Every
    ///         validity check passes (the strategy answers, is healthy, the oracle is fine), so the
    ///         request is accepted at the stale, overpriced value. It is NOT repriced afterwards.
    function test_unrecognisedLoss_requestLocksTheOverpricedClaim_remainingHoldersAbsorbWhenItSurfaces() public {
        (uint256 sa,) = _scenario();
        _hackFluid(20e6);
        // what the protocol can observe: still 40 in Fluid
        vm.mockCall(address(fluid), abi.encodeWithSignature("totalAssets()"), abi.encode(uint256(40e6)));
        assertEq(core.grossAssets(), 100e6, "the vault still believes it holds 100");
        (bool valid,) = core.navStatus();
        assertTrue(valid, "no on-chain signal has changed, so the NAV gate cannot tell");

        (uint256 e, uint256 c) = _request(alice, sa);
        assertEq(_q().epochClaim(e, c).assetsOwed, 50e6, "accepted at the pre-loss value: 50, not 40");

        vm.clearMockedCalls(); // the loss becomes visible
        assertEq(core.grossAssets(), 80e6);
        assertFalse(core.isInsolvent());
        assertApproxEqAbs(_value(bob), 30e6, 2, "the residual timing risk falls on the remaining holders");

        _close();
        _q().fundEpoch(e);
        assertEq(_claim(alice, e, c), 50e6, "Alice is never repriced for the protocol's late recognition");
    }

    function test_unrecognisedSevereLoss_becomesInsolvency_andIsSharedProRata() public {
        (uint256 sa,) = _scenario();
        _hackFluid(40e6); // Fluid is wiped out
        vm.mockCall(address(fluid), abi.encodeWithSignature("totalAssets()"), abi.encode(uint256(40e6)));
        (uint256 e, uint256 c) = _request(alice, sa); // accepted at 50 on the stale value
        vm.clearMockedCalls();

        // reality: gross 60 vs owed 50 -> still solvent; Bob is left with 10
        assertEq(core.grossAssets(), 60e6);
        assertFalse(core.isInsolvent());
        assertApproxEqAbs(_value(bob), 10e6, 2);

        // a second hack empties the rest of what was in the vault: now genuinely insolvent
        vm.prank(address(core));
        IERC20(USDC).transfer(address(0xdead), 30e6); // gross 30 vs owed 50
        assertTrue(core.isInsolvent());
        assertEq(core.liabilityIndex(), 0.6e18);

        _close();
        _q().fundEpoch(e);
        assertTrue(_q().epochData(e).state == EpochQueueStorage.EpochState.Funded);
        assertEq(_claim(alice, e, c), 30e6, "Alice's claim is capped by the general insolvency index, nothing else");
    }

    // ═════════════ the "major issue": 30 left against 50 owed must not block withdrawals ═════════════

    function test_majorIssue_30LeftAgainst50Owed_doesNotBlockWithdrawals_paysTheRecoveryRatio() public {
        (uint256 sa,) = _scenario();
        _deployToFluid(10e6); // Fluid holds 50, hot 50
        (uint256 e, uint256 c) = _request(alice, sa);
        assertEq(core.totalOwed(), 50e6);

        _hackFluid(50e6); // Fluid (holding 50) is wiped out: hot 50 remains
        vm.prank(address(core)); // and 20 more of the cash is lost: 30 left
        IERC20(USDC).transfer(address(0xdead), 20e6);
        assertEq(core.grossAssets(), 30e6, "30 left");
        assertTrue(core.isInsolvent(), "against 50 owed");
        assertEq(core.totalAssets(), 0, "no equity left for the remaining shareholder");

        _close();
        // OLD PR behaviour would demand 50 of cash here and never reach it (only 30 exists).
        _q().fundEpoch(e);
        assertTrue(
            _q().epochData(e).state == EpochQueueStorage.EpochState.Funded,
            "funding needs 50 * 0.6 = 30, which exists: the epoch funds"
        );
        assertEq(_q().reservedForClaims(), 30e6);

        assertEq(_claim(alice, e, c), 30e6, "Alice is paid the 60% recovery ratio, she is not locked out");
        assertEq(core.totalOwed(), 0);
    }

    function test_majorIssue_twoClaimants_samePercentage_orderDoesNotMatter() public {
        uint256 sa = _deposit(alice, 30e6);
        uint256 sc = _deposit(carol, 20e6);
        _deposit(bob, 50e6);
        _deployToFluid(50e6);
        (uint256 e, uint256 ca) = _request(alice, sa); // owed 30
        (, uint256 cc) = _request(carol, sc); // owed 20
        _hackFluid(50e6);
        vm.prank(address(core));
        IERC20(USDC).transfer(address(0xdead), 20e6); // 30 left vs 50 owed
        _close();
        _q().fundEpoch(e);

        uint256 paidC = _claim(carol, e, cc); // the SMALLER, LATER claimant goes first
        uint256 paidA = _claim(alice, e, ca);
        assertApproxEqAbs(paidC, 12e6, 2, "20 x 60%");
        assertApproxEqAbs(paidA, 18e6, 2, "30 x 60%");
        assertLe(paidA + paidC, 30e6, "never more than exists");
        assertGe(paidA + paidC, 30e6 - 4, "and nothing left unpaid");
    }

    /// @notice Cash that is stuck inside the hacked strategy cannot be paid out until it is realised;
    ///         funding is a liquidity step and is allowed to stay partial -- but it must not pay a
    ///         claim early and must not let anyone jump the queue.
    function test_majorIssue_illiquidRemainderInStrategy_partialFundingIsExplicit_andRecoversLater() public {
        (uint256 sa,) = _scenario();
        (uint256 e, uint256 c) = _request(alice, sa);
        _hackFluid(10e6); // Fluid keeps 30, hot 60: gross 90 vs 50 owed: solvent, fine
        // illiquid case: everything the vault could pay with is inside a strategy that cannot answer
        vm.prank(address(core));
        IERC20(USDC).transfer(address(fluid), 60e6); // sweep the hot cash into Fluid (now 90, hot 0)
        _close();

        // the epoch cannot fund from an empty hot balance unless the router can realise it
        _q().fundEpoch(e);
        if (_q().epochData(e).state != EpochQueueStorage.EpochState.Funded) {
            vm.prank(alice);
            vm.expectRevert(EpochedQueueModule.EpochNotFunded.selector);
            _q().claimEpochAssets(e, c);
            // liquidity returns to the vault
            vm.prank(address(fluid));
            IERC20(USDC).transfer(address(core), 90e6);
            _q().fundEpoch(e);
        }
        assertEq(_claim(alice, e, c), 50e6, "paid in full once the cash is actually there");
    }
}
