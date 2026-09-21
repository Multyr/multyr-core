// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// Withdrawal Model — Economic Exit at Request: STATEFUL invariants.
//
// A handler drives random sequences of deposit / standard request / instant
// request / NAV gain / NAV loss / close / fund / claim against a CoreHarness and
// the invariants below are checked after every call. The unit-level statement of
// each property lives in test/unit/core/EconomicExit_Spec.t.sol; this suite is
// the "in any reachable state" version of W-1, W-2, W-3, W-4, W-5, W-6, W-9,
// W-11, W-13 and W-14.
// ─────────────────────────────────────────────────────────────────────────────

import { Test, console2 } from "lib/forge-std/src/Test.sol";
import { StdInvariant } from "lib/forge-std/src/StdInvariant.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness } from "../helpers/CoreHarness.sol";
import { MockUSDC } from "../helpers/MockUSDC.sol";
import { MockBufferManagerForTests } from "../helpers/MockBufferManagerForTests.sol";
import { ERC4626Module } from "../../src/core/modules/ERC4626Module.sol";
import { EpochedQueueModule, EpochQueueStorage } from "../../src/core/modules/EpochedQueueModule.sol";
import { MockQueueEpochParamsProvider } from "../sprint-test/QueueEpochModule_WithdrawFlow_POC.t.sol";

address constant EE_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

contract EconomicExitHandler is Test {
    CoreHarness public core;
    address[] public actors;

    struct Tracked {
        uint256 epochId;
        uint256 claimId;
        address user;
        uint256 assetsOwed;
        bool claimed;
    }

    Tracked[] public tracked;

    uint256 public t;

    // violation latches, read by the invariants
    bool public priceMovedAgainstRemainingHolders; // W-6
    bool public indexMovedByClaim;                 // W-13
    bool public claimNotPaidAtIndex;               // W-14
    bool public insolventOpSucceeded;              // W-3

    uint256 public calls_request;
    uint256 public calls_instant;
    uint256 public calls_claim;
    uint256 public calls_insolvent;

    constructor(CoreHarness core_, address[] memory actors_) {
        core = core_;
        actors = actors_;
        t = block.timestamp;
    }

    function trackedLength() external view returns (uint256) {
        return tracked.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pps() internal view returns (uint256) {
        uint256 ts = core.totalSupply();
        return ts == 0 ? 1e18 : core.totalAssets() * 1e18 / ts;
    }

    // ── actions ──────────────────────────────────────────────────────────

    function deposit(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 1e6, 500_000e6);
        vm.prank(a);
        try ERC4626Module(address(core)).deposit(amount, a) {} catch {}
    }

    function request(uint256 seed, uint256 pct) external {
        address a = _actor(seed);
        uint256 bal = core.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bal * bound(pct, 1, 100) / 100;
        if (shares == 0) return;

        uint256 ppsBefore = _pps();
        uint256 supplyBefore = core.totalSupply();
        vm.prank(a);
        try EpochedQueueModule(address(core)).requestEpochWithdrawal(shares) returns (uint256 e, uint256 c) {
            calls_request++;
            _afterRequest(e, c, a, ppsBefore, supplyBefore);
        } catch {}
    }

    function instant(uint256 seed, uint256 pct) external {
        address a = _actor(seed);
        uint256 bal = core.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bal * bound(pct, 1, 100) / 100;
        if (shares == 0) return;

        uint256 ppsBefore = _pps();
        uint256 supplyBefore = core.totalSupply();
        vm.prank(a);
        try EpochedQueueModule(address(core)).requestInstantWithdrawal(shares) returns (
            bool settled, uint256 e, uint256 c
        ) {
            calls_instant++;
            if (settled) {
                _checkPrice(ppsBefore, supplyBefore);
            } else {
                _afterRequest(e, c, a, ppsBefore, supplyBefore);
            }
        } catch {}
    }

    function _afterRequest(uint256 e, uint256 c, address a, uint256 ppsBefore, uint256 supplyBefore) internal {
        EpochQueueStorage.EpochClaim memory cl = EpochedQueueModule(address(core)).epochClaim(e, c);
        tracked.push(Tracked(e, c, a, cl.assetsOwed, false));
        _checkPrice(ppsBefore, supplyBefore);
    }

    /// @dev W-6: an exit at the current price does not move the price for remaining holders.
    ///      Rounding is in the vault's favour, so only a DROP is a violation.
    function _checkPrice(uint256 ppsBefore, uint256 supplyBefore) internal {
        if (core.totalSupply() == 0 || supplyBefore == 0) return;
        // one wei of asset-rounding spread across the supply, in WAD
        uint256 slack = 1e18 / core.totalSupply() + 1;
        if (_pps() + slack < ppsBefore) priceMovedAgainstRemainingHolders = true;
    }

    function gain(uint256 amount) external {
        MockUSDC(EE_USDC).mint(address(core), bound(amount, 0, 200_000e6));
    }

    function loss(uint256 pct) external {
        uint256 hot = IERC20(EE_USDC).balanceOf(address(core));
        uint256 amt = hot * bound(pct, 0, 90) / 100;
        if (amt == 0) return;
        vm.prank(address(core));
        IERC20(EE_USDC).transfer(address(0xdead), amt);
    }

    function close() external {
        t += 7 days + 1;
        vm.warp(t);
        try EpochedQueueModule(address(core)).closeCurrentEpoch() {} catch {}
    }

    function fund(uint256 seed) external {
        uint256 cur = EpochedQueueModule(address(core)).currentEpochId();
        if (cur == 0) return;
        try EpochedQueueModule(address(core)).fundEpoch(seed % cur) {} catch {}
    }

    function claim(uint256 seed) external {
        uint256 n = tracked.length;
        if (n == 0) return;
        uint256 i = seed % n;
        Tracked storage tr = tracked[i];
        if (tr.claimed) return;

        (, , uint256 indexBefore) = core.liabilityState();
        uint256 balBefore = IERC20(EE_USDC).balanceOf(tr.user);

        vm.prank(tr.user);
        try EpochedQueueModule(address(core)).claimEpochAssets(tr.epochId, tr.claimId) returns (uint256 paid) {
            calls_claim++;
            tr.claimed = true;
            // W-14: every claim is paid at the one index
            uint256 expected = indexBefore >= 1e18 ? tr.assetsOwed : tr.assetsOwed * indexBefore / 1e18;
            if (paid != expected || IERC20(EE_USDC).balanceOf(tr.user) - balBefore != paid) {
                claimNotPaidAtIndex = true;
            }
            // W-13: paying at the current index leaves the index unchanged. The payout is rounded
            // DOWN, so gross can be at most 1 wei higher than the exact proportional value: the index
            // can rise by at most 1e18 / totalOwed_after (+1 for its own floor), and never fall.
            // When the last claim leaves totalOwed == 0 the index is 1e18 by definition.
            (, uint256 owedAfter, uint256 indexAfter) = core.liabilityState();
            if (owedAfter > 0) {
                if (indexAfter < indexBefore || indexAfter - indexBefore > 1e18 / owedAfter + 2) {
                    indexMovedByClaim = true;
                }
            }
        } catch {}
    }

    /// @dev W-3: in insolvency mode deposits, mints and new requests must revert.
    function probeInsolvencyGuards(uint256 seed) external {
        if (!core.isInsolvent()) return;
        calls_insolvent++;
        address a = _actor(seed);

        vm.prank(a);
        (bool ok1,) = address(core).call(abi.encodeWithSignature("deposit(uint256,address)", 1e6, a));
        vm.prank(a);
        (bool ok2,) = address(core).call(abi.encodeWithSignature("mint(uint256,address)", 1e6, a));
        vm.prank(a);
        (bool ok3,) = address(core).call(abi.encodeCall(EpochedQueueModule.requestEpochWithdrawal, (1)));
        vm.prank(a);
        (bool ok4,) = address(core).call(abi.encodeCall(EpochedQueueModule.requestInstantWithdrawal, (1)));
        if (ok1 || ok2 || ok3 || ok4) insolventOpSucceeded = true;
    }
}

contract EconomicExit_Invariants_Test is StdInvariant, Test {
    CoreHarness internal core;
    EconomicExitHandler internal handler;
    address[] internal actors;

    function setUp() public {
        MockUSDC mock = new MockUSDC();
        vm.etch(EE_USDC, address(mock).code);

        MockQueueEpochParamsProvider params = new MockQueueEpochParamsProvider();
        core = new CoreHarness(
            IERC20Metadata(EE_USDC), "USDC Agg", "agUSDC", address(this), address(this), address(params)
        );
        core.setEpochDurationUnsafe(7 days);
        core.setExitFeesUnsafe(25, 0, 0);

        for (uint256 i; i < 4; i++) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            MockUSDC(EE_USDC).mint(a, 100_000_000e6);
            vm.prank(a);
            IERC20(EE_USDC).approve(address(core), type(uint256).max);
        }

        handler = new EconomicExitHandler(core, actors);

        // seed some liquidity so every action is reachable from the first call
        for (uint256 i; i < 4; i++) {
            vm.prank(actors[i]);
            ERC4626Module(address(core)).deposit(200_000e6, actors[i]);
        }

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](9);
        sels[0] = handler.deposit.selector;
        sels[1] = handler.request.selector;
        sels[2] = handler.instant.selector;
        sels[3] = handler.gain.selector;
        sels[4] = handler.loss.selector;
        sels[5] = handler.close.selector;
        sels[6] = handler.fund.selector;
        sels[7] = handler.claim.selector;
        sels[8] = handler.probeInsolvencyGuards.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: sels }));
    }

    // W-1
    function invariant_W1_totalAssetsIsSaturatingGrossMinusOwed() public view {
        uint256 g = core.grossAssets();
        uint256 o = core.totalOwed();
        assertEq(core.totalAssets(), g > o ? g - o : 0, "W-1");
    }

    // W-2
    function invariant_W2_noSharesEscrowedInTheVault() public view {
        assertEq(core.balanceOf(address(core)), 0, "W-2");
    }

    // W-4
    function invariant_W4_reservedNeverExceedsOwed() public view {
        assertLe(EpochedQueueModule(address(core)).reservedForClaims(), core.totalOwed(), "W-4");
    }

    // W-5 + W-9
    function invariant_W5_W9_totalOwedIsTheSumOfUnclaimedFixedAmounts() public view {
        uint256 sum;
        uint256 n = handler.trackedLength();
        for (uint256 i; i < n; i++) {
            (uint256 e, uint256 c,, uint256 fixedOwed, bool claimed) = handler.tracked(i);
            // W-9: never changes after request
            assertEq(EpochedQueueModule(address(core)).epochClaim(e, c).assetsOwed, fixedOwed, "W-9");
            if (!claimed) sum += fixedOwed;
        }
        assertEq(core.totalOwed(), sum, "W-5");
    }

    // W-3
    function invariant_W3_insolvencyBlocksDepositsMintsAndRequests() public view {
        assertFalse(handler.insolventOpSucceeded(), "W-3");
    }

    // W-6
    function invariant_W6_exitNeverMovesThePriceAgainstRemainingHolders() public view {
        assertFalse(handler.priceMovedAgainstRemainingHolders(), "W-6");
    }

    // W-13
    function invariant_W13_claimingDoesNotMoveTheIndex() public view {
        assertFalse(handler.indexMovedByClaim(), "W-13");
    }

    // W-14
    function invariant_W14_everyClaimIsPaidAtTheSameIndex() public view {
        assertFalse(handler.claimNotPaidAtIndex(), "W-14");
    }

    // the index is a pure function of state, always in (0, 1e18]
    function invariant_indexBounds() public view {
        (uint256 g, uint256 o, uint256 idx) = core.liabilityState();
        assertLe(idx, 1e18);
        if (o == 0 || g >= o) assertEq(idx, 1e18);
        assertEq(core.isInsolvent(), g < o);
    }

    // W-11
    function invariant_W11_viewsNeverRevert() public view {
        core.totalAssets();
        core.convertToShares(1e6);
        core.convertToAssets(1e6);
        core.previewDeposit(1e6);
        core.previewMint(1e6);
        core.previewWithdraw(1e6);
        core.previewRedeem(1e6);
        core.maxDeposit(actors[0]);
        core.maxMint(actors[0]);
    }

    function invariant_callSummary() public view {
        // Not an assertion: documents that the run reached the interesting states.
        console2.log("requests", handler.calls_request());
        console2.log("instants", handler.calls_instant());
        console2.log("claims", handler.calls_claim());
        console2.log("insolvency probes", handler.calls_insolvent());
    }
}
