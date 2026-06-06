// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ──────────────────────────────────��───────────────────────────────────────────
// SPRINT SECURITY TEST -- High-Water Mark drawdown + interval guard fix
//
// ORIGINAL BUGS (now fixed):
// ─────────────────────────
// Bug A -- HWM decreased on drawdown:
//   Both QueueModule._crystallize() and PerfFeeMixin._crystallize() lowered the
//   HWM to the current (depressed) PPS when pps <= old:
//
//     if (pps <= old) {
//         f.highWaterMark = pps;   // was: HWM incorrectly lowered
//         ...
//     }
//
//   A correct HWM is MONOTONICALLY NON-DECREASING. Lowering it during a drawdown
//   let the protocol charge performance fees on mere loss recovery -- any subsequent
//   PPS increase above the new (reduced) HWM triggered a fee, even though investors
//   were still deeply underwater from their cost basis.
//
// Bug B -- minCrystallizeInterval guard was advisory only:
//   canCrystallize() checked the interval, but _crystallize() did not.
//   endEpochCrystallize() is ROLE_PUBLIC and bypassed the advisory guard directly.
//   Anyone could extract fees twice in the same block despite a 7-day minimum.
//
// FIXES APPLIED:
// ─────────────
// Fix A (QueueModule._crystallize, PerfFeeMixin._crystallize):
//   In the drawdown branch, leave the HWM unchanged:
//     if (pps <= old) {
//         f.lastCrystallize = uint64(block.timestamp);
//         emit Events.Crystallized(old, pps, 0);
//         return (old, 0);   // HWM is preserved
//     }
//
// Fix B (QueueModule._crystallize, PerfFeeMixin._crystallize):
//   Interval guard moved inside _crystallize(), applied after the drawdown check
//   so drawdown crystallisations are still recorded but fee-charging calls within
//   the minimum interval are silently rejected.
// ──────────────────────────────────────────────────────────────────────────────

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness } from "../helpers/CoreHarness.sol";
import { MockUSDC } from "../helpers/MockUSDC.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";
import { ERC4626Module } from "../../src/core/modules/ERC4626Module.sol";
import { QueueModule } from "../../src/core/modules/QueueModule.sol";

contract HWM_Drawdown_POC is Test {
    // ── constants ─────────────────────────────────────────────────────────────
    address constant USDC_UNDERLYING = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @dev 20 % performance fee rate in FixedPoint-WAD representation (0.2 x 1e18)
    uint256 constant PERF_RATE_20PCT = 2e17;

    // ── actors ────────────────────────────────────────────────────────────────
    address internal user;
    // address(this) is both owner AND feeCollector in the CoreHarness constructor

    // ── infra ─────────────────────────────────────────────────────────────────
    CoreHarness        internal core;
    MockUSDC           internal mock;
    MockParamsProvider internal params;

    // ──────────────────────────────────────────────────────────────────────────
    function setUp() public {
        user = makeAddr("user");

        // Etch MockUSDC at canonical USDC address
        mock = new MockUSDC();
        vm.etch(USDC_UNDERLYING, address(mock).code);

        params = new MockParamsProvider();
        core   = new CoreHarness(
            IERC20Metadata(USDC_UNDERLYING),
            "USDC Agg",
            "agUSDC",
            address(this), // owner
            address(this), // feeCollector perf fee shares land here
            address(params)
        );

        // Start with 0 % perf fee so initial setup crystallizations don't
        // charge fees, keeping totalSupply constant and PPS arithmetic clean.
        core.setPerfParamsUnsafe(0, 0);

        // User deposits 1 000 000 USDC -> 1 000 000 shares, PPS = 1.0
        MockUSDC(USDC_UNDERLYING).mint(user, 1_000_000e6);
        vm.prank(user);
        IERC20(USDC_UNDERLYING).approve(address(core), type(uint256).max);
        vm.prank(user);
        ERC4626Module(address(core)).deposit(1_000_000e6, user);

        // Sanity: PPS = 1.0 (1 M assets / 1 M shares)
        assertEq(core.totalSupply(),                               1_000_000e6, "setup: totalSupply");
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(address(core)), 1_000_000e6, "setup: hot balance");
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// @dev Simulate yield: directly mint USDC into the vault (increases totalAssets)
    function _addToVault(uint256 amount) internal {
        MockUSDC(USDC_UNDERLYING).mint(address(core), amount);
    }

    /// @dev Simulate a loss: vault transfers USDC out to a dead address
    function _drainFromVault(uint256 amount) internal {
        vm.prank(address(core));
        IERC20(USDC_UNDERLYING).transfer(makeAddr("blackhole"), amount);
    }

    function _crystallize() internal {
        QueueModule(address(core)).endEpochCrystallize();
    }

    // =========================================================================
    // TEST 1 -- HWM stays unchanged on drawdown crystallisation (Fix A)
    //
    // After establishing HWM = 1.1, a 90 % drawdown brings PPS to ~0.09.
    // Calling endEpochCrystallize() at the trough must NOT lower the HWM.
    //
    // With the fix: HWM remains 1.1. A partial recovery to PPS = 0.5 does NOT
    // satisfy pps > hwm (0.5 < 1.1), so canCrystallize() correctly returns false.
    // =========================================================================
    function test_hwm_stays_unchanged_on_drawdown() public {
        // Establish HWM at 1.1 (10 % yield, 0 % fee)
        _addToVault(100_000e6);              // totalAssets = 1.1 M, PPS = 1.1
        _crystallize();                       // pps > old(WAD=1.0) -> HWM = 1.1

        // canCrystallize() must be false now: PPS == HWM (no new profit)
        assertFalse(core.canCrystallize(), "after crystallize at PPS=1.1: canCrystallize must be false");

        // 90 % drawdown: remove 1 M -> vault has 100 k, PPS ~0.0909
        _drainFromVault(1_000_000e6);

        // Crystallize at trough -- FIX: HWM must remain at 1.1, NOT reset to 0.09
        _crystallize();

        // Partial recovery: add 400 k -> vault = 500 k, PPS = 0.5
        _addToVault(400_000e6);

        // FIX CONFIRMED: HWM = 1.1, PPS = 0.5 -> canCrystallize() must return false
        bool canCrystalliseNow = core.canCrystallize();
        assertFalse(
            canCrystalliseNow,
            "FIX CONFIRMED: HWM unchanged at 1.1, canCrystallize() correctly returns false at PPS=0.5"
        );
    }

    // =========================================================================
    // TEST 2 -- No performance fee charged while investors are in a net loss (Fix A)
    //
    // Same drawdown scenario as Test 1, but with a 20 % perf fee active.
    // With the fix, HWM stays at 1.1 after the trough crystallise.
    // A recovery to PPS = 0.5 is still below the original HWM, so no fee
    // should be charged.
    // =========================================================================
    function test_no_perf_fee_charged_on_loss_recovery() public {
        // Establish HWM at 1.1 with 0 % fee (clean setup)
        _addToVault(100_000e6);
        _crystallize();   // HWM = 1.1, no fee shares minted

        // 90 % drawdown -> PPS ~0.0909
        _drainFromVault(1_000_000e6);

        // Crystallize at trough -- FIX: HWM stays at 1.1
        _crystallize();

        // Switch on the production-level 20 % perf fee
        core.setPerfParamsUnsafe(PERF_RATE_20PCT, 0);

        // Partial recovery: vault = 500 k, PPS = 0.5 (still 50 % below deposit of 1.0)
        _addToVault(400_000e6);

        uint256 feeCollectorSharesBefore = core.balanceOf(address(this));

        // Crystallize -- must NOT charge fee (PPS 0.5 still below original HWM 1.1)
        _crystallize();

        uint256 feeCollectorSharesAfter = core.balanceOf(address(this));
        uint256 feeSharesMinted         = feeCollectorSharesAfter - feeCollectorSharesBefore;

        // FIX CONFIRMED: no fee while PPS is below the original HWM
        assertEq(
            feeSharesMinted,
            0,
            "FIX CONFIRMED: no performance fee minted -- PPS 0.5 is below original HWM 1.1"
        );

        // User is still in a loss position (500 k < 1 M deposited), but correctly not charged fees
        uint256 vaultBal      = IERC20(USDC_UNDERLYING).balanceOf(address(core));
        uint256 totalShares   = core.totalSupply();
        uint256 userShareValue = core.balanceOf(user) * vaultBal / totalShares;

        assertLt(
            userShareValue,
            1_000_000e6,
            "FIX: user is in a loss position (500k < 1M deposited) and correctly NOT charged a fee"
        );
    }

    // =========================================================================
    // TEST 3 -- Interval guard enforced inside _crystallize (Fix B)
    //
    // With the fix, _crystallize() itself checks the minimum interval.
    // A second call to endEpochCrystallize() within the 7-day window is a
    // silent no-op -- no fee is charged regardless of canCrystallize() result.
    // =========================================================================
    function test_interval_guard_enforced_in_crystallize() public {
        // Activate 20 % perf fee with a 7-day minimum crystallisation interval
        core.setPerfParamsUnsafe(PERF_RATE_20PCT, 7 days);

        // First crystallisation (legitimate)
        _addToVault(100_000e6); // PPS = 1.1

        uint256 feeBefore1 = core.balanceOf(address(this));
        _crystallize();          // fee charged on 100 k profit
        uint256 feeAfter1  = core.balanceOf(address(this));
        assertGt(feeAfter1 - feeBefore1, 0, "First crystallize: fee expected");

        // canCrystallize() correctly reports the interval has not elapsed
        assertFalse(
            core.canCrystallize(),
            "After first crystallize: canCrystallize() must be false (interval not elapsed)"
        );

        // Add more yield to push PPS above the new (post-dilution) HWM
        _addToVault(200_000e6); // total vault ~1.3 M+, PPS well above new HWM

        uint256 feeBefore2 = core.balanceOf(address(this));

        // FIX: endEpochCrystallize() is a no-op -- interval guard inside _crystallize blocks it
        _crystallize();

        uint256 feeAfter2 = core.balanceOf(address(this));

        // FIX CONFIRMED: second call produces zero fees within the 7-day window
        assertEq(
            feeAfter2 - feeBefore2,
            0,
            "FIX CONFIRMED: interval guard inside _crystallize blocks second fee within 7-day window"
        );
    }

    // =========================================================================
    // TEST 4 -- HWM reset exploit blocked (Fix A)
    //
    // A griever (or anyone, since endEpochCrystallize is ROLE_PUBLIC) calls
    // endEpochCrystallize() at the trough to try to reset the HWM.
    //
    // With the fix: the drawdown crystallise does NOT lower the HWM.
    // At PPS = 2.0 (still -80 % from peak HWM of 10.0), no performance fee
    // can be extracted because PPS < HWM.
    // =========================================================================
    function test_hwm_reset_exploit_blocked() public {
        core.setPerfParamsUnsafe(0, 0); // 0 % fee for HWM setup phase

        // Simulate 10x vault growth: totalAssets = 10 M, PPS = 10.0
        _addToVault(9_000_000e6);
        _crystallize();   // HWM = 10.0

        assertFalse(core.canCrystallize(), "HWM established at 10.0: canCrystallize must be false");

        // 95 % crash: vault drops from 10 M to 500 k, PPS = 0.5
        _drainFromVault(9_500_000e6);

        // Griever attempts HWM reset via the ROLE_PUBLIC endEpochCrystallize()
        address griever = makeAddr("griever");
        vm.prank(griever);
        QueueModule(address(core)).endEpochCrystallize(); // FIX: HWM stays at 10.0

        // Enable 20 % perf fee for the recovery phase
        core.setPerfParamsUnsafe(PERF_RATE_20PCT, 0);

        // Vault recovers to 2 M (PPS = 2.0 -- still 80 % below original HWM of 10.0)
        _addToVault(1_500_000e6);

        uint256 feeSharesBefore = core.balanceOf(address(this));
        _crystallize();  // PPS 2.0 < HWM 10.0 -> no fee
        uint256 feeSharesAfter  = core.balanceOf(address(this));
        uint256 feeSharesMinted = feeSharesAfter - feeSharesBefore;

        // FIX CONFIRMED: no fee extracted at PPS=2.0 while HWM is 10.0
        assertEq(
            feeSharesMinted,
            0,
            "FIX CONFIRMED: no performance fee at PPS=2.0 -- HWM correctly held at 10.0 despite griever call"
        );

        // User's share value reflects vault recovery with no fee dilution
        uint256 vaultBal    = IERC20(USDC_UNDERLYING).balanceOf(address(core));
        uint256 totalShares = core.totalSupply();
        uint256 userValue   = core.balanceOf(user) * vaultBal / totalShares;

        // User deposited at PPS=1.0, vault is now at PPS~2 -- user is in profit from deposit price
        // and correctly paid zero fees (since recovery has not cleared the peak HWM of 10.0)
        assertGt(userValue, 1_000_000e6, "User is nominally above deposit price at PPS~2 with no fees extracted");
    }
}
