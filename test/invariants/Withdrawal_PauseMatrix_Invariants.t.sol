// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// Withdrawal / pause matrix — review §20/§21 (Multyr Core Architecture Review,
// snapshot 0bab749) and docs/developer-response-recovery-architecture.{html,pdf}
// §9.
//
// Before this change, FLAG_PAUSED_WITHDRAWALS never gated EpochedQueueModule at
// all (requestInstantWithdrawal/requestEpochWithdrawal/closeCurrentEpoch/
// fundEpoch/claimEpochAssets had zero pause protection), while it DID gate
// ERC4626Module's forceWithdraw/forceWithdrawAll — the exact opposite of what
// the review requires (force exit must never be blocked by a generic emergency
// flag; the queue needs real breakers).
//
// This suite encodes the review §21 pause matrix directly: each of the five new
// breakers blocks only its own surface, guardianPause() reaches exactly the two
// breakers §20 approves for Guardian (instant settlement, epoch close/fund) and
// nothing else, and force exit is unaffected by pauseAll()/guardianPause() under
// any combination.
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness } from "../helpers/CoreHarness.sol";
import { MockUSDC } from "../helpers/MockUSDC.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";
import { CoreVault } from "../../src/core/CoreVault.sol";
import { ERC4626Module } from "../../src/core/modules/ERC4626Module.sol";
import { EpochedQueueModule, EpochQueueStorage } from "../../src/core/modules/EpochedQueueModule.sol";

contract Withdrawal_PauseMatrix_Invariants is Test {
    // MockParamsProvider.getQueueParams() default epoch duration.
    uint256 internal constant EPOCH_DURATION = 7 days;

    address internal owner;
    address internal guardian;
    address internal user;

    CoreHarness internal core;
    MockUSDC internal usdc;
    MockParamsProvider internal params;

    function setUp() public {
        owner = address(this);
        guardian = makeAddr("guardian");
        user = makeAddr("user");

        usdc = new MockUSDC();
        params = new MockParamsProvider();

        core = new CoreHarness(
            IERC20Metadata(address(usdc)), "Vault", "V", owner, owner, address(params)
        );
        core.setGuardian(guardian);

        usdc.mint(user, 10_000_000e6);
        vm.prank(user);
        IERC20(address(usdc)).approve(address(core), type(uint256).max);
    }

    function _deposit(uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        shares = ERC4626Module(address(core)).deposit(assets, user);
    }

    function _depositAndQueue(uint256 assets)
        internal
        returns (uint256 epochId, uint256 claimId)
    {
        uint256 shares = _deposit(assets);
        vm.prank(user);
        (epochId, claimId) = EpochedQueueModule(address(core)).requestEpochWithdrawal(shares);
    }

    function _depositQueueCloseFund(uint256 assets)
        internal
        returns (uint256 epochId, uint256 claimId)
    {
        (epochId, claimId) = _depositAndQueue(assets);
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        EpochedQueueModule(address(core)).closeCurrentEpoch();
        EpochedQueueModule(address(core)).fundEpoch(epochId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Instant-settlement breaker — Guardian-eligible (review §20)
    // ═══════════════════════════════════════════════════════════════════════

    function test_pauseInstantWithdrawalOnly_forcesQueueFallback_doesNotRevert() public {
        uint256 shares = _deposit(1_000_000e6);

        core.pauseInstantWithdrawalOnly(true);
        assertTrue(core.pausedInstantWithdrawal());

        vm.prank(user);
        (bool settledImmediately, uint256 epochId, uint256 claimId) =
            EpochedQueueModule(address(core)).requestInstantWithdrawal(shares);

        assertFalse(settledImmediately, "instant paused -> exit intent still recorded via queue fallback");
        EpochQueueStorage.EpochClaim memory claim =
            EpochedQueueModule(address(core)).epochClaim(epochId, claimId);
        assertEq(claim.user, user, "fallback claim correctly attributed to the real user");
    }

    function test_guardian_canTripButNotClearInstantWithdrawalBreaker() public {
        vm.prank(guardian);
        core.pauseInstantWithdrawalOnly(true);
        assertTrue(core.pausedInstantWithdrawal());

        vm.prank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        core.pauseInstantWithdrawalOnly(false);
        assertTrue(core.pausedInstantWithdrawal(), "guardian must not be able to clear its own breaker");
    }

    function test_owner_canTripInstantWithdrawalBreaker() public {
        core.pauseInstantWithdrawalOnly(true);
        assertTrue(core.pausedInstantWithdrawal());
    }

    function test_owner_canClearInstantWithdrawalBreaker_evenIfGuardianTrippedIt() public {
        vm.prank(guardian);
        core.pauseInstantWithdrawalOnly(true);
        assertTrue(core.pausedInstantWithdrawal());

        core.pauseInstantWithdrawalOnly(false); // owner, no prank
        assertFalse(core.pausedInstantWithdrawal());
    }

    function test_randomAddress_cannotTripInstantWithdrawalBreaker() public {
        vm.prank(user);
        vm.expectRevert(CoreVault.NotOwnerOrGuardian.selector);
        core.pauseInstantWithdrawalOnly(true);
    }

    function test_guardianPause_tripsInstantWithdrawalBreaker() public {
        uint256 shares = _deposit(1_000_000e6);

        vm.prank(guardian);
        core.guardianPause();
        assertTrue(core.pausedInstantWithdrawal(), "guardianPause must reach instant settlement (review section 20)");

        vm.prank(user);
        (bool settledImmediately,,) =
            EpochedQueueModule(address(core)).requestInstantWithdrawal(shares);
        assertFalse(settledImmediately, "instant settlement suppressed while guardianPause is active");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Queued-request breaker — owner-only, exceptional (review §20)
    // ═══════════════════════════════════════════════════════════════════════

    function test_pauseQueuedRequestOnly_blocksNewQueuedRequests() public {
        uint256 shares = _deposit(1_000_000e6);

        core.pauseQueuedRequestOnly(true);

        vm.prank(user);
        vm.expectRevert(EpochedQueueModule.QueuedRequestPaused.selector);
        EpochedQueueModule(address(core)).requestEpochWithdrawal(shares);
    }

    function test_pauseQueuedRequestOnly_alsoBlocksTheInstantFallbackPath() public {
        // requestInstantWithdrawal()'s queue-fallback must not be a bypass for
        // pauseQueuedRequestOnly() — same underlying risk (accepting a new
        // queued request during an active incident), same breaker. Force the
        // fallback branch deterministically via the lock period so this
        // exercises the fallback path rather than instant settlement.
        params.setLockPeriod(1 days);
        uint256 shares = _deposit(1_000_000e6);
        core.pauseQueuedRequestOnly(true);

        vm.prank(user);
        vm.expectRevert(EpochedQueueModule.QueuedRequestPaused.selector);
        EpochedQueueModule(address(core)).requestInstantWithdrawal(shares);
    }

    function test_guardian_cannotTripQueuedRequestBreaker() public {
        vm.prank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        core.pauseQueuedRequestOnly(true);
    }

    function test_guardianPause_doesNotBlockNewQueuedRequests() public {
        uint256 shares = _deposit(1_000_000e6);

        vm.prank(guardian);
        core.guardianPause();
        assertFalse(core.pausedQueuedRequest(), "guardianPause must never reach queued-request creation (review section 20)");

        vm.prank(user);
        EpochedQueueModule(address(core)).requestEpochWithdrawal(shares); // must not revert
    }

    function test_cancelEpochWithdrawal_remainsOpen_whileQueuedRequestPaused() public {
        (uint256 epochId, uint256 claimId) = _depositAndQueue(1_000_000e6);

        core.pauseQueuedRequestOnly(true);

        vm.prank(user);
        EpochedQueueModule(address(core)).cancelEpochWithdrawal(epochId, claimId); // must not revert
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Epoch close/fund breaker — Guardian-eligible (review §20)
    // ═══════════════════════════════════════════════════════════════════════

    function test_pauseEpochCloseFundOnly_blocksCloseAndFundAndSync() public {
        (uint256 epochId,) = _depositAndQueue(1_000_000e6);
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        vm.prank(guardian);
        core.pauseEpochCloseFundOnly(true);

        vm.expectRevert(EpochedQueueModule.EpochCloseFundPaused.selector);
        EpochedQueueModule(address(core)).closeCurrentEpoch();

        vm.expectRevert(EpochedQueueModule.EpochCloseFundPaused.selector);
        EpochedQueueModule(address(core)).syncOldestUnfundedEpoch();

        core.pauseEpochCloseFundOnly(false); // owner, no prank — guardian cannot clear (see below)
        EpochedQueueModule(address(core)).closeCurrentEpoch();

        vm.prank(guardian);
        core.pauseEpochCloseFundOnly(true);
        vm.expectRevert(EpochedQueueModule.EpochCloseFundPaused.selector);
        EpochedQueueModule(address(core)).fundEpoch(epochId);
    }

    function test_guardian_canTripButNotClearEpochCloseFundBreaker() public {
        vm.prank(guardian);
        core.pauseEpochCloseFundOnly(true);
        assertTrue(core.pausedEpochCloseFund());

        vm.prank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        core.pauseEpochCloseFundOnly(false);
        assertTrue(core.pausedEpochCloseFund(), "guardian must not be able to clear its own breaker");
    }

    function test_owner_canClearEpochCloseFundBreaker_evenIfGuardianTrippedIt() public {
        vm.prank(guardian);
        core.pauseEpochCloseFundOnly(true);
        assertTrue(core.pausedEpochCloseFund());

        core.pauseEpochCloseFundOnly(false); // owner, no prank
        assertFalse(core.pausedEpochCloseFund());
    }

    function test_guardianPause_blocksEpochCloseFund() public {
        _depositAndQueue(1_000_000e6);
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        vm.prank(guardian);
        core.guardianPause();

        vm.expectRevert(EpochedQueueModule.EpochCloseFundPaused.selector);
        EpochedQueueModule(address(core)).closeCurrentEpoch();
    }

    function test_pauseEpochCloseFundOnly_doesNotBlockNewQueuedRequestsOrCancel() public {
        (uint256 epochId, uint256 claimId) = _depositAndQueue(1_000_000e6);

        vm.prank(guardian);
        core.pauseEpochCloseFundOnly(true);

        vm.prank(user);
        EpochedQueueModule(address(core)).cancelEpochWithdrawal(epochId, claimId); // must not revert

        uint256 moreShares = _deposit(500_000e6);
        vm.prank(user);
        EpochedQueueModule(address(core)).requestEpochWithdrawal(moreShares); // must not revert
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Funded-claim breaker — owner-only, exceptional (review §20)
    // ═══════════════════════════════════════════════════════════════════════

    function test_pauseFundedClaimOnly_blocksClaimAndBatchClaim() public {
        (uint256 epochId, uint256 claimId) = _depositQueueCloseFund(1_000_000e6);

        core.pauseFundedClaimOnly(true);

        vm.prank(user);
        vm.expectRevert(EpochedQueueModule.FundedClaimPaused.selector);
        EpochedQueueModule(address(core)).claimEpochAssets(epochId, claimId);

        uint256[] memory ids = new uint256[](1);
        ids[0] = claimId;
        vm.prank(user);
        vm.expectRevert(EpochedQueueModule.FundedClaimPaused.selector);
        EpochedQueueModule(address(core)).batchClaimEpochAssets(epochId, ids);
    }

    function test_guardian_cannotTripFundedClaimBreaker() public {
        vm.prank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        core.pauseFundedClaimOnly(true);
    }

    function test_guardianPause_doesNotBlockFundedClaims() public {
        (uint256 epochId, uint256 claimId) = _depositQueueCloseFund(1_000_000e6);

        vm.prank(guardian);
        core.guardianPause();
        assertFalse(core.pausedFundedClaim(), "guardianPause must never reach funded claims (review section 20)");

        vm.prank(user);
        EpochedQueueModule(address(core)).claimEpochAssets(epochId, claimId); // must not revert
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Force-exit breaker — owner-only, dedicated, never generic (review §20)
    // ═══════════════════════════════════════════════════════════════════════

    function test_pauseForceExitOnly_blocksForceWithdrawAll() public {
        _deposit(1_000_000e6);

        core.pauseForceExitOnly(true);

        vm.prank(user);
        vm.expectRevert(ERC4626Module.ForceExitPaused.selector);
        ERC4626Module(address(core)).forceWithdrawAll(user, 0);
    }

    function test_guardian_cannotTripForceExitBreaker() public {
        vm.prank(guardian);
        vm.expectRevert(CoreVault.NotOwner.selector);
        core.pauseForceExitOnly(true);
    }

    function test_guardianPause_doesNotBlockForceExit() public {
        _deposit(1_000_000e6);

        vm.prank(guardian);
        core.guardianPause();
        assertFalse(core.pausedForceExit(), "force exit must never be reachable from guardianPause (review section 20)");

        vm.prank(user);
        uint256 got = ERC4626Module(address(core)).forceWithdrawAll(user, 0);
        assertGt(got, 0, "force exit succeeds despite an active guardianPause");
    }

    function test_pauseAll_doesNotBlockForceExit() public {
        _deposit(1_000_000e6);

        core.pauseAll();
        assertTrue(core.paused());

        vm.prank(user);
        uint256 got = ERC4626Module(address(core)).forceWithdrawAll(user, 0);
        assertGt(got, 0, "force exit succeeds despite pauseAll (review section 20, must never be a side effect)");
    }

    function test_pauseWithdrawalsOnly_doesNotBlockForceExit() public {
        _deposit(1_000_000e6);

        core.pauseWithdrawalsOnly(true);
        assertTrue(core.pausedWithdrawals());

        vm.prank(user);
        uint256 got = ERC4626Module(address(core)).forceWithdrawAll(user, 0);
        assertGt(got, 0, "force exit has its own dedicated breaker, independent of FLAG_PAUSED_WITHDRAWALS");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // pauseWithdrawalsOnly() as an owner-only aggregate — reaches exactly the
    // same two breakers as guardianPause() (instant settlement, epoch
    // close/fund) and nothing else. It must NOT reach queued-request creation
    // (review §19: exit intent stays recordable while settlement is paused)
    // or funded claims (review §20: no general administrative flag may ever
    // block them) — confirmed by a pre-existing test
    // (test_F2_pause_withdrawals_does_not_block_deposits in
    // CoreEngine_Integration_Hardening.t.sol) that already asserted queuing a
    // claim during pauseWithdrawalsOnly must succeed.
    // ═══════════════════════════════════════════════════════════════════════

    function test_pauseWithdrawalsOnly_blocksInstantSettlementAndEpochCloseFund_only() public {
        (uint256 epochId, uint256 claimId) = _depositAndQueue(1_000_000e6);
        uint256 moreShares = _deposit(1_000e6);

        core.pauseWithdrawalsOnly(true);

        // Instant settlement becomes unavailable (silently) -> falls back to
        // the (unblocked) queue path instead of reverting.
        vm.prank(user);
        (bool settledImmediately,,) =
            EpochedQueueModule(address(core)).requestInstantWithdrawal(moreShares);
        assertFalse(settledImmediately, "instant unavailable under pauseWithdrawalsOnly -> queue fallback");

        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        vm.expectRevert(EpochedQueueModule.EpochCloseFundPaused.selector);
        EpochedQueueModule(address(core)).closeCurrentEpoch();

        // Cancelling an already-submitted request must still work.
        vm.prank(user);
        EpochedQueueModule(address(core)).cancelEpochWithdrawal(epochId, claimId);
    }

    function test_pauseWithdrawalsOnly_doesNotBlockNewQueuedRequests() public {
        uint256 shares = _deposit(1_000_000e6);

        core.pauseWithdrawalsOnly(true);

        vm.prank(user);
        EpochedQueueModule(address(core)).requestEpochWithdrawal(shares); // must not revert
    }

    function test_pauseWithdrawalsOnly_doesNotBlockFundedClaims() public {
        (uint256 epochId, uint256 claimId) = _depositQueueCloseFund(1_000_000e6);

        core.pauseWithdrawalsOnly(true);

        vm.prank(user);
        EpochedQueueModule(address(core)).claimEpochAssets(epochId, claimId); // must not revert
    }

    // ═══════════════════════════════════════════════════════════════════════
    // unpauseAll() clears every granular flag alongside the legacy ones
    // ═══════════════════════════════════════════════════════════════════════

    function test_unpauseAll_clearsAllGranularFlags() public {
        core.pauseInstantWithdrawalOnly(true);
        core.pauseQueuedRequestOnly(true);
        core.pauseEpochCloseFundOnly(true);
        core.pauseFundedClaimOnly(true);
        core.pauseForceExitOnly(true);

        core.unpauseAll();

        assertFalse(core.pausedInstantWithdrawal());
        assertFalse(core.pausedQueuedRequest());
        assertFalse(core.pausedEpochCloseFund());
        assertFalse(core.pausedFundedClaim());
        assertFalse(core.pausedForceExit());
    }
}
