// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ForceWithdrawBaseTest,
    MockLossCapRouter,
    MockAggregatedLossCapRouter,
    MockStrategy,
    IForceWithdraw
} from "../unit/core/ForceWithdrawBase.t.sol";
import { IStrategyRouter } from "src/interfaces/IStrategyRouter.sol";
import { IAdminModule } from "src/interfaces/IAdminModule.sol";
import { StrategyRouter } from "src/core/modules/StrategyRouter.sol";

/**
 * @title ForceWithdraw_PropagatesLossCap_Test
 * @notice Verifies CRITICAL errors (LossCapExceeded, AggregatedLossCapExceeded) bubble up
 */
contract ForceWithdraw_PropagatesLossCap_Test is ForceWithdrawBaseTest {
    function test_LossCapExceeded_bubblesUp() public {
        // Deploy router that reverts with LossCapExceeded
        MockLossCapRouter lossCapRouter = new MockLossCapRouter(address(usdc));

        // Set router
        vm.prank(owner);
        IAdminModule(address(vault)).setRouter(address(lossCapRouter));

        // Move liquidity from vault to strategy (simulates deployment)
        // Keep totalAssets constant so share math works correctly
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        deal(address(usdc), address(vault), 0);
        lossCapRouter.strategyContract().setTotalAssets(vaultBalance);

        // Cache strategy address before prank (prank is consumed by next external call)
        address strategyAddr = lossCapRouter.strategy();

        // Create plan (strategy is enabled in mock)
        IStrategyRouter.Pull[] memory plan = new IStrategyRouter.Pull[](1);
        plan[0] = IStrategyRouter.Pull({ strat: strategyAddr, amount: 100e6 });

        // Should revert with LossCapExceeded (bubbles up)
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockLossCapRouter.LossCapExceeded.selector, strategyAddr, 1000, 900, 1000
            )
        );
        IForceWithdraw(address(vault)).forceWithdraw(100e6, receiver, user, plan, type(uint256).max);
    }

    function test_AggregatedLossCapExceeded_bubblesUp() public {
        // Deploy router that reverts with AggregatedLossCapExceeded
        MockAggregatedLossCapRouter aggLossCapRouter =
            new MockAggregatedLossCapRouter(address(usdc));

        // Set router
        vm.prank(owner);
        IAdminModule(address(vault)).setRouter(address(aggLossCapRouter));

        // Move liquidity from vault to strategy (simulates deployment)
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        deal(address(usdc), address(vault), 0);
        aggLossCapRouter.strategyContract().setTotalAssets(vaultBalance);

        // Cache strategy address before prank
        address strategyAddr = aggLossCapRouter.strategy();

        // Create plan
        IStrategyRouter.Pull[] memory plan = new IStrategyRouter.Pull[](1);
        plan[0] = IStrategyRouter.Pull({ strat: strategyAddr, amount: 100e6 });

        // Should revert with AggregatedLossCapExceeded (bubbles up)
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockAggregatedLossCapRouter.AggregatedLossCapExceeded.selector, 1000, 900, 1000
            )
        );
        IForceWithdraw(address(vault)).forceWithdraw(100e6, receiver, user, plan, type(uint256).max);
    }

    function test_LossCapExceeded_selector_matchesStrategyRouter() public pure {
        // Verify our mock selector matches the real StrategyRouter error
        bytes4 mockSelector = MockLossCapRouter.LossCapExceeded.selector;
        bytes4 realSelector = StrategyRouter.LossCapExceeded.selector;

        assertEq(mockSelector, realSelector, "LossCapExceeded selectors should match");
    }

    function test_AggregatedLossCapExceeded_selector_matchesStrategyRouter() public pure {
        bytes4 mockSelector = MockAggregatedLossCapRouter.AggregatedLossCapExceeded.selector;
        bytes4 realSelector = StrategyRouter.AggregatedLossCapExceeded.selector;

        assertEq(mockSelector, realSelector, "AggregatedLossCapExceeded selectors should match");
    }
}
