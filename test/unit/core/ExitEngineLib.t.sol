// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ExitEngineLib } from "../../../src/core/libraries/ExitEngineLib.sol";
import { ExitFeeLib } from "../../../src/core/libraries/ExitFeeLib.sol";
import { CoreStorage } from "../../../src/core/storage/CoreStorage.sol";
import { QueueStorage } from "../../../src/core/storage/QueueStorage.sol";
import { FeeStorage } from "../../../src/core/storage/FeeStorage.sol";
import { Percentage } from "../../../src/libs/Percentage.sol";

/// @title ExitEngineLib Unit Tests
/// @dev Tests the pure library functions in isolation
contract ExitEngineLibTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════════
    // rollEpochIfNeeded
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_rollEpochIfNeeded_noRollBeforeExpiry() public {
        CoreStorage.Layout storage core = CoreStorage.layout();
        core.epochStart = uint64(block.timestamp);
        core.epochDuration = 7 days;
        core.epochWithdrawn = 1000e6;

        bool rolled = ExitEngineLib.rollEpochIfNeeded(core);

        assertFalse(rolled, "should not roll before expiry");
        assertEq(core.epochWithdrawn, 1000e6, "epochWithdrawn should not reset");
    }

    function test_rollEpochIfNeeded_rollsAfterExpiry_7d() public {
        CoreStorage.Layout storage core = CoreStorage.layout();
        core.epochStart = uint64(block.timestamp);
        core.epochDuration = 7 days;
        core.epochWithdrawn = 5000e6;

        vm.warp(block.timestamp + 7 days);

        bool rolled = ExitEngineLib.rollEpochIfNeeded(core);

        assertTrue(rolled, "should roll after 7 days");
        assertEq(core.epochWithdrawn, 0, "epochWithdrawn should reset");
        assertGe(core.epochStart, uint64(block.timestamp - 7 days), "epochStart should advance");
    }

    function test_rollEpochIfNeeded_rollsAfterExpiry_1d() public {
        CoreStorage.Layout storage core = CoreStorage.layout();
        core.epochStart = uint64(block.timestamp);
        core.epochDuration = 1 days;
        core.epochWithdrawn = 100e6;

        vm.warp(block.timestamp + 1 days + 1);

        bool rolled = ExitEngineLib.rollEpochIfNeeded(core);

        assertTrue(rolled, "should roll after 1 day");
        assertEq(core.epochWithdrawn, 0, "epochWithdrawn should reset");
    }

    function test_rollEpochIfNeeded_rollsAfterExpiry_30d() public {
        CoreStorage.Layout storage core = CoreStorage.layout();
        core.epochStart = uint64(block.timestamp);
        core.epochDuration = 30 days;
        core.epochWithdrawn = 999e6;

        vm.warp(block.timestamp + 30 days);

        bool rolled = ExitEngineLib.rollEpochIfNeeded(core);

        assertTrue(rolled, "should roll after 30 days");
        assertEq(core.epochWithdrawn, 0, "epochWithdrawn should reset");
    }

    function test_rollEpochIfNeeded_revertsOnZeroDuration() public {
        CoreStorage.Layout storage core = CoreStorage.layout();
        core.epochStart = uint64(block.timestamp);
        core.epochDuration = 0;

        // Library calls are inlined, so vm.expectRevert doesn't work directly.
        // Instead, use try/catch via an external call to this contract.
        try this.externalRollEpoch() {
            fail("should have reverted");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ExitEngineLib.EpochDurationNotSet.selector);
        }
    }

    /// @dev External wrapper to test library revert via try/catch
    function externalRollEpoch() external {
        ExitEngineLib.rollEpochIfNeeded(CoreStorage.layout());
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // computeFeeShares
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_computeFeeShares_standard_witOnly() public view {
        FeeStorage.InternalFeeParams memory fee = FeeStorage.InternalFeeParams({
            depBps: 0,
            witBps: 100, // 1%
            immediateExitPenaltyBps: 50, // 0.5%
            forceExitPenaltyBps: 200, // 2%
            treasury: address(0)
        });

        (uint256 feeShares, uint256 userShares) =
            ExitEngineLib.computeFeeShares(10000, ExitEngineLib.ExitMode.STANDARD, fee);

        // STANDARD: witBps only = 1% = 100 bps
        // mulBpsUp(10000, 100) = ceil(10000 * 100 / 10000) = 100
        assertEq(feeShares, 100, "STANDARD fee should be 1%");
        assertEq(userShares, 9900, "user should get 99%");
        assertEq(feeShares + userShares, 10000, "shares must sum");
    }

    function test_computeFeeShares_instant_witPlusPenalty() public view {
        FeeStorage.InternalFeeParams memory fee = FeeStorage.InternalFeeParams({
            depBps: 0,
            witBps: 100,
            immediateExitPenaltyBps: 50,
            forceExitPenaltyBps: 200,
            treasury: address(0)
        });

        (uint256 feeShares, uint256 userShares) =
            ExitEngineLib.computeFeeShares(10000, ExitEngineLib.ExitMode.INSTANT, fee);

        // INSTANT: witBps + immediateExitPenaltyBps = 150 bps
        // mulBpsUp(10000, 150) = ceil(10000 * 150 / 10000) = 150
        assertEq(feeShares, 150, "INSTANT fee should be 1.5%");
        assertEq(userShares, 9850, "user should get 98.5%");
    }

    function test_computeFeeShares_force_witPlusForce() public view {
        FeeStorage.InternalFeeParams memory fee = FeeStorage.InternalFeeParams({
            depBps: 0,
            witBps: 100,
            immediateExitPenaltyBps: 50,
            forceExitPenaltyBps: 200,
            treasury: address(0)
        });

        (uint256 feeShares, uint256 userShares) =
            ExitEngineLib.computeFeeShares(10000, ExitEngineLib.ExitMode.FORCE, fee);

        // FORCE: witBps + forceExitPenaltyBps = 300 bps
        // mulBpsUp(10000, 300) = ceil(10000 * 300 / 10000) = 300
        assertEq(feeShares, 300, "FORCE fee should be 3%");
        assertEq(userShares, 9700, "user should get 97%");
    }

    function test_computeFeeShares_roundsUp() public view {
        FeeStorage.InternalFeeParams memory fee = FeeStorage.InternalFeeParams({
            depBps: 0,
            witBps: 100,
            immediateExitPenaltyBps: 0,
            forceExitPenaltyBps: 0,
            treasury: address(0)
        });

        // 999 shares * 100 bps = 99900 / 10000 = 9.99 → rounds UP to 10
        (uint256 feeShares, uint256 userShares) =
            ExitEngineLib.computeFeeShares(999, ExitEngineLib.ExitMode.STANDARD, fee);

        assertEq(feeShares, 10, "fee should round UP");
        assertEq(userShares, 989, "user gets remainder");
    }

    function test_computeFeeShares_zeroFee() public view {
        FeeStorage.InternalFeeParams memory fee = FeeStorage.InternalFeeParams({
            depBps: 0,
            witBps: 0,
            immediateExitPenaltyBps: 0,
            forceExitPenaltyBps: 0,
            treasury: address(0)
        });

        (uint256 feeShares, uint256 userShares) =
            ExitEngineLib.computeFeeShares(10000, ExitEngineLib.ExitMode.STANDARD, fee);

        assertEq(feeShares, 0, "zero fee");
        assertEq(userShares, 10000, "all to user");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // simulateExit
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_simulateExit_standard_alwaysQueues() public view {
        FeeStorage.InternalFeeParams memory fee = FeeStorage.InternalFeeParams({
            depBps: 0,
            witBps: 100,
            immediateExitPenaltyBps: 50,
            forceExitPenaltyBps: 200,
            treasury: address(0)
        });

        ExitEngineLib.ExitResult memory r = ExitEngineLib.simulateExit(
            1000e6, // shares
            ExitEngineLib.ExitMode.STANDARD,
            1000e6, // grossAssets (1:1 for simplicity)
            100_000e6, // totalAssets
            100_000e6, // totalSupply (1:1 PPS)
            50_000e6, // capRemaining
            fee
        );

        assertTrue(r.willQueue, "STANDARD always queues");
        assertEq(r.epochCapRemaining, 50_000e6, "cap untouched for STANDARD");
        assertGt(r.netAssets, 0, "net assets > 0");
        assertGt(r.feeShares, 0, "fee shares > 0");
        assertEq(r.feeShares + r.userShares, 1000e6, "shares must sum");
    }

    function test_simulateExit_instant_underCap() public view {
        FeeStorage.InternalFeeParams memory fee = FeeStorage.InternalFeeParams({
            depBps: 0,
            witBps: 100,
            immediateExitPenaltyBps: 50,
            forceExitPenaltyBps: 0,
            treasury: address(0)
        });

        ExitEngineLib.ExitResult memory r = ExitEngineLib.simulateExit(
            1000e6,
            ExitEngineLib.ExitMode.INSTANT,
            1000e6,
            100_000e6,
            100_000e6,
            50_000e6, // cap >> gross
            fee
        );

        assertFalse(r.willQueue, "INSTANT under cap should not queue");
        assertEq(r.epochCapRemaining, 50_000e6 - 1000e6, "cap decremented");
    }

    function test_simulateExit_instant_overCap() public view {
        FeeStorage.InternalFeeParams memory fee = FeeStorage.InternalFeeParams({
            depBps: 0,
            witBps: 100,
            immediateExitPenaltyBps: 50,
            forceExitPenaltyBps: 0,
            treasury: address(0)
        });

        ExitEngineLib.ExitResult memory r = ExitEngineLib.simulateExit(
            10_000e6,
            ExitEngineLib.ExitMode.INSTANT,
            10_000e6,
            100_000e6,
            100_000e6,
            5_000e6, // cap < gross
            fee
        );

        assertTrue(r.willQueue, "INSTANT over cap should queue");
        assertEq(r.epochCapRemaining, 5_000e6, "cap untouched when queued");
    }

    function test_simulateExit_force_noCap() public view {
        FeeStorage.InternalFeeParams memory fee = FeeStorage.InternalFeeParams({
            depBps: 0,
            witBps: 100,
            immediateExitPenaltyBps: 0,
            forceExitPenaltyBps: 200,
            treasury: address(0)
        });

        ExitEngineLib.ExitResult memory r = ExitEngineLib.simulateExit(
            1000e6,
            ExitEngineLib.ExitMode.FORCE,
            1000e6,
            100_000e6,
            100_000e6,
            0, // cap = 0
            fee
        );

        assertFalse(r.willQueue, "FORCE never queues");
        assertEq(r.epochCapRemaining, 0, "cap untouched for FORCE");
        // FORCE fee: witBps(100) + forceExitPenaltyBps(200) = 300 bps
        assertEq(r.feeShares, Percentage.mulBpsUp(1000e6, 300), "FORCE fee = 3%");
    }

    function test_simulateExit_zeroTotalSupply() public view {
        FeeStorage.InternalFeeParams memory fee = FeeStorage.InternalFeeParams({
            depBps: 0,
            witBps: 100,
            immediateExitPenaltyBps: 0,
            forceExitPenaltyBps: 0,
            treasury: address(0)
        });

        ExitEngineLib.ExitResult memory r = ExitEngineLib.simulateExit(
            1000e6,
            ExitEngineLib.ExitMode.STANDARD,
            0,
            0,
            0, // totalSupply == 0
            0,
            fee
        );

        assertEq(r.netAssets, 0, "netAssets should be 0 when totalSupply is 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // consumeEpochCap
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_consumeEpochCap_incrementsWithdrawn() public {
        CoreStorage.Layout storage core = CoreStorage.layout();
        core.epochWithdrawn = 1000e6;

        ExitEngineLib.consumeEpochCap(core, 500e6);

        assertEq(core.epochWithdrawn, 1500e6, "epochWithdrawn should increment");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // validateEpochDuration
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_validateEpochDuration_valid() public view {
        assertTrue(ExitEngineLib.validateEpochDuration(1 days), "1 day valid");
        assertTrue(ExitEngineLib.validateEpochDuration(7 days), "7 days valid");
        assertTrue(ExitEngineLib.validateEpochDuration(30 days), "30 days valid");
    }

    function test_validateEpochDuration_invalid() public view {
        assertFalse(ExitEngineLib.validateEpochDuration(0), "0 invalid");
        assertFalse(ExitEngineLib.validateEpochDuration(12 hours), "12h invalid");
        assertFalse(ExitEngineLib.validateEpochDuration(31 days), "31 days invalid");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // simulateExit == runtime invariant (feeShares + userShares == shares)
    // ═══════════════════════════════════════════════════════════════════════════════

    function testFuzz_feeSharesAndUserSharesSumToShares(
        uint256 shares,
        uint8 modeRaw,
        uint16 witBps,
        uint16 immPenBps,
        uint16 forcePenBps
    ) public view {
        shares = bound(shares, 1, 1e18);
        witBps = uint16(bound(witBps, 0, 2000));
        immPenBps = uint16(bound(immPenBps, 0, 1000));
        forcePenBps = uint16(bound(forcePenBps, 0, 2000));

        ExitEngineLib.ExitMode mode = ExitEngineLib.ExitMode(modeRaw % 3);

        FeeStorage.InternalFeeParams memory fee = FeeStorage.InternalFeeParams({
            depBps: 0,
            witBps: witBps,
            immediateExitPenaltyBps: immPenBps,
            forceExitPenaltyBps: forcePenBps,
            treasury: address(0)
        });

        (uint256 feeShares, uint256 userShares) =
            ExitEngineLib.computeFeeShares(shares, mode, fee);

        assertEq(feeShares + userShares, shares, "shares invariant: fee + user == total");
        assertLe(feeShares, shares, "feeShares <= shares");
    }
}
