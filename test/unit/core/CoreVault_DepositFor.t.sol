// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseVaultTest } from "../../helpers/BaseVaultTest.t.sol";

/// @title CoreVault_DepositFor
/// @notice Unit tests for depositFor(assets, receiver, payer) function
/// @dev Tests payer-model deposits where assets come from one address and shares go to another
contract CoreVault_DepositFor is BaseVaultTest {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    /// @notice Test depositFor when payer and receiver are the same address
    function test_depositFor_samePayerAndReceiver() public {
        uint256 amt = 10_000e6;

        // Transfer USDC to user
        require(assetToken.transfer(user, amt), "transfer fail");

        vm.startPrank(user);
        // User approves vault to pull from themselves
        assetToken.approve(vaultAddr, amt);

        uint256 expectedShares = vault.previewDeposit(amt);
        uint256 userSharesBefore = IVaultLike(vaultAddr).balanceOf(user);

        // User calls depositFor with themselves as both payer and receiver
        uint256 shares = IVaultLike(vaultAddr).depositFor(amt, user, user);

        uint256 userSharesAfter = IVaultLike(vaultAddr).balanceOf(user);
        vm.stopPrank();

        uint256 minted = userSharesAfter - userSharesBefore;
        assertEq(minted, expectedShares, "shares mismatch preview");
        assertEq(shares, expectedShares, "return value mismatch");
    }

    /// @notice Test depositFor when payer (alice) is different from receiver (bob)
    function test_depositFor_differentPayerAndReceiver() public {
        uint256 amt = 10_000e6;

        // Transfer USDC to alice (the payer)
        require(assetToken.transfer(alice, amt), "transfer fail");

        // Alice approves vault
        vm.prank(alice);
        assetToken.approve(vaultAddr, amt);

        uint256 expectedShares = vault.previewDeposit(amt);
        uint256 bobSharesBefore = IVaultLike(vaultAddr).balanceOf(bob);
        uint256 aliceAssetsBefore = assetToken.balanceOf(alice);

        // Anyone can call depositFor (msg.sender doesn't matter for authorization)
        // Assets come from alice, shares go to bob
        uint256 shares = IVaultLike(vaultAddr).depositFor(amt, bob, alice);

        uint256 bobSharesAfter = IVaultLike(vaultAddr).balanceOf(bob);
        uint256 aliceAssetsAfter = assetToken.balanceOf(alice);

        // Bob received shares
        uint256 minted = bobSharesAfter - bobSharesBefore;
        assertEq(minted, expectedShares, "bob shares mismatch");
        assertEq(shares, expectedShares, "return value mismatch");

        // Alice's assets were pulled
        assertEq(aliceAssetsBefore - aliceAssetsAfter, amt, "alice assets not pulled");

        // Alice should have 0 shares (she's just the payer)
        assertEq(IVaultLike(vaultAddr).balanceOf(alice), 0, "alice should have no shares");
    }

    /// @notice Test depositFor reverts when payer has insufficient allowance
    function test_depositFor_revertsOnInsufficientAllowance() public {
        uint256 amt = 10_000e6;

        // Transfer USDC to alice but don't approve vault
        require(assetToken.transfer(alice, amt), "transfer fail");

        // Attempt depositFor without approval - should revert
        vm.expectRevert();
        IVaultLike(vaultAddr).depositFor(amt, bob, alice);
    }

    /// @notice Test depositFor reverts when payer has insufficient balance
    function test_depositFor_revertsOnInsufficientBalance() public {
        uint256 amt = 10_000e6;

        // Alice has no balance but approves
        vm.prank(alice);
        assetToken.approve(vaultAddr, amt);

        // Attempt depositFor without balance - should revert
        vm.expectRevert();
        IVaultLike(vaultAddr).depositFor(amt, bob, alice);
    }

    /// @notice Test depositFor reverts on zero amount
    function test_depositFor_revertsOnZeroAmount() public {
        vm.expectRevert();
        IVaultLike(vaultAddr).depositFor(0, user, user);
    }

    /// @notice Test depositFor reverts on zero receiver
    function test_depositFor_revertsOnZeroReceiver() public {
        require(assetToken.transfer(user, 1000e6), "transfer fail");
        vm.prank(user);
        assetToken.approve(vaultAddr, 1000e6);

        vm.expectRevert();
        IVaultLike(vaultAddr).depositFor(1000e6, address(0), user);
    }

    /// @notice Test depositFor reverts on zero payer
    function test_depositFor_revertsOnZeroPayer() public {
        vm.expectRevert();
        IVaultLike(vaultAddr).depositFor(1000e6, user, address(0));
    }
}

interface IVaultLike {
    function depositFor(uint256 assets, address receiver, address payer) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
}
