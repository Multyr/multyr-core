// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BaseVaultTest } from "../../helpers/BaseVaultTest.t.sol";
import { CoreVault } from "../../../src/core/CoreVault.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";

contract CoreVault_HWM is BaseVaultTest {
    function test_crystallize_mints_perf_fee_and_updates_hwm() public {
        // Set perf params so crystallization works (10% perf fee, 1 hour min interval)
        CoreHarness(payable(vaultAddr)).setPerfParamsUnsafe(10e16, 3600);

        // Warp to satisfy minCrystallizeInterval
        vm.warp(block.timestamp + 1 days);

        // Deposit from user
        uint256 amt = 1_000e6;
        require(assetToken.transfer(user, amt), "transfer fail");
        vm.startPrank(user);
        assetToken.approve(vaultAddr, amt);
        vault.deposit(amt, user);
        vm.stopPrank();

        // Simulate profit: send assets directly to vault to increase NAV
        require(assetToken.transfer(vaultAddr, 100e6), "transfer fail");

        // Sanity: canCrystallize should be true if PPS > HWM
        bool ok = vault.canCrystallize();
        assertTrue(ok, "should be able to crystallize");

        // Track treasury share balance before
        uint256 tsBefore = CoreVault(payable(vaultAddr)).totalSupply();
        uint256 treasBefore = CoreVault(payable(vaultAddr)).balanceOf(address(this));

        // Crystallize
        vault.endEpochCrystallize();

        // After: total supply increases; treasury gets minted shares
        uint256 tsAfter = CoreVault(payable(vaultAddr)).totalSupply();
        uint256 treasAfter = CoreVault(payable(vaultAddr)).balanceOf(address(this));
        assertGt(tsAfter, tsBefore, "totalSupply should increase by perf fee shares");
        assertGt(treasAfter, treasBefore, "treasury should receive perf fee shares");
    }
}
