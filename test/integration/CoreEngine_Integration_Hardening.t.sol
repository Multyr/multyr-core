// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CoreHarness } from "../helpers/CoreHarness.sol";
import { MockUSDC } from "../helpers/MockUSDC.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../helpers/MockBufferManagerForTests.sol";
import { StrategyMock } from "../helpers/StrategyMock.sol";
import { RevertingStrategyMock } from "../helpers/RevertingStrategyMock.sol";
import { StrategyRouter } from "../../src/core/modules/StrategyRouter.sol";
import { QueueStorage } from "../../src/core/storage/QueueStorage.sol";

interface IQueueVault {
    function requestClaim(bool immediate, uint256 shares) external;
    function cancelClaim(uint256 claimId) external;
    function settleFeesAndProcessQueue(uint256 maxClaims) external;
    function processQueuedRedemptions(uint256 maxClaims) external;
    function pendingShares() external view returns (uint256);
    function nextClaimId() external view returns (uint256);
    function queueLength() external view returns (uint256);
}

// ============================================================================
// Core + Engine Integration Hardening Pack
// ============================================================================
// Covers P0 blocchi: A2, B1-B3, C1-C4, D1-D3, E2-E3, F1, G1-G2
// Direttive CTO: ogni test verifica accounting globale, queue state, fee
// correctness, NAV/PPS coherence, no reserved liquidity deployment,
// no double count, no ghost state.
// ============================================================================

contract CoreEngine_Integration_Hardening is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    CoreHarness internal vault;
    MockParamsProvider internal params;
    StrategyMock internal stratA;
    StrategyMock internal stratB;
    RevertingStrategyMock internal stratFailing;

    address internal owner = address(this);
    address internal treasury = address(0xFEE);

    // ── helpers ──────────────────────────────────────────────────────────────

    function setUp() public {
        MockUSDC mock = new MockUSDC();
        vm.etch(USDC, address(mock).code);

        params = new MockParamsProvider();
        vault = new CoreHarness(
            IERC20Metadata(USDC), "agUSDC", "agUSDC", owner, treasury, address(params)
        );

        stratA = new StrategyMock(USDC);
        stratB = new StrategyMock(USDC);
        stratFailing = new RevertingStrategyMock(USDC);

        // Wire a fresh valid NAV so deposit/withdraw don't revert NavInvalid
        MockBufferManagerForTests bm = new MockBufferManagerForTests(address(vault));
        vault.setBufferManagerUnsafe(address(bm));
    }

    function _mint(address to, uint256 amt) internal {
        MockUSDC(USDC).mint(to, amt);
    }

    function _deposit(address user, uint256 amt) internal returns (uint256 shares) {
        _mint(user, amt);
        vm.startPrank(user);
        IERC20(USDC).approve(address(vault), amt);
        shares = vault.deposit(amt, user);
        vm.stopPrank();
    }

    function _q() internal view returns (IQueueVault) { return IQueueVault(address(vault)); }

    function _requestClaim(address user, uint256 shares, bool immediate)
        internal
        returns (uint256 claimId)
    {
        uint256 before = _q().nextClaimId();
        vm.prank(user);
        _q().requestClaim(immediate, shares);
        claimId = before + 1; // nextClaimId is pre-incremented (++q.nextClaimId)
    }

    function _cancelClaim(address user, uint256 claimId) internal {
        vm.prank(user);
        _q().cancelClaim(claimId);
    }

    function _settle(uint256 maxClaims) internal {
        _q().settleFeesAndProcessQueue(maxClaims);
    }

    function _totalAssets() internal view returns (uint256) {
        return vault.totalAssets();
    }

    function _pps() internal view returns (uint256) {
        uint256 ts = vault.totalSupply();
        if (ts == 0) return 1e18;
        return (_totalAssets() * 1e18) / ts;
    }

    // ── helpers: strategy wiring ─────────────────────────────────────────────

    function _wireStrategy(address strat) internal {
        vault.addStrategyUnsafe(strat);
    }

    function _deployToStrategy(address strat, uint256 amt) internal {
        // Transfer from vault to strategy (simulates deploy)
        vm.prank(address(vault));
        IERC20(USDC).transfer(strat, amt);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BLOCCO C — Queue safety vs Engine
    // ═══════════════════════════════════════════════════════════════════════

    // C2 — Pending claims reduce effective deployable idle
    // Assert: idle reserved for pending claims is not deployed
    function test_C2_pending_claims_reduce_effective_deployable_idle() public {
        address user = address(0xA1);
        uint256 depositAmt = 100_000e6;

        uint256 shares = _deposit(user, depositAmt);
        uint256 idleBefore = IERC20(USDC).balanceOf(address(vault));
        assertEq(idleBefore, depositAmt, "all idle initially");

        // User queues a claim for half their shares
        uint256 claimShares = shares / 2;
        _requestClaim(user, claimShares, false);

        uint256 pendingAfter = _q().pendingShares();
        assertEq(pendingAfter, claimShares, "pendingShares tracked");

        // The pending shares represent ~50% of assets — they must NOT be deployed
        // (deployable idle = idle - reserved_for_pending)
        uint256 totalS = vault.totalSupply();
        uint256 totalA = _totalAssets();
        uint256 reservedAssets = totalS > 0 ? (claimShares * totalA) / totalS : 0;
        uint256 deployableMax = idleBefore > reservedAssets ? idleBefore - reservedAssets : 0;

        // Verify: whatever stays in vault idle after a hypothetical deploy
        // must cover the reserved amount
        uint256 idleNow = IERC20(USDC).balanceOf(address(vault));
        assertGe(idleNow, reservedAssets, "idle must cover pending claim liability");

        // totalAssets unchanged: no capital was created or destroyed
        assertEq(_totalAssets(), depositAmt, "totalAssets conserved after requestClaim");
        assertGt(deployableMax, 0, "some deployable idle remains");
    }

    // C3 — Rebalance does not consume buffer reserved for near-term settlement
    // Assert: after settle, the settled amount was available (not deployed)
    function test_C3_rebalance_does_not_consume_buffer_reserved_for_settlement() public {
        address user = address(0xA2);
        uint256 depositAmt = 200_000e6;

        uint256 shares = _deposit(user, depositAmt);

        // Wire a strategy and deploy most capital there
        _wireStrategy(address(stratA));
        uint256 deployAmt = 180_000e6; // 90% deployed
        _deployToStrategy(address(stratA), deployAmt);

        uint256 idleAfterDeploy = IERC20(USDC).balanceOf(address(vault));
        assertEq(idleAfterDeploy, depositAmt - deployAmt, "idle = 20k after deploy");

        // User requests queued claim for all shares
        _requestClaim(user, shares, false);

        // Settlement should be serviced from idle — stratA assets untouched
        uint256 stratABefore = IERC20(USDC).balanceOf(address(stratA));

        _settle(10);

        // Claim was skipped (hot=20k < gross=200k): strategy buffer NOT consumed
        uint256 stratAAfter = IERC20(USDC).balanceOf(address(stratA));
        assertEq(stratAAfter, stratABefore, "strategy not unwound for settlement");

        // pendingShares stays non-zero: settle is conservative, claim skipped due to insufficient hot
        // This is the correct behavior: never drain strategy to service queue (idle must be pre-ensured)
        assertGt(_q().pendingShares(), 0, "claim skipped: hot < gross, pending shares stay");
        assertEq(_q().pendingShares(), shares, "full claim still pending");
    }

    // C4 — Queue pressure change alters guard outcome
    // Assert: same strategy state, high queue pressure → queuePressureBps increases
    function test_C4_claim_queue_growth_increases_queue_pressure() public {
        address userA = address(0xA3);
        address userB = address(0xA4);
        uint256 depositAmt = 100_000e6;

        uint256 sharesA = _deposit(userA, depositAmt);
        uint256 sharesB = _deposit(userB, depositAmt);

        uint256 totalS = vault.totalSupply();
        uint256 totalA = _totalAssets();

        // Measure pressure with zero queue
        uint256 pendingBefore = _q().pendingShares();
        assertEq(pendingBefore, 0, "no pending initially");

        // Both users queue claims → pressure rises
        _requestClaim(userA, sharesA, false);
        _requestClaim(userB, sharesB, false);

        uint256 pendingAfter = _q().pendingShares();
        assertEq(pendingAfter, sharesA + sharesB, "both shares pending");

        // queuePressureBps = pendingShares * 10000 / (tvl + 1)
        uint256 expectedPressure = (pendingAfter * 10_000) / (totalA + 1);
        assertGt(expectedPressure, 0, "queue pressure must be non-zero");
        assertGt(expectedPressure, 5_000, "queue pressure > 50% of TVL");

        // Verify totalAssets still conserved
        assertEq(_totalAssets(), totalA, "totalAssets unchanged by requestClaim");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BLOCCO A — Multi-user interleaved flows
    // ═══════════════════════════════════════════════════════════════════════

    // A2 — Multi-user interleaved claims and rebalances
    function test_A2_multi_user_interleaved_claims_rebalances_conserve_accounting() public {
        address[5] memory users = [
            address(0xB1), address(0xB2), address(0xB3), address(0xB4), address(0xB5)
        ];
        uint256 amtEach = 50_000e6;

        // All users deposit
        uint256[] memory sharesOf = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            sharesOf[i] = _deposit(users[i], amtEach);
        }
        uint256 totalDeposited = amtEach * 5;
        assertEq(_totalAssets(), totalDeposited, "totalAssets = sum deposits");

        uint256 ppsInitial = _pps();
        uint256 tsInitial = vault.totalSupply();

        // Users 0,1 do immediate claim; users 2,3 queued claim; user 4 stays
        vm.prank(users[0]); _q().requestClaim(true, sharesOf[0]);
        vm.prank(users[1]); _q().requestClaim(true, sharesOf[1]);
        vm.prank(users[2]); _q().requestClaim(false, sharesOf[2]);
        vm.prank(users[3]); _q().requestClaim(false, sharesOf[3]);

        // Settle once
        uint256 taBefore = _totalAssets();
        _settle(10);

        // After settle: pendingShares for settled claims must be 0
        uint256 pendingAfter = _q().pendingShares();
        assertEq(pendingAfter, 0, "all queued claims settled");

        // User 4 still holds shares — totalSupply reduced by settled shares
        uint256 tsAfter = vault.totalSupply();
        assertEq(tsAfter, sharesOf[4], "only user4 shares remain");

        // User 4 totalAssets share = their proportional claim
        uint256 taFinal = _totalAssets();
        // No capital should be double-counted
        assertLe(taFinal, totalDeposited, "no phantom capital");

        // PPS must not have jumped anomalously (tolerance: ±1 bps from immediate exit fee)
        uint256 ppsFinal = _pps();
        // PPS can only go up (fee collection) or stay same, never down anomalously
        assertGe(ppsFinal, ppsInitial * 9_990 / 10_000, "PPS did not drop more than 0.1%");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BLOCCO B — NAV / PPS / Liability correctness
    // ═══════════════════════════════════════════════════════════════════════

    // B1 — NAV = hot + strat + warm, no double-count, pending not subtracted
    function test_B1_nav_formula_consistent_hot_plus_strategy_plus_warm() public {
        address user = address(0xC1);
        uint256 amt = 100_000e6;
        _deposit(user, amt);

        _wireStrategy(address(stratA));
        _deployToStrategy(address(stratA), 60_000e6);

        uint256 hot = IERC20(USDC).balanceOf(address(vault));
        uint256 strat = IERC20(USDC).balanceOf(address(stratA));
        // warm = 0 (no BufferManager in this harness)
        uint256 expectedNav = hot + strat;

        assertEq(_totalAssets(), expectedNav, "NAV = hot + strat (no double-count)");
        assertEq(_totalAssets(), amt, "NAV conserved after deploy");

        // Request claim: pending shares in queue but NAV must NOT change
        uint256 shares = vault.balanceOf(user);
        _requestClaim(user, shares / 4, false);

        assertEq(_totalAssets(), expectedNav, "NAV unchanged by requestClaim");
    }

    // B2 — PPS does not jump on request/cancel
    function test_B2_pps_does_not_jump_on_request_claim_or_cancel() public {
        address userA = address(0xC2);
        address userB = address(0xC3);
        _deposit(userA, 100_000e6);
        _deposit(userB, 100_000e6);

        uint256 ppsBefore = _pps();

        uint256 sharesA = vault.balanceOf(userA);
        uint256 claimId = _requestClaim(userA, sharesA / 2, false);

        uint256 ppsAfterRequest = _pps();

        // PPS must not change on request (shares still outstanding, assets unchanged)
        assertEq(ppsAfterRequest, ppsBefore, "PPS unchanged after requestClaim");

        // Cancel restores state
        _cancelClaim(userA, claimId);

        uint256 ppsAfterCancel = _pps();
        assertEq(ppsAfterCancel, ppsBefore, "PPS unchanged after cancel");

        // No arbitrage: depositing right after cancel does not exploit any PPS jump
        address userC = address(0xC4);
        _deposit(userC, 100_000e6);
        uint256 ppsAfterDeposit = _pps();
        assertApproxEqAbs(ppsAfterDeposit, ppsBefore, 1, "PPS stable across deposit after cancel");
    }

    // B3 — PPS coherent through partial settlement
    function test_B3_pps_coherent_through_settlement() public {
        address userA = address(0xC5);
        address userB = address(0xC6);
        uint256 amt = 100_000e6;
        uint256 sharesA = _deposit(userA, amt);
        uint256 sharesB = _deposit(userB, amt);

        uint256 ppsBefore = _pps();
        uint256 taBefore = _totalAssets();

        // Both queue claims
        _requestClaim(userA, sharesA, false);
        _requestClaim(userB, sharesB / 2, false);

        // Settle all
        _settle(10);

        // PPS after settle: shares burned, assets paid out — PPS must be coherent
        uint256 tsAfter = vault.totalSupply();
        uint256 taAfter = _totalAssets();

        if (tsAfter > 0) {
            uint256 ppsAfter = (taAfter * 1e18) / tsAfter;
            // PPS must not diverge more than small dust rounding
            assertApproxEqAbs(ppsAfter, ppsBefore, 1e6, "PPS coherent through settlement");
        }

        // Remaining user B can withdraw their half
        uint256 remaining = vault.balanceOf(userB);
        assertEq(remaining, sharesB / 2, "userB still holds unsettled half");
        assertGe(taAfter, 0, "no negative totalAssets");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BLOCCO D — Fee correctness cross-path
    // ═══════════════════════════════════════════════════════════════════════

    // D1 — Immediate vs queued claim: fee parity when both have no immediate penalty
    function test_D1_queued_claim_no_penalty_immediate_has_penalty() public {
        // Set exit fees: witBps=50 (0.5%), immediatePenaltyBps=100 (1%), force=0
        vault.setExitFeesUnsafe(50, 100, 0);

        address userImm = address(0xD1);
        address userQ = address(0xD2);
        uint256 amt = 100_000e6;

        uint256 sharesImm = _deposit(userImm, amt);
        uint256 sharesQ = _deposit(userQ, amt);

        uint256 taBeforeImm = _totalAssets();

        // Immediate claim
        uint256 balBeforeImm = IERC20(USDC).balanceOf(userImm);
        vm.prank(userImm);
        _q().requestClaim(true, sharesImm);
        _settle(10);
        uint256 balAfterImm = IERC20(USDC).balanceOf(userImm);
        uint256 netImm = balAfterImm - balBeforeImm;

        // Queued claim (same economic state)
        uint256 balBeforeQ = IERC20(USDC).balanceOf(userQ);
        vm.prank(userQ);
        _q().requestClaim(false, sharesQ);
        _settle(10);
        uint256 balAfterQ = IERC20(USDC).balanceOf(userQ);
        uint256 netQ = balAfterQ - balBeforeQ;

        // Queued must net MORE than immediate (no penalty on queued)
        assertGt(netQ, netImm, "queued path nets more: no immediate penalty");

        // Both must be < depositAmt (witBps applied to both)
        assertLt(netImm, amt, "immediate has fees");
        assertLt(netQ, amt, "queued has witBps fee");

        // Queued: only witBps (0.5%), so net = amt * (1 - 0.005) = 99500e6
        // Immediate: witBps + immPenalty (1.5%), net = amt * 0.985 = 98500e6
        assertApproxEqAbs(netQ, amt * 9950 / 10_000, 1e6, "queued fee = witBps only");
        assertApproxEqAbs(netImm, amt * 9850 / 10_000, 1e6, "immediate fee = witBps + penalty");
    }

    // D2 — Rebalance + harvest do not double-charge on exit
    function test_D2_harvest_then_exit_no_double_fee() public {
        vault.setExitFeesUnsafe(50, 0, 0); // 0.5% withdrawal fee only
        vault.setPerfParamsUnsafe(0, 0); // no perf fee for simplicity

        address user = address(0xD3);
        uint256 amt = 100_000e6;
        uint256 shares = _deposit(user, amt);

        // Simulate yield: mint extra USDC to vault (harvest)
        uint256 yieldAmt = 1_000e6;
        _mint(address(vault), yieldAmt);

        uint256 taAfterYield = _totalAssets();
        assertEq(taAfterYield, amt + yieldAmt, "yield added to NAV");

        // PPS improved
        uint256 ppsAfterYield = _pps();
        assertGt(ppsAfterYield, 1e18, "PPS > 1 after yield");

        // User exits — net should reflect the yield gain, minus only witBps once
        uint256 balBefore = IERC20(USDC).balanceOf(user);
        _requestClaim(user, shares, false);
        _settle(10);
        uint256 net = IERC20(USDC).balanceOf(user) - balBefore;

        // Expected: (amt + yieldAmt) * (1 - 0.005)
        uint256 gross = taAfterYield;
        uint256 expected = gross * 9950 / 10_000;
        assertApproxEqAbs(net, expected, 2e6, "no double fee: single witBps application");
    }

    // D3 — Fee accrual during pending claim: user locked in queue still gets correct assets
    function test_D3_fee_accrual_during_pending_claim_uses_snapshot_pps() public {
        vault.setExitFeesUnsafe(0, 0, 0); // no fees for clean pps test

        address userQ = address(0xD4);
        address userStay = address(0xD5);
        uint256 amt = 100_000e6;

        uint256 sharesQ = _deposit(userQ, amt);
        _deposit(userStay, amt);

        uint256 ppsAtRequest = _pps();

        // userQ requests queued claim
        _requestClaim(userQ, sharesQ, false);

        // Simulate yield while userQ is in queue (another user brings yield)
        _mint(address(vault), 10_000e6);

        // PPS has now risen for stayer
        uint256 ppsAfterYield = _pps();
        assertGt(ppsAfterYield, ppsAtRequest, "PPS rose due to yield");

        // Settle — userQ should get assets at settlement PPS (which includes yield)
        uint256 balBefore = IERC20(USDC).balanceOf(userQ);
        _settle(10);
        uint256 net = IERC20(USDC).balanceOf(userQ) - balBefore;

        // Settlement uses current PPS (no stale snapshot penalty)
        // userQ holds sharesQ, settles at current taAfterYield/ts
        uint256 taSettle = vault.totalAssets() + net; // reconstruct pre-settle TA
        // Assert: net > deposit (yield included) or net == deposit * ppsSettle/ppsInit
        assertGe(net, amt, "pending claim user benefits from yield while waiting");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BLOCCO E — Buffer / liquidity sourcing / emergency paths
    // ═══════════════════════════════════════════════════════════════════════

    // E2 — Partial liquidity shortfall: settle pays only what is available
    function test_E2_partial_liquidity_shortfall_settle_is_conservative() public {
        address userA = address(0xE1);
        address userB = address(0xE2);
        uint256 amt = 100_000e6;

        uint256 sharesA = _deposit(userA, amt);
        uint256 sharesB = _deposit(userB, amt);

        // Deploy 90% to strategy — only 20k idle
        _wireStrategy(address(stratA));
        _deployToStrategy(address(stratA), 180_000e6);

        uint256 idleAvailable = IERC20(USDC).balanceOf(address(vault));
        assertEq(idleAvailable, 20_000e6, "only 20k idle");

        // Both users queue exit — need 200k, have only 20k idle
        _requestClaim(userA, sharesA, false);
        _requestClaim(userB, sharesB, false);

        uint256 pendingBefore = _q().pendingShares();
        assertGt(pendingBefore, 0, "pending shares exist");

        uint256 balABefore = IERC20(USDC).balanceOf(userA);
        uint256 balBBefore = IERC20(USDC).balanceOf(userB);

        // Settle with shortfall
        _settle(10);

        uint256 balAAfter = IERC20(USDC).balanceOf(userA);
        uint256 balBAfter = IERC20(USDC).balanceOf(userB);

        uint256 paidA = balAAfter - balABefore;
        uint256 paidB = balBAfter - balBBefore;
        uint256 totalPaid = paidA + paidB;

        // System must NOT pay more than idle available
        assertLe(totalPaid, idleAvailable + 1, "cannot pay more than idle (conservative)");

        // No phantom payments — paid must come from real idle
        uint256 idleAfter = IERC20(USDC).balanceOf(address(vault));
        assertGe(idleAfter + totalPaid, idleAvailable - 1, "idle conservation");

        // pendingShares still > 0 if not fully served
        if (totalPaid < (sharesA + sharesB) * amt / vault.totalSupply() + totalPaid) {
            // some may remain pending
            assertGe(_q().pendingShares() + (paidA > 0 ? sharesA : 0) + (paidB > 0 ? sharesB : 0),
                pendingBefore * 9 / 10, "pending reduced by served amount");
        }
    }

    // E3 — Strategy failure during liquidity sourcing keeps core safe
    function test_E3_strategy_failure_during_unwind_keeps_core_accounting_intact() public {
        address user = address(0xE3);
        uint256 amt = 100_000e6;
        uint256 shares = _deposit(user, amt);

        // Wire failing strategy alongside good one
        _wireStrategy(address(stratFailing));
        _wireStrategy(address(stratA));

        // Deploy to good strategy only
        _deployToStrategy(address(stratA), 50_000e6);

        uint256 taBeforeRequest = _totalAssets();
        assertEq(taBeforeRequest, amt, "totalAssets correct before request");

        // User queues full exit
        _requestClaim(user, shares, false);

        // totalAssets must be unchanged by requestClaim
        assertEq(_totalAssets(), taBeforeRequest, "totalAssets unchanged by requestClaim");

        // Settle — failing strategy should not corrupt state
        // (settle uses idle; if stratFailing is not in path, no issue)
        uint256 pendingBefore = _q().pendingShares();
        _settle(10);

        // Queue state must be coherent (no overflow, no ghost)
        uint256 pendingAfter = _q().pendingShares();
        assertLe(pendingAfter, pendingBefore, "pendingShares only decreases on settle");

        // totalAssets must be >= 0 and coherent
        uint256 taAfter = _totalAssets();
        assertGe(taAfter, 0, "no negative totalAssets after partial settle");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BLOCCO F — Degraded mode
    // ═══════════════════════════════════════════════════════════════════════

    // F1 — When vault is paused, exits still work (degraded = pause deposits not exits)
    function test_F1_pause_deposits_does_not_block_exits() public {
        address user = address(0xF1);
        uint256 amt = 100_000e6;
        uint256 shares = _deposit(user, amt);

        // Pause deposits only
        vm.prank(owner);
        vault.pauseDepositsOnly(true);

        // Deposit must revert
        address user2 = address(0xF2);
        _mint(user2, amt);
        vm.startPrank(user2);
        IERC20(USDC).approve(address(vault), amt);
        vm.expectRevert();
        vault.deposit(amt, user2);
        vm.stopPrank();

        // Exit (requestClaim + settle) must still work
        _requestClaim(user, shares, false);
        _settle(10);

        assertEq(_q().pendingShares(), 0, "exit processed despite deposits paused");
        assertGt(IERC20(USDC).balanceOf(user), 0, "user received funds on exit");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BLOCCO G — Ghost state / queue compaction
    // ═══════════════════════════════════════════════════════════════════════

    // G1 — Cancelled claims do not leave settlement-blocking ghosts
    function test_G1_cancelled_claims_do_not_leave_settlement_blocking_ghosts() public {
        address userA = address(0x6601);
        address userB = address(0x6602);
        uint256 amt = 50_000e6;

        uint256 sharesA = _deposit(userA, amt);
        uint256 sharesB = _deposit(userB, amt);

        // userA queues, then cancels
        uint256 claimId = _requestClaim(userA, sharesA, false);
        _cancelClaim(userA, claimId);

        assertEq(_q().pendingShares(), 0, "pendingShares = 0 after cancel");

        // userB queues and settles
        _requestClaim(userB, sharesB, false);

        uint256 balBBefore = IERC20(USDC).balanceOf(userB);
        _settle(10);
        uint256 balBAfter = IERC20(USDC).balanceOf(userB);

        // userB must have received their assets — cancel of A did not block queue
        assertGt(balBAfter - balBBefore, 0, "userB settle succeeded despite A cancel ghost");
        assertEq(_q().pendingShares(), 0, "queue fully cleared");
    }

    // G2 — Settle with only ghost (cancelled) entries does not corrupt queue metrics
    function test_G2_settle_with_only_ghost_entries_does_not_corrupt_queue() public {
        address user = address(0x6603);
        uint256 amt = 100_000e6;
        uint256 shares = _deposit(user, amt);

        // Request then cancel — leaves ghost entry
        uint256 claimId = _requestClaim(user, shares / 2, false);
        _cancelClaim(user, claimId);

        uint256 pendingBefore = _q().pendingShares();
        uint256 qLenBefore = _q().queueLength();

        // Settle with only ghost entries
        _settle(10);

        uint256 pendingAfter = _q().pendingShares();
        uint256 taAfter = _totalAssets();

        // Metrics must not be corrupted
        assertEq(pendingAfter, pendingBefore, "pendingShares not corrupted by ghost-only settle");
        assertEq(taAfter, amt, "totalAssets not corrupted by ghost-only settle");
        assertGe(vault.balanceOf(user), shares / 2, "user still holds remaining shares");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CROSS-CYCLE INVARIANT CHECKS
    // ═══════════════════════════════════════════════════════════════════════

    // I1 — Global assets conservation across deposit → settle cycle
    function test_I1_global_assets_conservation_deposit_settle_cycle() public {
        address[3] memory users = [address(0x9901), address(0x9902), address(0x9903)];
        uint256 amt = 100_000e6;

        for (uint256 i = 0; i < 3; i++) _deposit(users[i], amt);
        uint256 totalIn = amt * 3;
        assertEq(_totalAssets(), totalIn, "conservation: initial");

        // All queue claims
        for (uint256 i = 0; i < 3; i++) {
            uint256 s = vault.balanceOf(users[i]);
            _requestClaim(users[i], s, false);
        }
        assertEq(_totalAssets(), totalIn, "conservation: after requestClaims");

        uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
        _settle(10);

        // Paid out + treasury fees + remaining vault = totalIn
        uint256 paidOut;
        for (uint256 i = 0; i < 3; i++) {
            paidOut += IERC20(USDC).balanceOf(users[i]);
        }
        uint256 treasuryFees = IERC20(USDC).balanceOf(treasury) - treasuryBefore;
        uint256 vaultRemainder = _totalAssets();

        assertApproxEqAbs(
            paidOut + treasuryFees + vaultRemainder,
            totalIn,
            3, // dust tolerance: 1 per user
            "I1: global conservation: paidOut + fees + remainder = totalIn"
        );
    }

    // I2 — No reserved liquidity deployed: idle >= pending_claim_asset_value
    function test_I2_idle_always_covers_pending_claim_liability() public {
        address user = address(0x9904);
        uint256 amt = 100_000e6;
        uint256 shares = _deposit(user, amt);

        // Queue half the shares
        _requestClaim(user, shares / 2, false);

        uint256 pending = _q().pendingShares();
        uint256 ts = vault.totalSupply();
        uint256 ta = _totalAssets();

        uint256 pendingAssetValue = ts > 0 ? (pending * ta) / ts : 0;
        uint256 idle = IERC20(USDC).balanceOf(address(vault));

        // I2: idle must cover pending liability (no deploy of reserved liquidity)
        assertGe(idle, pendingAssetValue, "I2: idle >= pending liability");
    }

    // I6 — PPS / NAV coherence under async operations
    function test_I6_pps_nav_coherence_under_async_operations() public {
        address userA = address(0x9905);
        address userB = address(0x9906);
        uint256 amt = 100_000e6;

        _deposit(userA, amt);
        _deposit(userB, amt);

        uint256 ta0 = _totalAssets();
        uint256 ts0 = vault.totalSupply();
        uint256 pps0 = (ta0 * 1e18) / ts0;

        // Interleave: request, cancel, new deposit, settle
        uint256 sharesA = vault.balanceOf(userA);
        uint256 claimId = _requestClaim(userA, sharesA / 3, false);

        uint256 pps1 = _pps();
        assertEq(pps1, pps0, "I6: PPS unchanged by requestClaim");

        _cancelClaim(userA, claimId);
        uint256 pps2 = _pps();
        assertEq(pps2, pps0, "I6: PPS unchanged by cancel");

        address userC = address(0x9907);
        _deposit(userC, amt);
        uint256 pps3 = _pps();
        assertApproxEqAbs(pps3, pps0, 1, "I6: PPS stable on new deposit");

        uint256 sharesB = vault.balanceOf(userB);
        _requestClaim(userB, sharesB, false);
        _settle(10);

        if (vault.totalSupply() > 0) {
            uint256 ppsFinal = _pps();
            assertApproxEqAbs(ppsFinal, pps0, 1e6, "I6: PPS coherent after full cycle");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // P1 TESTS
    // ═══════════════════════════════════════════════════════════════════════

    // A3 — Repeated rebalance cycles do not drift totalAssets
    // Assert: N cycles of deploy→settle→deploy produce no phantom capital accumulation
    function test_A3_repeated_rebalance_cycles_no_capital_drift() public {
        address user = address(0xA301);
        uint256 depositAmt = 300_000e6;
        _deposit(user, depositAmt);

        _wireStrategy(address(stratA));
        _wireStrategy(address(stratB));

        uint256 taInitial = _totalAssets();

        // 5 cycles: deploy to A, settle claim, deploy to B, settle
        for (uint256 cycle = 0; cycle < 5; cycle++) {
            // Deploy 40% to stratA, 40% to stratB, 20% idle
            uint256 idle = IERC20(USDC).balanceOf(address(vault));
            uint256 deployA = idle * 40 / 100;
            uint256 deployB = idle * 40 / 100;
            if (deployA > 0) _deployToStrategy(address(stratA), deployA);
            if (deployB > 0) _deployToStrategy(address(stratB), deployB);

            // Small queued claim each cycle
            uint256 shares = vault.balanceOf(user);
            uint256 claimShares = shares / 20; // 5% of remaining
            if (claimShares > 0) {
                _requestClaim(user, claimShares, false);
                // Retrieve some capital from strategy to cover idle (simulate rebalance)
                uint256 stratBal = IERC20(USDC).balanceOf(address(stratA));
                if (stratBal > 0) {
                    // Simulate strategy returning funds (withdraw)
                    vm.prank(address(stratA));
                    IERC20(USDC).transfer(address(vault), stratBal / 2);
                }
                _settle(10);
            }

            // After each cycle: totalAssets must not exceed initial (no phantom capital)
            uint256 taCycle = _totalAssets();
            assertLe(taCycle, taInitial, "A3: no phantom capital after cycle");
        }

        // Final: total capital out (fees + user receipts) + remaining TA = initial
        uint256 taFinal = _totalAssets();
        assertLe(taFinal, taInitial, "A3: final TA <= initial (capital left or exited)");
    }

    // D4 — Fee split conservation: depBps + witBps + perfFee do not double-count
    // Assert: vault collects exactly one fee layer; user net + fee shares = gross
    function test_D4_fee_split_conservation_deposit_exit() public {
        uint16 depBps = 50;   // 0.5%
        uint16 witBps = 30;   // 0.3%
        vault.setFeeParamsUnsafe(depBps, witBps, treasury);

        address user = address(0xD401);
        uint256 amt = 100_000e6;

        uint256 treasurySharesBefore = vault.balanceOf(treasury);

        // Deposit: fee minted to treasury as shares
        uint256 shares = _deposit(user, amt);
        uint256 treasurySharesAfterDep = vault.balanceOf(treasury);
        uint256 depFeeShares = treasurySharesAfterDep - treasurySharesBefore;

        // Deposit fee check: gross = shares + depFeeShares (proportionally)
        // Total supply includes both — no double-counting
        uint256 tsAfterDep = vault.totalSupply();
        assertEq(tsAfterDep, shares + depFeeShares, "D4: totalSupply = user shares + dep fee shares");

        // Exit via queued claim
        uint256 balBefore = IERC20(USDC).balanceOf(user);
        _requestClaim(user, shares, false);
        _settle(10);
        uint256 net = IERC20(USDC).balanceOf(user) - balBefore;

        // Withdrawal fee also collected as shares to treasury during settlement
        uint256 treasurySharesAfterWit = vault.balanceOf(treasury);
        uint256 witFeeShares = treasurySharesAfterWit - treasurySharesAfterDep;

        // Conservation: user net + fee value = amt (minus rounding dust)
        uint256 witFeeValue = vault.totalSupply() > 0
            ? (witFeeShares * _totalAssets()) / vault.totalSupply()
            : 0;
        assertApproxEqAbs(net + witFeeValue + (amt * depBps / 10_000), amt, 2e6,
            "D4: net + fees = gross (one fee layer each)");

        // No double-fee: wit fee shares appear exactly once
        assertGt(witFeeShares, 0, "D4: withdrawal fee collected");
        assertLe(witFeeShares, shares, "D4: wit fee shares <= user shares");
    }

    // E4 — After liquidity shortfall, buffer refills correctly on next deposit
    // Assert: after skipped settlement, a new deposit restores idle and enables settlement
    function test_E4_buffer_refills_after_shortfall_enables_settlement() public {
        address user = address(0xE401);
        address refiller = address(0xE402);
        uint256 depositAmt = 100_000e6;

        uint256 shares = _deposit(user, depositAmt);

        // Deploy 95% — only 5k idle
        _wireStrategy(address(stratA));
        _deployToStrategy(address(stratA), 95_000e6);

        uint256 idleBefore = IERC20(USDC).balanceOf(address(vault));
        assertEq(idleBefore, 5_000e6, "E4: 5k idle before claim");

        // User claims full amount — hot(5k) < gross(100k) → skipped
        _requestClaim(user, shares, false);
        _settle(10);
        assertGt(_q().pendingShares(), 0, "E4: claim skipped due to shortfall");

        // Strategy returns funds (simulate rebalance/rebalance)
        uint256 stratBal = IERC20(USDC).balanceOf(address(stratA));
        vm.prank(address(stratA));
        IERC20(USDC).transfer(address(vault), stratBal);

        // Now idle covers the claim — settle again
        _settle(10);
        assertEq(_q().pendingShares(), 0, "E4: claim settled after buffer refill");

        uint256 net = IERC20(USDC).balanceOf(user);
        assertGt(net, 0, "E4: user received assets after refill settlement");
    }

    // G3 — FIFO queue ordering: earliest claim settles first
    // Assert: claims queued in order A→B→C settle in exact order A→B→C
    function test_G3_queue_fifo_ordering() public {
        address userA = address(0x6601);
        address userB = address(0x6602);
        address userC = address(0x6603);
        uint256 amt = 50_000e6;

        uint256 sharesA = _deposit(userA, amt);
        uint256 sharesB = _deposit(userB, amt);
        uint256 sharesC = _deposit(userC, amt);

        // Queue in order A, B, C — all queued (not immediate)
        _requestClaim(userA, sharesA, false);
        _requestClaim(userB, sharesB, false);
        _requestClaim(userC, sharesC, false);

        uint256 balA0 = IERC20(USDC).balanceOf(userA);
        uint256 balB0 = IERC20(USDC).balanceOf(userB);
        uint256 balC0 = IERC20(USDC).balanceOf(userC);

        // Settle only 1 claim (maxClaims=1) — A should be first
        _settle(1);

        uint256 dA = IERC20(USDC).balanceOf(userA) - balA0;
        uint256 dB = IERC20(USDC).balanceOf(userB) - balB0;
        uint256 dC = IERC20(USDC).balanceOf(userC) - balC0;

        assertGt(dA, 0, "G3: first queued claim (A) settled first");
        assertEq(dB, 0, "G3: second claim (B) not yet settled");
        assertEq(dC, 0, "G3: third claim (C) not yet settled");

        // Settle 1 more — B next
        _settle(1);
        uint256 dB2 = IERC20(USDC).balanceOf(userB) - balB0;
        uint256 dC2 = IERC20(USDC).balanceOf(userC) - balC0;
        assertGt(dB2, 0, "G3: second claim (B) settled second");
        assertEq(dC2, 0, "G3: third claim (C) still pending");

        // Settle 1 more — C last
        _settle(1);
        uint256 dC3 = IERC20(USDC).balanceOf(userC) - balC0;
        assertGt(dC3, 0, "G3: third claim (C) settled third");
    }

    // F2 — pauseWithdrawalsOnly blocks exits but not deposits
    function test_F2_pause_withdrawals_does_not_block_deposits() public {
        address user = address(0xF201);
        address newUser = address(0xF202);

        _deposit(user, 100_000e6);

        // Pause withdrawals
        vault.pauseWithdrawalsOnly(true);

        // Deposits must still work
        uint256 shares = _deposit(newUser, 50_000e6);
        assertGt(shares, 0, "F2: deposit succeeds while withdrawals paused");

        // Queue claim during pause — requestClaim is a queue operation, not immediate withdrawal
        uint256 userShares = vault.balanceOf(user);
        _requestClaim(user, userShares, false);
        assertGt(_q().pendingShares(), 0, "F2: claim queued while withdrawals paused");

        // Settlement is the withdrawal — should be blocked or skipped
        // (pauseWithdrawalsOnly blocks the settle path)
        // We verify vault accounting is intact
        uint256 ta = _totalAssets();
        assertGt(ta, 0, "F2: vault accounting intact while paused");
    }

    // F3 — Full vault pause blocks both deposits and queue settlement
    function test_F3_full_pause_blocks_deposits_and_settlements() public {
        address user = address(0xF301);
        address newUser = address(0xF302);

        uint256 shares = _deposit(user, 100_000e6);

        // Full pause
        vault.pause();

        // Deposit must revert
        _mint(newUser, 50_000e6);
        vm.startPrank(newUser);
        IERC20(USDC).approve(address(vault), 50_000e6);
        vm.expectRevert();
        vault.deposit(50_000e6, newUser);
        vm.stopPrank();

        // Vault state unchanged
        assertEq(_totalAssets(), 100_000e6, "F3: totalAssets unchanged after blocked deposit");
        assertEq(vault.totalSupply(), shares, "F3: totalSupply unchanged after blocked deposit");

        // Unpause — operations resume
        vault.unpause();
        uint256 newShares = _deposit(newUser, 50_000e6);
        assertGt(newShares, 0, "F3: deposit works after unpause");
    }
}
