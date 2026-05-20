// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ForceWithdrawBaseTest, IForceWithdraw } from "./ForceWithdrawBase.t.sol";
import { IStrategyRouter } from "src/interfaces/IStrategyRouter.sol";

/**
 * @title ForceWithdraw_Allowance_Test
 * @notice Verifies allowance spending for caller != owner
 */
contract ForceWithdraw_Allowance_Test is ForceWithdrawBaseTest {
    address public operator = address(0x5);

    function test_allowance_spentCorrectly() public {
        uint256 assets = 100e6;

        // Calculate expected sharesSpent
        uint256 baseShares = vault.previewWithdraw(assets);
        uint256 witFeeShares = (baseShares * DEFAULT_WIT_BPS) / 10000;
        uint256 forcePenaltyShares = (baseShares * DEFAULT_FORCE_EXIT_BPS) / 10000;
        uint256 sharesSpent = baseShares + witFeeShares + forcePenaltyShares;

        // User approves operator
        vm.prank(user);
        vault.approve(operator, sharesSpent);

        // Verify allowance before
        uint256 allowanceBefore = vault.allowance(user, operator);
        assertEq(allowanceBefore, sharesSpent, "Allowance should be set");

        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // Operator calls forceWithdraw on behalf of user
        vm.prank(operator);
        IForceWithdraw(address(vault))
            .forceWithdraw(assets, receiver, user, plan, type(uint256).max);

        // Verify allowance reduced to 0
        uint256 allowanceAfter = vault.allowance(user, operator);
        assertEq(allowanceAfter, 0, "Allowance should be consumed");
    }

    function test_allowance_insufficient_reverts() public {
        uint256 assets = 100e6;

        // Calculate expected sharesSpent
        uint256 baseShares = vault.previewWithdraw(assets);
        uint256 witFeeShares = (baseShares * DEFAULT_WIT_BPS) / 10000;
        uint256 forcePenaltyShares = (baseShares * DEFAULT_FORCE_EXIT_BPS) / 10000;
        uint256 sharesSpent = baseShares + witFeeShares + forcePenaltyShares;

        // User approves operator with LESS than required
        vm.prank(user);
        vault.approve(operator, sharesSpent - 1);

        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // Operator calls forceWithdraw - should revert
        vm.prank(operator);
        vm.expectRevert(); // ERC20InsufficientAllowance
        IForceWithdraw(address(vault))
            .forceWithdraw(assets, receiver, user, plan, type(uint256).max);
    }

    function test_allowance_unlimited_succeeds() public {
        uint256 assets = 100e6;

        // User approves unlimited
        vm.prank(user);
        vault.approve(operator, type(uint256).max);

        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // Operator calls forceWithdraw
        vm.prank(operator);
        IForceWithdraw(address(vault))
            .forceWithdraw(assets, receiver, user, plan, type(uint256).max);

        // Verify assets received
        assertEq(usdc.balanceOf(receiver), assets, "Receiver should get assets");

        // Unlimited allowance should remain unlimited
        assertEq(
            vault.allowance(user, operator), type(uint256).max, "Unlimited allowance should remain"
        );
    }

    function test_owner_noAllowanceNeeded() public {
        uint256 assets = 100e6;
        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // Owner (user) calls directly - no allowance needed
        vm.prank(user);
        IForceWithdraw(address(vault))
            .forceWithdraw(assets, receiver, user, plan, type(uint256).max);

        assertEq(usdc.balanceOf(receiver), assets, "Receiver should get assets");
    }
}
