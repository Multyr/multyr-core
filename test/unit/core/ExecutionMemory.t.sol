// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ExecutionMemory } from "../../../src/core/modules/ExecutionMemory.sol";
import { IExecutionMemory } from "../../../src/interfaces/IExecutionMemory.sol";

/// @notice First-ever dedicated coverage for ExecutionMemory. Includes a regression check
///         that emaGasCost/fallbackGasCostUsd/maxAcceptableGasCost now hold WAD-scale (1e18)
///         USD amounts without truncation — the old uint32/uint64 types would have silently
///         wrapped values in this range.
contract ExecutionMemory_Test is Test {
    ExecutionMemory internal mem;
    address internal owner;
    address internal keeper;
    address internal strategy;

    function setUp() public {
        owner = makeAddr("owner");
        keeper = makeAddr("keeper");
        strategy = makeAddr("strategy");
        vm.prank(owner);
        mem = new ExecutionMemory(owner, keeper);
    }

    // ═══════════════════════════════════════════════════════════════════
    // WAD-scale widening regression
    // ═══════════════════════════════════════════════════════════════════

    function test_defaults_areWadScale_notTruncated() public view {
        // Old uint32 max is ~4.29e9 — WAD $50/$500 would have silently wrapped.
        assertEq(mem.fallbackGasCostUsd(), 50e18);
        assertEq(mem.maxAcceptableGasCost(), 500e18);
        assertGt(mem.fallbackGasCostUsd(), type(uint32).max);
        assertGt(mem.maxAcceptableGasCost(), type(uint32).max);
    }

    function test_recordExecution_storesWadScaleGasCost_withoutTruncation() public {
        // Old uint64 max (~1.8e19) is close to this WAD value's neighborhood; use a
        // deliberately large WAD cost near the old ceiling to prove no wraparound.
        uint256 largeCostWad = 300e18; // within maxAcceptableGasCost (500e18)
        vm.prank(keeper);
        mem.recordExecution(strategy, largeCostWad, 10, 0, true);

        (uint256 gasCostUsd,) = mem.getExpectedCost(strategy);
        // Below minObservationsForLiveCost (10) -> fallback, not the recorded value yet.
        assertEq(gasCostUsd, mem.fallbackGasCostUsd());

        (uint256 storedEma,,,,,,) = mem.records(strategy);
        assertEq(storedEma, largeCostWad, "first observation stored verbatim, no truncation");
    }

    function test_recordExecution_emaConverges_atWadScale() public {
        vm.startPrank(keeper);
        for (uint256 i = 0; i < 15; i++) {
            mem.recordExecution(strategy, 100e18, 10, 0, true);
        }
        vm.stopPrank();

        (uint256 gasCostUsd, uint16 slippageBps) = mem.getExpectedCost(strategy);
        // >= minObservationsForLiveCost (10) -> live EMA, converged to 100e18.
        assertApproxEqAbs(gasCostUsd, 100e18, 1e12);
        assertEq(slippageBps, 10);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Outlier filter (WAD-scale threshold)
    // ═══════════════════════════════════════════════════════════════════

    function test_recordExecution_rejectsOutlierAboveMaxAcceptable() public {
        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit IExecutionMemory.ExecutionOutlierRejected(strategy, 600e18, 10);
        mem.recordExecution(strategy, 600e18, 10, 0, true); // > maxAcceptableGasCost (500e18)

        (,,,,, uint64 lastUpdateTs,) = mem.records(strategy);
        assertEq(lastUpdateTs, 0, "outlier must not update the record");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Bootstrap fallback + governance setters
    // ═══════════════════════════════════════════════════════════════════

    function test_getExpectedCost_fallsBackBelowObservationThreshold() public {
        (uint256 gasCostUsd, uint16 slippageBps) = mem.getExpectedCost(strategy);
        assertEq(gasCostUsd, 50e18);
        assertEq(slippageBps, 5);
    }

    function test_setFallbackCost_acceptsWadScaleValue_onlyOwner() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(ExecutionMemory.NotOwner.selector);
        mem.setFallbackCost(75e18, 7, 70);

        vm.prank(owner);
        mem.setFallbackCost(75e18, 7, 70);
        assertEq(mem.fallbackGasCostUsd(), 75e18);
    }

    function test_setOutlierFilter_acceptsWadScaleValue_onlyOwner() public {
        vm.prank(owner);
        mem.setOutlierFilter(1000e18, 2_000);
        assertEq(mem.maxAcceptableGasCost(), 1000e18);
        assertEq(mem.maxAcceptableSlippageBps(), 2_000);
    }

    function test_recordExecution_onlyKeeperOrOwner() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(ExecutionMemory.NotKeeper.selector);
        mem.recordExecution(strategy, 1e18, 10, 0, true);
    }
}
