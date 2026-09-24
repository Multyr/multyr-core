// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "lib/forge-std/src/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {CoreHarness} from "../../helpers/CoreHarness.sol";
import {MockUSDC} from "../../helpers/MockUSDC.sol";
import {ERC4626Module} from "../../../src/core/modules/ERC4626Module.sol";
import {
    EpochedQueueModule,
    EpochQueueStorage
} from "../../../src/core/modules/EpochedQueueModule.sol";
import {
    MockQueueEpochParamsProvider
} from "../../sprint-test/QueueEpochModule_WithdrawFlow_POC.t.sol";
import {ClaimSettlementUpkeep} from "../../../src/automation/ClaimSettlementUpkeep.sol";

contract ClaimSettlementUpkeep_Test is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address keeperBot = makeAddr("keeperBot"); // an address with NO stake in any claim

    CoreHarness core;
    ClaimSettlementUpkeep upkeep;
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
        upkeep = new ClaimSettlementUpkeep(address(core));
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

    function _close() internal {
        t += 7 days + 1;
        vm.warp(t);
        _q().closeCurrentEpoch();
    }

    // ═════ 1. no work, no false positives ═════

    function test_checkUpkeep_noWorkWhenNothingFunded() public {
        uint256 sa = _deposit(alice, 1_000e6);
        _request(alice, sa);
        // not closed/funded yet
        (bool needed,) = upkeep.checkUpkeep("");
        assertFalse(needed, "nothing FUNDED yet -- no work");
    }

    function test_checkUpkeep_noWorkAfterEverythingSettled() public {
        uint256 sa = _deposit(alice, 1_000e6);
        (uint256 e, uint256 c) = _request(alice, sa);
        _close();
        _q().fundEpoch(e);

        (bool needed1, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed1);
        upkeep.performUpkeep(data);

        (bool needed2,) = upkeep.checkUpkeep("");
        assertFalse(needed2, "the one claim is settled -- nothing left to do");
        c;
    }

    // ═════ 2. the core property: keeper pays the CLAIM OWNER, not the caller ═════

    function test_performUpkeep_paysTheClaimOwner_notTheCaller() public {
        uint256 sa = _deposit(alice, 1_000e6);
        (uint256 e, uint256 c) = _request(alice, sa);
        _close();
        _q().fundEpoch(e);

        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        uint256 botBefore = IERC20(USDC).balanceOf(keeperBot);

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);
        vm.prank(keeperBot); // an address with zero stake in this claim calls performUpkeep
        upkeep.performUpkeep(data);

        assertEq(
            IERC20(USDC).balanceOf(alice), aliceBefore + 1_000e6, "alice, not the caller, is paid"
        );
        assertEq(IERC20(USDC).balanceOf(keeperBot), botBefore, "the keeper caller receives nothing");
        assertTrue(_q().epochClaim(e, c).claimed);
    }

    // ═════ 3. multiple claims, batch bound, cursor progression ═════

    function test_performUpkeep_settlesMultipleClaimants_acrossBatches() public {
        uint256 sa = _deposit(alice, 300e6);
        uint256 sb = _deposit(bob, 300e6);
        uint256 sc = _deposit(carol, 300e6);
        _deposit(dave, 1_000e6);
        (uint256 e, uint256 ca) = _request(alice, sa);
        (, uint256 cb) = _request(bob, sb);
        (, uint256 cc) = _request(carol, sc);
        _close();
        _q().fundEpoch(e);

        upkeep.setBatchSizes(2, 50); // force at least two ticks for three claims

        (bool needed1, bytes memory data1) = upkeep.checkUpkeep("");
        assertTrue(needed1);
        upkeep.performUpkeep(data1);

        // exactly two of the three should now be settled
        uint256 settledCount;
        if (_q().epochClaim(e, ca).claimed) settledCount++;
        if (_q().epochClaim(e, cb).claimed) settledCount++;
        if (_q().epochClaim(e, cc).claimed) settledCount++;
        assertEq(settledCount, 2, "batch size bound to 2");

        (bool needed2, bytes memory data2) = upkeep.checkUpkeep("");
        assertTrue(needed2, "one claim still outstanding");
        upkeep.performUpkeep(data2);

        assertTrue(_q().epochClaim(e, ca).claimed);
        assertTrue(_q().epochClaim(e, cb).claimed);
        assertTrue(_q().epochClaim(e, cc).claimed);
        assertEq(IERC20(USDC).balanceOf(alice), 10_000_000e6 - 300e6 + 300e6, "alice made whole");

        (bool needed3,) = upkeep.checkUpkeep("");
        assertFalse(needed3);
    }

    function test_cursor_advancesPastAnUnfundedEpoch_thenFindsALaterFundedOne() public {
        uint256 sa = _deposit(alice, 300e6);
        (uint256 e0, uint256 ca) = _request(alice, sa);
        _close(); // e0 closed, deliberately left UNFUNDED

        uint256 sb = _deposit(bob, 300e6);
        _deposit(dave, 1_000e6);
        (uint256 e1, uint256 cb) = _request(bob, sb);
        _close();
        _q().fundEpoch(e1); // e1 funded, e0 still is not

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);
        (uint256 epochId, uint256[] memory claimIds,,) =
            abi.decode(data, (uint256, uint256[], uint256, uint256));
        assertEq(epochId, e1, "skips the still-unfunded e0, finds work in e1");
        assertEq(claimIds.length, 1);
        assertEq(claimIds[0], cb);

        upkeep.performUpkeep(data);
        assertTrue(_q().epochClaim(e1, cb).claimed);
        assertFalse(_q().epochClaim(e0, ca).claimed, "e0's claim is untouched -- still not funded");
    }

    // ═════ 4. idempotency against self-claim ═════

    function test_selfClaim_thenKeeper_isANoOp_notADoubleClaim() public {
        uint256 sa = _deposit(alice, 1_000e6);
        (uint256 e, uint256 c) = _request(alice, sa);
        _close();
        _q().fundEpoch(e);

        vm.prank(alice);
        _q().claimEpochAssets(e, c); // alice claims herself before the keeper gets to it

        (bool needed,) = upkeep.checkUpkeep("");
        assertFalse(needed, "already self-claimed -- nothing left for the keeper");
    }

    function test_keeperFirst_thenSelfClaimReverts_alreadySettled() public {
        uint256 sa = _deposit(alice, 1_000e6);
        (uint256 e, uint256 c) = _request(alice, sa);
        _close();
        _q().fundEpoch(e);

        (, bytes memory data) = upkeep.checkUpkeep("");
        upkeep.performUpkeep(data);

        vm.prank(alice);
        vm.expectRevert(EpochedQueueModule.ClaimAlreadySettled.selector);
        _q().claimEpochAssets(e, c);
    }

    // ═════ 5. pause leaves the cursor untouched; resumes when unpaused ═════

    function test_performUpkeep_whilePaused_doesNotAdvanceTheCursor() public {
        uint256 sa = _deposit(alice, 1_000e6);
        (uint256 e, uint256 c) = _request(alice, sa);
        _close();
        _q().fundEpoch(e);

        (, bytes memory data) = upkeep.checkUpkeep("");

        core.pauseFundedClaimOnly(true);
        upkeep.performUpkeep(data); // pause check returns without settlement
        assertFalse(_q().epochClaim(e, c).claimed, "nothing settled while paused");

        core.pauseFundedClaimOnly(false);
        (bool needed, bytes memory data2) = upkeep.checkUpkeep("");
        assertTrue(needed, "cursor did not advance past the failed attempt -- retried");
        upkeep.performUpkeep(data2);
        assertTrue(_q().epochClaim(e, c).claimed, "succeeds once unpaused");
    }

    // ═════ 6. owner escape hatch ═════

    function test_excludeClaim_removesItFromTheScan() public {
        uint256 sa = _deposit(alice, 300e6);
        uint256 sb = _deposit(bob, 300e6);
        _deposit(dave, 1_000e6);
        (uint256 e, uint256 ca) = _request(alice, sa);
        (, uint256 cb) = _request(bob, sb);
        _close();
        _q().fundEpoch(e);

        upkeep.excludeClaim(e, ca, true);

        (, bytes memory data) = upkeep.checkUpkeep("");
        (, uint256[] memory claimIds,,) = abi.decode(data, (uint256, uint256[], uint256, uint256));
        assertEq(claimIds.length, 1);
        assertEq(claimIds[0], cb, "excluded claim is skipped, the other is still found");

        upkeep.performUpkeep(data);
        assertTrue(_q().epochClaim(e, cb).claimed);
        assertFalse(_q().epochClaim(e, ca).claimed, "excluded claim untouched by the keeper");

        // the excluded user can still self-claim -- exclusion only affects this keeper's scan
        vm.prank(alice);
        _q().claimEpochAssets(e, ca);
        assertTrue(_q().epochClaim(e, ca).claimed);
    }

    function test_onlyOwner_canExcludeOrConfigure() public {
        vm.prank(alice);
        vm.expectRevert();
        upkeep.excludeClaim(0, 1, true);

        vm.prank(alice);
        vm.expectRevert();
        upkeep.setBatchSizes(5, 100);

        vm.prank(alice);
        vm.expectRevert();
        upkeep.setCursor(0, 1);
    }

    function test_setBatchSizes_rejectsInvalidConfig() public {
        vm.expectRevert(ClaimSettlementUpkeep.BadBatchSize.selector);
        upkeep.setBatchSizes(0, 100);

        vm.expectRevert(ClaimSettlementUpkeep.BadBatchSize.selector);
        upkeep.setBatchSizes(10, 5); // scan bound must be >= claim bound
    }

    // ═════ 7. dust-scale claims -- zero-amount / edge cases don't break the scan ═════

    function test_checkUpkeep_skipsNeverCreatedClaimIds_afterAnEmptyEpoch() public {
        // close and fund an epoch with zero claims in it (nextClaimIdForEpoch == 0)
        _deposit(dave, 1_000e6);
        _close();
        uint256 e0 = 0; // the very first (empty) epoch
        _q().fundEpoch(e0);

        uint256 sa = _deposit(alice, 300e6);
        (uint256 e1, uint256 ca) = _request(alice, sa);
        _close();
        _q().fundEpoch(e1);

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);
        (uint256 epochId, uint256[] memory claimIds,,) =
            abi.decode(data, (uint256, uint256[], uint256, uint256));
        assertEq(epochId, e1);
        assertEq(claimIds.length, 1);
        assertEq(claimIds[0], ca);
    }

    function test_forgedCursorIsIgnored() public {
        uint256 a = _deposit(alice, 100e6);
        (uint256 e, uint256 c) = _request(alice, a);
        _close();
        _q().fundEpoch(e);
        upkeep.performUpkeep(abi.encode(e, new uint256[](0), type(uint256).max, type(uint256).max));
        assertTrue(_q().epochClaim(e, c).claimed);
        assertLe(upkeep.cursorEpochId(), _q().currentEpochId());
    }

    function test_skippedEpochIsRevisitedAfterFunding() public {
        uint256 a = _deposit(alice, 100e6);
        uint256 b = _deposit(bob, 100e6);
        (uint256 e0, uint256 c0) = _request(alice, a);
        _close();
        (uint256 e1, uint256 c1) = _request(bob, b);
        _close();
        _q().fundEpoch(e1);
        upkeep.performUpkeep("");
        assertTrue(_q().epochClaim(e1, c1).claimed);
        _q().fundEpoch(e0);
        (bool needed,) = upkeep.checkUpkeep("");
        assertTrue(needed);
        upkeep.performUpkeep("");
        assertTrue(_q().epochClaim(e0, c0).claimed);
    }

    function test_pausedClaimsDoNotRequestUpkeep() public {
        uint256 a = _deposit(alice, 100e6);
        (uint256 e,) = _request(alice, a);
        _close();
        _q().fundEpoch(e);
        core.pauseFundedClaimOnly(true);
        (bool needed,) = upkeep.checkUpkeep("");
        assertFalse(needed);
    }

    function test_poisonedClaimDoesNotBlockHealthyClaimAndBacksOff() public {
        uint256 a = _deposit(alice, 100e6);
        uint256 b = _deposit(bob, 100e6);
        (uint256 e, uint256 ca) = _request(alice, a);
        (, uint256 cb) = _request(bob, b);
        _close();
        _q().fundEpoch(e);
        vm.mockCallRevert(
            USDC, abi.encodeWithSelector(IERC20.transfer.selector, alice, 100e6), "blocked"
        );
        upkeep.performUpkeep("");
        assertFalse(_q().epochClaim(e, ca).claimed);
        assertTrue(_q().epochClaim(e, cb).claimed);
        assertGt(upkeep.retryAfter(e, ca), block.timestamp);
        (bool needed,) = upkeep.checkUpkeep("");
        assertFalse(needed);
        vm.clearMockedCalls();
        vm.warp(block.timestamp + upkeep.RETRY_DELAY());
        upkeep.performUpkeep("");
        assertTrue(_q().epochClaim(e, ca).claimed);
    }

    function test_boundedEmptyPagesProgressToPayableClaim() public {
        uint256 a = _deposit(alice, 100e6);
        uint256 b = _deposit(bob, 100e6);
        (uint256 e, uint256 ca) = _request(alice, a);
        (, uint256 cb) = _request(bob, b);
        _close();
        _q().fundEpoch(e);
        vm.prank(alice);
        _q().claimEpochAssets(e, ca);
        upkeep.setBatchSizes(1, 1);
        (bool needed,) = upkeep.checkUpkeep("");
        assertTrue(needed, "bounded empty page needs cursor progress");
        upkeep.performUpkeep("");
        assertEq(upkeep.cursorClaimId(), cb);
        vm.warp(block.timestamp + 1 minutes);
        upkeep.performUpkeep("");
        assertTrue(_q().epochClaim(e, cb).claimed);
    }
}
