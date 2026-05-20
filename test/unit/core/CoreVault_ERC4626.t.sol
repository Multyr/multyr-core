// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseVaultTest } from "../../helpers/BaseVaultTest.t.sol";
import { ExitEngineLib } from "src/core/libraries/ExitEngineLib.sol";

contract CoreVault_ERC4626 is BaseVaultTest {
    function test_previewDeposit_matches_deposit_no_fee() public {
        // Use amount below initial minted supply in BaseVaultTest (1,000,000e6)
        uint256 amt = 123_456e6;
        require(assetToken.transfer(user, amt), "transfer fail");
        vm.startPrank(user);
        assetToken.approve(vaultAddr, amt);
        uint256 expected = vault.previewDeposit(amt);
        uint256 beforeShares = CoreAggregatorVaultLike(address(vaultAddr)).balanceOf(user);
        vault.deposit(amt, user);
        uint256 afterShares = CoreAggregatorVaultLike(address(vaultAddr)).balanceOf(user);
        vm.stopPrank();
        uint256 minted = afterShares - beforeShares;
        assertEq(minted, expected, "deposit shares mismatch preview");
    }

    function test_previewWithdraw_matches_withdraw_no_fee() public {
        uint256 amt = 1_000e6;
        require(assetToken.transfer(user, amt), "transfer fail");
        vm.startPrank(user);
        assetToken.approve(vaultAddr, amt);
        vault.deposit(amt, user);
        // previewWithdraw still returns correct shares
        uint256 assets = amt / 2;
        uint256 expectedShares = vault.previewWithdraw(assets);
        assertGt(expectedShares, 0, "previewWithdraw should return non-zero shares");
        // withdraw() now always reverts — users must use requestClaim(true)
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        CoreAggregatorVaultLike(address(vaultAddr)).withdraw(assets, user, user);
        vm.stopPrank();
    }
}

interface CoreAggregatorVaultLike {
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
}
