// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseVaultTest } from "../../helpers/BaseVaultTest.t.sol";

/// @title CoreVault_DepositFor
/// @notice Unit tests for depositFor(assets, receiver) -- 2-arg router model.
///
/// msg.sender is always the payer. Routers pull user tokens to themselves
/// first (via Permit2 or ERC20 approve-to-router), then call
/// depositFor(amount, user) so the router is the token source.
/// This eliminates the unauthorized-payer attack from the 3-arg form.
contract CoreVault_DepositFor is BaseVaultTest {
    address internal alice = address(0xA11CE);
    address internal bob   = address(0xB0B);

    /// @notice Caller deposits for themselves (payer == receiver == msg.sender)
    function test_depositFor_callerDepositsForSelf() public {
        uint256 amt = 10_000e6;
        require(assetToken.transfer(user, amt), "transfer fail");

        vm.startPrank(user);
        assetToken.approve(vaultAddr, amt);

        uint256 expectedShares = vault.previewDeposit(amt);
        uint256 sharesBefore   = IVaultLike(vaultAddr).balanceOf(user);

        // user is both msg.sender (payer) and receiver
        uint256 shares = IVaultLike(vaultAddr).depositFor(amt, user);

        vm.stopPrank();

        assertEq(IVaultLike(vaultAddr).balanceOf(user) - sharesBefore, expectedShares, "shares mismatch");
        assertEq(shares, expectedShares, "return value mismatch");
    }

    /// @notice Router pattern: caller (router/payer) deposits for a different receiver
    ///
    /// Simulates the DepositRouter flow:
    ///   1. alice has USDC and approves the vault (simulates router holding tokens)
    ///   2. alice calls depositFor(amt, bob) -- alice is msg.sender (payer), bob gets shares
    function test_depositFor_routerDepositsForReceiver() public {
        uint256 amt = 10_000e6;
        require(assetToken.transfer(alice, amt), "transfer fail");

        vm.prank(alice);
        assetToken.approve(vaultAddr, amt);

        uint256 expectedShares  = vault.previewDeposit(amt);
        uint256 bobSharesBefore = IVaultLike(vaultAddr).balanceOf(bob);
        uint256 aliceBefore     = assetToken.balanceOf(alice);

        // alice = msg.sender = payer; bob = receiver
        vm.prank(alice);
        uint256 shares = IVaultLike(vaultAddr).depositFor(amt, bob);

        // bob received shares, alice paid tokens
        assertEq(IVaultLike(vaultAddr).balanceOf(bob) - bobSharesBefore, expectedShares, "bob shares mismatch");
        assertEq(shares, expectedShares, "return value mismatch");
        assertEq(aliceBefore - assetToken.balanceOf(alice), amt, "alice tokens not pulled");
        assertEq(IVaultLike(vaultAddr).balanceOf(alice), 0, "alice should have no shares");
    }

    /// @notice Caller without vault approval reverts
    function test_depositFor_revertsOnInsufficientAllowance() public {
        uint256 amt = 10_000e6;
        require(assetToken.transfer(alice, amt), "transfer fail");
        // alice has tokens but no vault approval

        vm.prank(alice);
        vm.expectRevert();
        IVaultLike(vaultAddr).depositFor(amt, bob);
    }

    /// @notice Caller without balance reverts
    function test_depositFor_revertsOnInsufficientBalance() public {
        uint256 amt = 10_000e6;
        // alice has no balance but approves
        vm.prank(alice);
        assetToken.approve(vaultAddr, amt);

        vm.prank(alice);
        vm.expectRevert();
        IVaultLike(vaultAddr).depositFor(amt, bob);
    }

    /// @notice Zero amount reverts
    function test_depositFor_revertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert();
        IVaultLike(vaultAddr).depositFor(0, user);
    }

    /// @notice Zero receiver reverts
    function test_depositFor_revertsOnZeroReceiver() public {
        require(assetToken.transfer(user, 1000e6), "transfer fail");
        vm.prank(user);
        assetToken.approve(vaultAddr, 1000e6);

        vm.prank(user);
        vm.expectRevert();
        IVaultLike(vaultAddr).depositFor(1000e6, address(0));
    }

    /// @notice Arbitrary caller cannot use a victim's approval to deposit on their behalf
    ///
    /// In the old 3-arg form: attacker called depositFor(amount, attacker, victim).
    /// In the new 2-arg form: msg.sender is always the payer, so the attacker
    /// would have to supply their OWN tokens -- and they have none.
    function test_depositFor_cannotStealVictimApproval() public {
        address victim   = makeAddr("victim");
        address attacker = makeAddr("attacker");
        uint256 amt = 1_000_000e6;

        // Victim has USDC and approves the vault (standard UX)
        assetToken.transfer(victim, amt);
        vm.prank(victim);
        assetToken.approve(vaultAddr, type(uint256).max);

        // Attacker has no USDC; calling depositFor with attacker as receiver now
        // pulls from msg.sender (attacker), not from victim
        vm.prank(attacker);
        vm.expectRevert(); // reverts: attacker has no USDC
        IVaultLike(vaultAddr).depositFor(amt, attacker);

        // Victim's USDC is untouched
        assertEq(assetToken.balanceOf(victim), amt, "FIX: victim USDC unchanged");
        assertEq(IVaultLike(vaultAddr).balanceOf(attacker), 0, "FIX: attacker received no shares");
    }
}

interface IVaultLike {
    function depositFor(uint256 assets, address receiver) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
}
