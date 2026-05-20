// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ForceWithdrawBaseTest, IForceWithdraw } from "./ForceWithdrawBase.t.sol";
import { IStrategyRouter } from "src/interfaces/IStrategyRouter.sol";
import { ERC4626Module } from "src/core/modules/ERC4626Module.sol";
import { ExitEngineLib } from "src/core/libraries/ExitEngineLib.sol";

/**
 * @title ForceWithdraw_BypassesLockPeriod_Test
 * @notice FIX #5: Verifies forceWithdraw bypasses lock period (guaranteed exit)
 */
contract ForceWithdraw_BypassesLockPeriod_Test is ForceWithdrawBaseTest {
    function setUp() public override {
        super.setUp();

        // Set lock period to 7 days
        params.setLockPeriod(7 days);
    }

    function test_forceWithdraw_bypassesLockPeriod() public {
        // User just deposited (in setUp) - still within lock period
        // warp 1 second (still locked)
        vm.warp(block.timestamp + 1);

        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // forceWithdraw should succeed even within lock period
        vm.prank(user);
        uint256 sharesSpent = IForceWithdraw(address(vault))
            .forceWithdraw(100e6, receiver, user, plan, type(uint256).max);

        assertTrue(sharesSpent > 0, "Should spend shares");
        assertEq(usdc.balanceOf(receiver), 100e6, "Receiver should get assets");
    }

    function test_standardWithdraw_respectsLockPeriod() public {
        // User just deposited (in setUp) - still within lock period
        // warp 1 second (still locked)
        vm.warp(block.timestamp + 1);

        // Standard withdraw always reverts with AsyncWithdrawalRequired
        vm.prank(user);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(100e6, receiver, user);
    }

    function test_standardRedeem_respectsLockPeriod() public {
        // User just deposited (in setUp) - still within lock period
        vm.warp(block.timestamp + 1);

        uint256 shares = vault.balanceOf(user) / 2;

        // Standard redeem always reverts with AsyncWithdrawalRequired
        vm.prank(user);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.redeem(shares, receiver, user);
    }

    function test_standardWithdraw_revertsAfterLockPeriod() public {
        // Warp past lock period
        vm.warp(block.timestamp + 7 days + 1);

        // Standard withdraw always reverts with AsyncWithdrawalRequired
        vm.prank(user);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(100e6, receiver, user);
    }

    function test_forceWithdraw_stillWorksAfterLockPeriod() public {
        // Warp past lock period
        vm.warp(block.timestamp + 7 days + 1);

        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // forceWithdraw should also work after lock period
        vm.prank(user);
        uint256 sharesSpent = IForceWithdraw(address(vault))
            .forceWithdraw(100e6, receiver, user, plan, type(uint256).max);

        assertTrue(sharesSpent > 0, "Should spend shares");
    }
}
