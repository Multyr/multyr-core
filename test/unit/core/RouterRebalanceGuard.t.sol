// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { RouterRebalanceGuard } from "../../../src/core/modules/RouterRebalanceGuard.sol";
import { AllocationTypes } from "../../../src/interfaces/IAllocationTypes.sol";
import { OracleValuationLib } from "../../../src/core/libraries/OracleValuationLib.sol";
import { GlobalConfig } from "../../../src/core/config/GlobalConfig.sol";
import { MockPriceOracleMiddleware } from "../../helpers/MockPriceOracleMiddleware.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";

/// @notice First-ever dedicated coverage for RouterRebalanceGuard. Centerpiece: proves the
///         oracle-conversion fix by running the SAME real-dollar economics through two
///         guards — one for a 6dp USDC-like asset, one for an 18dp WETH-like asset — and
///         checking they reach identical gate decisions.
contract RouterRebalanceGuard_Test is Test {
    address internal owner;
    address internal keeper;
    address internal governor;
    address internal orchestrator;

    GlobalConfig internal params;
    MockPriceOracleMiddleware internal oracle;

    ERC20Mock internal usdc; // 6 decimals
    ERC20Mock internal weth; // 18 decimals

    RouterRebalanceGuard internal guardUsdc;
    RouterRebalanceGuard internal guardWeth;

    function setUp() public {
        owner = makeAddr("owner");
        keeper = makeAddr("keeper");
        governor = makeAddr("governor");
        orchestrator = makeAddr("orchestrator");

        usdc = new ERC20Mock("USDC", "USDC", 6);
        weth = new ERC20Mock("WETH", "WETH", 18);

        oracle = new MockPriceOracleMiddleware();

        vm.startPrank(governor);
        params = new GlobalConfig(governor, 50, 100, 2000, 86400, 10, 500, 3600, 3600);
        params.setAssetOracleConfig(address(usdc), address(oracle), 3600);
        params.setAssetOracleConfig(address(weth), address(oracle), 3600);
        vm.stopPrank();

        oracle.setPrice(address(usdc), 1e18); // $1.00
        oracle.setPrice(address(weth), 3500e18); // $3500.00

        vm.startPrank(owner);
        guardUsdc = new RouterRebalanceGuard(owner, keeper, address(usdc), address(params));
        guardWeth = new RouterRebalanceGuard(owner, keeper, address(weth), address(params));
        guardUsdc.setOrchestrator(orchestrator);
        guardWeth.setOrchestrator(orchestrator);
        // Zero out cost model + minNetBenefitBps so benefit/ratio gates don't interfere
        // with isolating MIN_MOVE (a zero-delta-APY plan has exactly 0 net benefit bps,
        // which would otherwise fail the default 10bps floor).
        guardUsdc.setCostModelFallbacks(0, 0, 0);
        guardWeth.setCostModelFallbacks(0, 0, 0);
        guardUsdc.setGateConfig(500, 200, 1000e18, 10, 15_000, 30, 0);
        guardWeth.setGateConfig(500, 200, 1000e18, 10, 15_000, 30, 0);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Construction
    // ═══════════════════════════════════════════════════════════════════

    function test_constructor_setsAssetDecimals() public {
        assertEq(guardUsdc.assetDecimals(), 6);
        assertEq(guardWeth.assetDecimals(), 18);
    }

    function test_constructor_revertsOnZeroAsset() public {
        vm.expectRevert(RouterRebalanceGuard.ZeroAddress.selector);
        new RouterRebalanceGuard(owner, keeper, address(0), address(params));
    }

    function test_constructor_revertsOnZeroParams() public {
        vm.expectRevert(RouterRebalanceGuard.ZeroAddress.selector);
        new RouterRebalanceGuard(owner, keeper, address(usdc), address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Access control
    // ═══════════════════════════════════════════════════════════════════

    function test_setGateConfig_onlyOwner() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(RouterRebalanceGuard.NotOwner.selector);
        guardUsdc.setGateConfig(500, 200, 1000e18, 10, 15_000, 30, 10);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Oracle fail-closed behavior
    // ═══════════════════════════════════════════════════════════════════

    function test_evaluatePlan_revertsWhenOracleUnset() public {
        // weth/usdc oracles ARE set globally in setUp via asset config, so use an asset
        // with no oracle config to exercise the fail-closed OracleNotConfigured path.
        ERC20Mock other = new ERC20Mock("OTHER", "OTHER", 8);
        vm.prank(owner);
        RouterRebalanceGuard g = new RouterRebalanceGuard(owner, keeper, address(other), address(params));

        AllocationTypes.RebalancePlan memory plan = _trivialPlan(1);
        AllocationTypes.QueueSafetyContext memory qs;
        vm.expectRevert(abi.encodeWithSelector(OracleValuationLib.OracleNotConfigured.selector, address(other)));
        g.evaluatePlan(plan, 1_000_000e8, 0, qs);
    }

    function test_evaluatePlan_revertsWhenOracleStale() public {
        oracle.setStale(address(usdc));
        AllocationTypes.RebalancePlan memory plan = _trivialPlan(1);
        AllocationTypes.QueueSafetyContext memory qs;
        vm.expectRevert();
        guardUsdc.evaluatePlan(plan, 1_000_000e6, 0, qs);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Basic gates
    // ═══════════════════════════════════════════════════════════════════

    function test_evaluatePlan_invalidPlan_emptyStrategies() public {
        AllocationTypes.RebalancePlan memory plan = _trivialPlan(1);
        plan.strategies = new address[](0);
        AllocationTypes.QueueSafetyContext memory qs;
        AllocationTypes.PlanEvaluation memory r = guardUsdc.evaluatePlan(plan, 1_000_000e6, 0, qs);
        assertEq(r.reasonCode, uint8(AllocationTypes.GuardReason.INVALID_PLAN));
    }

    function test_evaluatePlan_stressBlock_nonSafetyPlan() public {
        vm.prank(owner);
        guardUsdc.forceRegime(uint8(AllocationTypes.Regime.STRESS));
        AllocationTypes.RebalancePlan memory plan = _trivialPlan(1);
        plan.driftBps = 500;
        AllocationTypes.QueueSafetyContext memory qs;
        AllocationTypes.PlanEvaluation memory r = guardUsdc.evaluatePlan(plan, 1_000_000e6, 0, qs);
        assertEq(r.reasonCode, uint8(AllocationTypes.GuardReason.STRESS_BLOCK));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Centerpiece: MIN_MOVE gate parity across 6dp (USDC) and 18dp (WETH)
    // ═══════════════════════════════════════════════════════════════════

    /// @dev minMoveUsd default is $1000 (WAD). At $1/USDC that's 1000e6; at $3500/WETH
    ///      that's (1000e18 * 1e18)/3500e18 WETH. A plan moving just under that dollar
    ///      amount must be blocked on BOTH guards; a plan at/above it must clear this gate
    ///      on BOTH guards. This is the proof that the oracle conversion works — not just
    ///      that it doesn't revert.
    function test_minMove_blocksBelowThreshold_bothDecimals() public {
        uint256 thresholdUsdc = OracleValuationLib.usdToAssetUnits(1000e18, 1e18, 6);
        uint256 thresholdWeth = OracleValuationLib.usdToAssetUnits(1000e18, 3500e18, 18);
        assertEq(thresholdUsdc, 1000e6);

        AllocationTypes.QueueSafetyContext memory qs;
        qs.availableIdleAfterPlanBps = 10_000; // clear the default 500bps queue-safety floor

        AllocationTypes.RebalancePlan memory planUsdc = _trivialPlan(1);
        planUsdc.driftBps = 500; // == effEntry, clears hysteresis
        planUsdc.totalMoveUsd = thresholdUsdc - 1;
        planUsdc.withdrawAmounts[0] = thresholdUsdc - 1;
        AllocationTypes.PlanEvaluation memory rUsdc =
            guardUsdc.evaluatePlan(planUsdc, 500_000e6, 0, qs);
        assertEq(rUsdc.reasonCode, uint8(AllocationTypes.GuardReason.MIN_MOVE), "usdc below threshold blocked");

        AllocationTypes.RebalancePlan memory planWeth = _trivialPlan(1);
        planWeth.driftBps = 500;
        planWeth.totalMoveUsd = thresholdWeth - 1;
        planWeth.withdrawAmounts[0] = thresholdWeth - 1;
        // tvl kept small (100 WETH) so the bps-based floor (0.1% of tvl) stays well below
        // the $1000 floor — otherwise the bps floor would dominate and this test would no
        // longer isolate the dollar-conversion path being proven here.
        AllocationTypes.PlanEvaluation memory rWeth =
            guardWeth.evaluatePlan(planWeth, 100e18, 0, qs);
        assertEq(rWeth.reasonCode, uint8(AllocationTypes.GuardReason.MIN_MOVE), "weth below threshold blocked");
    }

    function test_minMove_proceedsAtOrAboveThreshold_bothDecimals() public {
        uint256 thresholdUsdc = OracleValuationLib.usdToAssetUnits(1000e18, 1e18, 6);
        uint256 thresholdWeth = OracleValuationLib.usdToAssetUnits(1000e18, 3500e18, 18);

        AllocationTypes.QueueSafetyContext memory qs;
        qs.availableIdleAfterPlanBps = 10_000;

        AllocationTypes.RebalancePlan memory planUsdc = _trivialPlan(1);
        planUsdc.driftBps = 500;
        planUsdc.totalMoveUsd = thresholdUsdc;
        planUsdc.withdrawAmounts[0] = thresholdUsdc;
        AllocationTypes.PlanEvaluation memory rUsdc =
            guardUsdc.evaluatePlan(planUsdc, 500_000e6, 0, qs);
        assertTrue(rUsdc.proceed, "usdc at threshold proceeds");

        AllocationTypes.RebalancePlan memory planWeth = _trivialPlan(1);
        planWeth.driftBps = 500;
        planWeth.totalMoveUsd = thresholdWeth;
        planWeth.withdrawAmounts[0] = thresholdWeth;
        AllocationTypes.PlanEvaluation memory rWeth =
            guardWeth.evaluatePlan(planWeth, 100e18, 0, qs);
        assertTrue(rWeth.proceed, "weth at threshold proceeds");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _trivialPlan(uint256 n) internal pure returns (AllocationTypes.RebalancePlan memory plan) {
        plan.strategies = new address[](n);
        plan.withdrawAmounts = new uint256[](n);
        plan.depositAmounts = new uint256[](n);
        plan.strategyConfidences = new uint16[](n);
        plan.strategyScores = new uint16[](n);
        for (uint256 i = 0; i < n; i++) {
            plan.strategies[i] = address(uint160(0x1000 + i));
            plan.strategyConfidences[i] = 10_000;
            plan.strategyScores[i] = 10_000;
        }
        plan.aggregateConfidence = 10_000;
        plan.deltaAPYBps = 0;
    }
}
