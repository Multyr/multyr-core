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

    function deposit(uint256 amount) external returns (uint256 received) {
        depositCallCount++;
        if (depositShouldFail) revert("deposit disabled");
        token.transferFrom(coreVault_, address(this), amount);
        return amount;
    }

    function withdraw(uint256 amount, address to) external returns (uint256 sent) {
        withdrawCallCount++;
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
    // ISSUE 2 — refill() must not call the same underlying adapter twice when
    // it is registered as both the legacy `cfg.warmAdapter` and _warmAdapters[0]
    // (the default state after any updateConfig(cfg) with warmAdapter set).
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

        // Force a partial fill on the first call so the OLD code's loop would
        // have looped back around to A a second time.
        adapterA.setPerCallFillCap(300e6);

        vm.prank(address(coreVault));
        bufferManager.refill(500e6);

        assertEq(
            adapterA.withdrawCallCount(),
            1,
            "FIX: adapter A must be invoked exactly once per refill(), not twice"
        );
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
        bufferManager.forceRefill(500e6);

        assertEq(
            adapterA.withdrawCallCount(),
            1,
            "FIX: adapter A must be invoked exactly once per forceRefill(), not twice"
        );
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

        assertEq(adapterA.withdrawCallCount(), 1, "A called once (drained at 300)");
        assertEq(adapterB.withdrawCallCount(), 1, "B called once to cover the remainder");
        assertEq(usdc.balanceOf(address(coreVault)), 500e6, "full 500 delivered via A+B");
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
