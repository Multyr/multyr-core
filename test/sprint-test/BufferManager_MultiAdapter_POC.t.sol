// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────────────────────────────────────────────────────────────────
// SPRINT SECURITY TEST — BufferManager multi-adapter generalization + refill fix
//
// ISSUE 1 — executeDeploy() / rebalance() hardcoded to exactly 1 or 2 adapters:
//   Both functions had `if (len == 1) {...} else if (len == 2) {...} else {
//   revert InvalidWarmAdapters(); }`, even though setWarmAdapters()/addWarmAdapter()
//   allow configuring an arbitrary number of adapters. A 3rd configured adapter made
//   deploys permanently revert.
//
// FIX: _deployToAdapters() tries _warmAdapters[0..len) in order, stopping at the
//      first success — works for any adapter count, including 0 fallbacks (1) and
//      N-way fallback chains.
//
// ISSUE 2 — refill()/forceRefill()/rebalance()/realizeForReserveAndOps() double-
//   withdrawal: each function withdrew from `cfg.warmAdapter` (legacy) first, THEN
//   looped over `_warmAdapters` INCLUDING index 0 — which is seeded with the same
//   legacy adapter address by _setConfig() whenever the array is empty at config
//   time (the common/default path). If the legacy call under-filled (remaining > 0),
//   the loop called the *same underlying adapter* a second time in the same
//   transaction — wasted gas at best, and for fee/slippage-charging adapters
//   (e.g. Morpho, which pads previewWithdraw by +1 per call), double per-call
//   overhead at worst. warmBalance()/_updateWarmNavCache() already guarded against
//   this exact double-counting on the read side; the withdraw side did not.
//
// FIX: _withdrawFromAdapters() (used by refill(), rebalance()'s refill branch, and
//      realizeForReserveAndOps()) and forceRefill()'s inline logic now skip the
//      legacy adapter if it is already present in _warmAdapters, mirroring the
//      dedup already used by warmBalance()/_updateWarmNavCache().
// ──────────────────────────────────────────────────────────────────────────────

import { Test } from "forge-std/Test.sol";
import { BufferManager } from "../../src/core/modules/BufferManager.sol";
import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";
import { IWarmAdapter } from "../../src/interfaces/IWarmAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    MockCoreVault,
    MockERC20
} from "../integration/BufferManager_WarmAdapters.t.sol";

/// @dev Minimal IWarmAdapter mock that tracks call counts and can cap how much it
///      releases per withdraw() call, so tests can force a partial fill and observe
///      exactly how many times the underlying adapter was invoked.
contract MockCountingWarmAdapter is IWarmAdapter {
    MockERC20 public immutable token;
    address public immutable coreVault_;

    uint256 public perCallFillCap = type(uint256).max;
    bool public depositShouldFail;
    bool public withdrawShouldFail;

    uint256 public withdrawCallCount;
    uint256 public depositCallCount;

    constructor(address token_, address core_) {
        token = MockERC20(token_);
        coreVault_ = core_;
    }

    function asset() external view returns (address) {
        return address(token);
    }

    function coreVault() external view returns (address) {
        return coreVault_;
    }

    function totalAssets() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function setPerCallFillCap(uint256 cap) external {
        perCallFillCap = cap;
    }

    function setDepositShouldFail(bool b) external {
        depositShouldFail = b;
    }

    function setWithdrawShouldFail(bool b) external {
        withdrawShouldFail = b;
    }

    function deposit(uint256 amount) external returns (uint256 received) {
        depositCallCount++;
        if (depositShouldFail) revert("deposit disabled");
        token.transferFrom(coreVault_, address(this), amount);
        return amount;
    }

    function withdraw(uint256 amount, address to) external returns (uint256 sent) {
        withdrawCallCount++;
        if (withdrawShouldFail) revert("withdraw disabled");
        uint256 bal = token.balanceOf(address(this));
        uint256 give = amount;
        if (give > perCallFillCap) give = perCallFillCap;
        if (give > bal) give = bal;
        token.transfer(to, give);
        return give;
    }
}

contract BufferManager_MultiAdapter_POC is Test {
    BufferManager internal bufferManager;
    MockCoreVault internal coreVault;
    MockERC20 internal usdc;

    address internal owner = address(this);

    function setUp() public {
        MockERC20 usdcImpl = new MockERC20("USDC", "USDC", 6);
        vm.etch(0xaf88d065e77c8cC2239327C5EDb3A432268e5831, address(usdcImpl).code);
        usdc = MockERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);

        coreVault = new MockCoreVault(address(usdc));
    }

    function _deployBufferManager() internal {
        IBufferManager.BufferConfig memory cfg;
        cfg.targetHotBps = 1000;
        cfg.minHotBps = 500;
        cfg.targetWarmBps = 1000;
        cfg.maxWarmBps = 2000;
        cfg.opsReserveTargetBps = 100;
        cfg.maxWarmSlippageBps = 0; // disabled: POC isolates call-count, not slippage
        cfg.asset = address(usdc);
        cfg.warmAdapter = address(0);
        cfg.twapWindowSec = 0;
        cfg.paused = false;

        bufferManager = new BufferManager(owner, address(coreVault), cfg);
        coreVault.setBufferManager(address(bufferManager));

        vm.prank(address(coreVault));
        usdc.approve(address(bufferManager), type(uint256).max);
    }

    // =========================================================================
    // ISSUE 2 — refill() must not call the same underlying adapter twice via two
    // DIFFERENT code paths when it is registered as both the legacy
    // `cfg.warmAdapter` and _warmAdapters[0] (the default state after any
    // updateConfig(cfg) with warmAdapter set). Retrying the SAME adapter via the
    // SAME code path for a residual partial fill (see the refill-regression tests
    // below) is legitimate and distinct from this dedup concern.
    // =========================================================================
    function test_refill_doesNotDoubleCall_legacyAdapterInArray() public {
        _deployBufferManager();

        MockCountingWarmAdapter adapterA = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        usdc.mint(address(adapterA), 1_000e6);

        // Register A as the legacy adapter -> _setConfig() backward-compat path
        // seeds _warmAdapters[0] = A too, since the array was empty.
        IBufferManager.BufferConfig memory cfg = bufferManager.getConfig();
        cfg.warmAdapter = address(adapterA);
        bufferManager.updateConfig(cfg);

        assertEq(bufferManager.getWarmAdapters().length, 1, "A seeded into array");
        assertEq(bufferManager.getWarmAdapters()[0], address(adapterA), "A is array[0]");

        // Force a partial fill on the first call. Without dedup, the OLD code
        // would call A once via the legacy special-case (delivers 300, remaining
        // 200) THEN loop back around to A again as _warmAdapters[0] (delivers the
        // remaining 200 in a 2nd call) = 3 calls total across two code paths. With
        // dedup, the legacy special-case is skipped entirely (A is in the array),
        // so all delivery happens through the single array-loop path — which now
        // retries A on its own residual = 2 calls total, not 3.
        adapterA.setPerCallFillCap(300e6);

        vm.prank(address(coreVault));
        bufferManager.refill(500e6);

        assertEq(
            adapterA.withdrawCallCount(),
            2,
            "dedup: only the array-loop path calls A (2 retries for 300+200), not 3 via both paths"
        );
        assertEq(usdc.balanceOf(address(coreVault)), 500e6, "full 500 delivered despite the per-call cap");
    }

    function test_forceRefill_doesNotDoubleCall_legacyAdapterInArray() public {
        _deployBufferManager();

        MockCountingWarmAdapter adapterA = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        usdc.mint(address(adapterA), 1_000e6);

        IBufferManager.BufferConfig memory cfg = bufferManager.getConfig();
        cfg.warmAdapter = address(adapterA);
        bufferManager.updateConfig(cfg);
        adapterA.setPerCallFillCap(300e6);

        vm.prank(address(coreVault));
        (bool ok, uint256 pulled) = bufferManager.forceRefill(500e6);

        // forceRefill() now shares _withdrawFromAdapters() with refill() (kpi4/fix-
        // refill-regression follow-up), so this is the same dedup + retry story:
        // legacy special-case skipped (A is in the array), array-loop path retries
        // A for the 300+200 residual = 2 calls total, not 3 via both paths.
        assertTrue(ok, "forceRefill succeeds");
        assertEq(pulled, 500e6, "full 500 delivered despite the per-call cap");
        assertEq(
            adapterA.withdrawCallCount(),
            2,
            "dedup: only the array-loop path calls A (2 retries for 300+200), not 3 via both paths"
        );
    }

    /// @dev forceRefill() had its own separate inline loop with the identical
    ///      single-pass-per-adapter bug as refill() — arguably worse, since it
    ///      backs forceWithdrawAll() (the guaranteed-exit / W2-policy path) and has
    ///      no slippage check to at least surface the under-delivery as a revert.
    ///      Now sharing _withdrawFromAdapters(), a reverting adapter is surfaced via
    ///      the same WarmWithdrawAdapterFailed event refill() uses, and forceRefill()
    ///      still falls through to the next adapter rather than returning ok=false
    ///      just because one adapter failed.
    function test_forceRefill_regressionFix_revertingAdapterEmitsSharedFailureEvent() public {
        _deployBufferManager();

        MockCountingWarmAdapter adapterA = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        MockCountingWarmAdapter adapterB = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        usdc.mint(address(adapterB), 1_000e6);
        adapterA.setWithdrawShouldFail(true);

        bufferManager.addWarmAdapter(address(adapterA));
        bufferManager.addWarmAdapter(address(adapterB));

        vm.expectEmit(true, false, false, true, address(bufferManager));
        emit BufferManager.WarmWithdrawAdapterFailed(address(adapterA), 500e6);

        vm.prank(address(coreVault));
        (bool ok, uint256 pulled) = bufferManager.forceRefill(500e6);

        assertTrue(ok, "B still delivers, so overall forceRefill succeeds");
        assertEq(pulled, 500e6, "full amount delivered by B despite A failing");
    }

    /// @dev Total-failure path (every adapter delivers nothing) still returns
    ///      ok=false and emits ForceRefillFailed — unchanged by sharing
    ///      _withdrawFromAdapters() with refill().
    function test_forceRefill_totalFailure_stillReturnsFalseAndEmitsForceRefillFailed() public {
        _deployBufferManager();

        MockCountingWarmAdapter adapterA = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        adapterA.setWithdrawShouldFail(true);
        bufferManager.addWarmAdapter(address(adapterA));
        // adapterA never funded and always reverts — nothing to deliver.

        vm.expectEmit(false, false, false, true, address(bufferManager));
        emit BufferManager.ForceRefillFailed(500e6);

        vm.prank(address(coreVault));
        (bool ok, uint256 pulled) = bufferManager.forceRefill(500e6);

        assertFalse(ok, "no adapter delivered anything");
        assertEq(pulled, 0);
    }

    // Sanity: with two genuinely distinct adapters, refill() must still fall
    // through from the (short) legacy/primary to the secondary — dedup must not
    // suppress real fallback behavior, only the duplicate-address case.
    function test_refill_stillFallsThroughToDistinctSecondAdapter() public {
        _deployBufferManager();

        MockCountingWarmAdapter adapterA = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        MockCountingWarmAdapter adapterB = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        usdc.mint(address(adapterA), 300e6);
        usdc.mint(address(adapterB), 1_000e6);

        IBufferManager.BufferConfig memory cfg = bufferManager.getConfig();
        cfg.warmAdapter = address(adapterA);
        bufferManager.updateConfig(cfg); // seeds array = [A]

        bufferManager.addWarmAdapter(address(adapterB)); // array = [A, B]

        vm.prank(address(coreVault));
        bufferManager.refill(500e6);

        // A is called twice: once delivering 300 (its full balance), then once
        // more since remaining > 0 after that — the retry loop can only learn A
        // is drained by trying again and observing a 0 return, not in advance.
        assertEq(adapterA.withdrawCallCount(), 2, "A drained at 300, then one 0-progress probe call");
        assertEq(adapterB.withdrawCallCount(), 1, "B called once to cover the remainder");
        assertEq(usdc.balanceOf(address(coreVault)), 500e6, "full 500 delivered via A+B");
    }

    // =========================================================================
    // REGRESSION — kpi4/fix-refill-regression: the dedup fix above (ISSUE 2) made
    // _withdrawFromAdapters() do a single pass per adapter instead of retrying on
    // partial fills. Confirmed via A/B test: adapter holds 1000e6 but rations
    // 300e6/call, refill(500e6) delivered only 300e6 (1 call) instead of 500e6
    // (2 calls). Three consequences: (1) DoS — with a realistic non-zero slippage
    // config, the 300/500 shortfall (40%) exceeds any sane threshold and refill()
    // reverts with SlippageExceeded whenever an adapter caps funds per call; (2)
    // under-delivery when funds were actually available; (3) an adapter revert was
    // silently swallowed with no visibility. This existing POC's
    // maxWarmSlippageBps=0 (see _deployBufferManager) hid all three, since it
    // asserted on withdrawCallCount, never on delivered balance.
    // =========================================================================

    /// @dev The exact regression scenario: 1000e6 available, 300e6/call cap,
    ///      500e6 requested, with a realistic 1% slippage config. Pre-fix this
    ///      would revert with SlippageExceeded (40% shortfall on a single pass).
    ///      Post-fix, the retry loop fills the full amount and no revert occurs.
    function test_refill_regressionFix_realisticSlippageNoLongerReverts() public {
        _deployBufferManager();

        IBufferManager.BufferConfig memory cfg = bufferManager.getConfig();
        cfg.maxWarmSlippageBps = 100; // 1% — realistic, not the POC's disabled 0
        bufferManager.updateConfig(cfg);

        MockCountingWarmAdapter adapterA = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        usdc.mint(address(adapterA), 1_000e6);
        bufferManager.addWarmAdapter(address(adapterA));
        adapterA.setPerCallFillCap(300e6);

        vm.prank(address(coreVault));
        bufferManager.refill(500e6); // must NOT revert with SlippageExceeded

        assertEq(usdc.balanceOf(address(coreVault)), 500e6, "full 500 delivered, not just the first 300");
        assertEq(adapterA.withdrawCallCount(), 2, "300 then 200 - retried on the residual");
    }

    /// @dev More fragmented than the headline scenario: a 150e6/call cap needs 4
    ///      retries to fill 500e6 (150+150+150+50), well under
    ///      MAX_ADAPTER_WITHDRAW_ATTEMPTS. Proves the retry isn't a one-shot
    ///      "try twice" special case but a genuine loop.
    function test_refill_regressionFix_multipleRetriesUntilFilled() public {
        _deployBufferManager();

        MockCountingWarmAdapter adapterA = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        usdc.mint(address(adapterA), 1_000e6);
        bufferManager.addWarmAdapter(address(adapterA));
        adapterA.setPerCallFillCap(150e6);

        vm.prank(address(coreVault));
        bufferManager.refill(500e6);

        assertEq(usdc.balanceOf(address(coreVault)), 500e6, "full 500 delivered across 4 retries");
        assertEq(adapterA.withdrawCallCount(), 4, "150+150+150+50 = 4 calls");
    }

    /// @dev An adapter that reverts on withdraw() must not be silently swallowed —
    ///      WarmWithdrawAdapterFailed makes the failure visible, even though the
    ///      call itself still falls through gracefully (doesn't revert the whole
    ///      refill(), and moves on to the next adapter).
    function test_refill_regressionFix_revertingAdapterEmitsFailureEvent() public {
        _deployBufferManager();

        MockCountingWarmAdapter adapterA = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        MockCountingWarmAdapter adapterB = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        usdc.mint(address(adapterB), 1_000e6);
        adapterA.setWithdrawShouldFail(true);

        bufferManager.addWarmAdapter(address(adapterA));
        bufferManager.addWarmAdapter(address(adapterB));

        vm.expectEmit(true, false, false, true, address(bufferManager));
        emit BufferManager.WarmWithdrawAdapterFailed(address(adapterA), 500e6);

        vm.prank(address(coreVault));
        bufferManager.refill(500e6);

        assertEq(usdc.balanceOf(address(coreVault)), 500e6, "B still delivers the full amount despite A failing");
    }

    /// @dev An adapter that always makes tiny nonzero progress (never returns 0,
    ///      never fully drains) must not loop forever — MAX_ADAPTER_WITHDRAW_ATTEMPTS
    ///      bounds the retry, and the shortfall is left for the next adapter (or
    ///      surfaces via the caller's own slippage check) rather than exhausting gas.
    function test_refill_regressionFix_retryBoundedByMaxAttempts() public {
        _deployBufferManager();

        MockCountingWarmAdapter adapterA = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        MockCountingWarmAdapter adapterB = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        usdc.mint(address(adapterA), 1_000e6);
        usdc.mint(address(adapterB), 1_000e6);
        adapterA.setPerCallFillCap(1); // dribbles 1 wei per call, never 0, never drained

        bufferManager.addWarmAdapter(address(adapterA));
        bufferManager.addWarmAdapter(address(adapterB));

        vm.prank(address(coreVault));
        bufferManager.refill(500e6);

        assertEq(adapterA.withdrawCallCount(), 8, "capped at MAX_ADAPTER_WITHDRAW_ATTEMPTS, not looping forever");
        assertEq(usdc.balanceOf(address(coreVault)), 500e6, "B covers the rest after A's bounded retry gives up");
    }

    // =========================================================================
    // ISSUE 1 — executeDeploy()/rebalance() must support more than 2 adapters.
    // Previously: len==3 unconditionally reverted InvalidWarmAdapters().
    // =========================================================================
    function test_executeDeploy_generalizesToThreeAdapters() public {
        _deployBufferManager();

        MockCountingWarmAdapter a1 = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        MockCountingWarmAdapter a2 = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        MockCountingWarmAdapter a3 = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        a1.setDepositShouldFail(true);
        a2.setDepositShouldFail(true);
        // a3 is the only adapter willing to accept the deposit

        bufferManager.addWarmAdapter(address(a1));
        bufferManager.addWarmAdapter(address(a2));
        bufferManager.addWarmAdapter(address(a3));
        assertEq(bufferManager.getWarmAdapters().length, 3, "3 adapters configured");

        usdc.mint(address(coreVault), 1_000e6);
        // Only a3 ever reaches transferFrom (a1/a2 revert before pulling funds),
        // but grant it the allowance it needs to pull from coreVault.
        vm.prank(address(coreVault));
        usdc.approve(address(a3), type(uint256).max);

        vm.prank(address(coreVault));
        bufferManager.executeDeploy(400e6);

        // a1/a2's deposit() reverts, which rolls back their own depositCallCount
        // increment too (EVM revert semantics) — so only a3's persisted counter is
        // observable here. The trace (forge test -vvv) shows both a1.deposit() and
        // a2.deposit() were attempted and reverted before a3 succeeded, which is the
        // actual behavior under test: previously len==3 reverted InvalidWarmAdapters()
        // before ever trying any adapter.
        assertEq(a3.depositCallCount(), 1, "a3 tried and succeeded");
        assertEq(usdc.balanceOf(address(a3)), 400e6, "funds landed in the 3rd adapter");
    }

    function test_rebalance_deployBranch_generalizesToThreeAdapters() public {
        _deployBufferManager();

        MockCountingWarmAdapter a1 = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        MockCountingWarmAdapter a2 = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        MockCountingWarmAdapter a3 = new MockCountingWarmAdapter(address(usdc), address(coreVault));
        a1.setDepositShouldFail(true);
        a2.setDepositShouldFail(true);

        bufferManager.addWarmAdapter(address(a1));
        bufferManager.addWarmAdapter(address(a2));
        bufferManager.addWarmAdapter(address(a3));
        vm.prank(address(coreVault));
        usdc.approve(address(a3), type(uint256).max);

        // 10_000 NAV, 80% hot -> plan() will want to deploy hot down to targetHotBps (10%)
        coreVault.setTotalAssets(10_000e6);
        usdc.mint(address(coreVault), 8_000e6);

        (, uint256 needDeploy) = bufferManager.plan();
        assertGt(needDeploy, 0, "should need to deploy");

        vm.prank(address(coreVault));
        bufferManager.rebalance();

        assertEq(a3.depositCallCount(), 1, "3rd adapter received the deploy via rebalance()");
        assertGt(usdc.balanceOf(address(a3)), 0, "funds landed in the 3rd adapter");
    }
}
