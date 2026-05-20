// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ForceWithdrawBaseTest, IForceWithdraw } from "./ForceWithdrawBase.t.sol";
import { IStrategyRouter } from "src/interfaces/IStrategyRouter.sol";
import { ERC4626Module } from "src/core/modules/ERC4626Module.sol";

/**
 * @title ForceWithdraw_Slippage_Test
 * @notice Verifies slippage protection via maxShares parameter
 */
contract ForceWithdraw_Slippage_Test is ForceWithdrawBaseTest {
    function test_maxShares_tooLow_reverts() public {
        uint256 assets = 100e6;

        // Calculate expected sharesSpent
        uint256 baseShares = vault.previewWithdraw(assets);
        uint256 witFeeShares = (baseShares * DEFAULT_WIT_BPS) / 10000;
        uint256 forcePenaltyShares = (baseShares * DEFAULT_FORCE_EXIT_BPS) / 10000;
        uint256 sharesSpent = baseShares + witFeeShares + forcePenaltyShares;

        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // Set maxShares lower than required
        uint256 tooLowMaxShares = sharesSpent - 1;

        vm.prank(user);
        vm.expectRevert(ERC4626Module.SlippageExceeded.selector);
        IForceWithdraw(address(vault)).forceWithdraw(assets, receiver, user, plan, tooLowMaxShares);
    }

    function test_maxShares_exact_succeeds() public {
        uint256 assets = 100e6;

        // Calculate expected sharesSpent
        uint256 baseShares = vault.previewWithdraw(assets);
        uint256 witFeeShares = (baseShares * DEFAULT_WIT_BPS) / 10000;
        uint256 forcePenaltyShares = (baseShares * DEFAULT_FORCE_EXIT_BPS) / 10000;
        uint256 exactMaxShares = baseShares + witFeeShares + forcePenaltyShares;

        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // Should succeed with exact maxShares
        vm.prank(user);
        uint256 sharesSpent = IForceWithdraw(address(vault))
            .forceWithdraw(assets, receiver, user, plan, exactMaxShares);

        assertEq(sharesSpent, exactMaxShares, "Should spend exactly maxShares");
    }

    function test_maxShares_higher_succeeds() public {
        uint256 assets = 100e6;

        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // Should succeed with higher maxShares
        vm.prank(user);
        uint256 sharesSpent = IForceWithdraw(address(vault))
            .forceWithdraw(assets, receiver, user, plan, type(uint256).max);

        assertTrue(sharesSpent > 0, "Should spend some shares");
        assertTrue(sharesSpent < type(uint256).max, "Should spend less than max");
    }

    function test_maxShares_zero_reverts() public {
        uint256 assets = 100e6;
        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        vm.prank(user);
        vm.expectRevert(ERC4626Module.SlippageExceeded.selector);
        IForceWithdraw(address(vault)).forceWithdraw(assets, receiver, user, plan, 0);
    }
}
