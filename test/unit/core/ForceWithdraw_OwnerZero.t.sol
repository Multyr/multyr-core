// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ForceWithdrawBaseTest, IForceWithdraw } from "./ForceWithdrawBase.t.sol";
import { IStrategyRouter } from "src/interfaces/IStrategyRouter.sol";
import { ERC4626Module } from "src/core/modules/ERC4626Module.sol";

/**
 * @title ForceWithdraw_OwnerZero_Test
 * @notice FIX #1: Verifies owner_ zero address check
 */
contract ForceWithdraw_OwnerZero_Test is ForceWithdrawBaseTest {
    function test_forceWithdraw_ownerZero_reverts() public {
        uint256 assets = 100e6;
        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        vm.prank(user);
        vm.expectRevert(ERC4626Module.ZeroAddress.selector);
        IForceWithdraw(address(vault))
            .forceWithdraw(assets, receiver, address(0), plan, type(uint256).max);
    }

    function test_forceWithdraw_receiverZero_reverts() public {
        uint256 assets = 100e6;
        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        vm.prank(user);
        vm.expectRevert(ERC4626Module.ZeroAddress.selector);
        IForceWithdraw(address(vault))
            .forceWithdraw(assets, address(0), user, plan, type(uint256).max);
    }

    function test_forceWithdraw_assetsZero_reverts() public {
        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        vm.prank(user);
        vm.expectRevert(ERC4626Module.ZeroAmount.selector);
        IForceWithdraw(address(vault)).forceWithdraw(0, receiver, user, plan, type(uint256).max);
    }
}
