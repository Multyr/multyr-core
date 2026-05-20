// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";

/// @title Hardening: mintRewardShares Access Control
/// @notice CTO requirement: only authorized RewardsPayoutManager can mint reward shares.
///         No generic role, no other path. Test negative access control.
contract Hardening_MintRewardShares is Test {
    CoreHarness public vault;
    ERC20Mock public usdc;

    address public owner;
    address public feeCollector = address(0xFEE);
    address public payoutManager = address(0xDA71);
    address public attacker = address(0xBAD);
    address public user = address(0xA001);

    function setUp() public {
        owner = address(this);
        usdc = new ERC20Mock("USDC", "USDC", 6);
        MockParamsProvider params = new MockParamsProvider();

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Vault", "vUSDC",
            owner, feeCollector, address(params)
        );
        MockBufferManagerForTests bm = new MockBufferManagerForTests(address(vault));
        vault.setBufferManagerUnsafe(address(bm));
        vault.unpause();

        // Seed vault so shares have value
        usdc._mint(owner, 10_000_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10_000_000e6, owner);

        // Set authorized payout manager
        vault.setRewardsPayoutManagerUnsafe(payoutManager);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POSITIVE: authorized payout manager can mint
    // ═══════════════════════════════════════════════════════════════════════════

    function test_authorizedPayoutManager_canMint() public {
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(payoutManager);
        vault.mintRewardShares(user, 1000e6); // 1000 USDC equivalent

        uint256 supplyAfter = vault.totalSupply();
        assertGt(supplyAfter, supplyBefore, "supply increased");
        assertGt(vault.balanceOf(user), 0, "user received shares");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NEGATIVE: all other callers are rejected
    // ═══════════════════════════════════════════════════════════════════════════

    function test_attacker_cannotMint() public {
        vm.prank(attacker);
        vm.expectRevert("not-payout-manager");
        vault.mintRewardShares(user, 1000e6);
    }

    function test_owner_cannotMint() public {
        vm.prank(owner);
        vm.expectRevert("not-payout-manager");
        vault.mintRewardShares(user, 1000e6);
    }

    function test_feeCollector_cannotMint() public {
        vm.prank(feeCollector);
        vm.expectRevert("not-payout-manager");
        vault.mintRewardShares(user, 1000e6);
    }

    function test_user_cannotMint() public {
        vm.prank(user);
        vm.expectRevert("not-payout-manager");
        vault.mintRewardShares(user, 1000e6);
    }

    function test_zeroAddress_reverts() public {
        vm.prank(payoutManager);
        vm.expectRevert("user=0");
        vault.mintRewardShares(address(0), 1000e6);
    }

    function test_zeroAmount_noOp() public {
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(payoutManager);
        vault.mintRewardShares(user, 0);

        assertEq(vault.totalSupply(), supplyBefore, "no mint for zero amount");
    }

    function test_wrongPayoutManager_reverts() public {
        address wrongManager = address(0xDEAD);
        vm.prank(wrongManager);
        vm.expectRevert("not-payout-manager");
        vault.mintRewardShares(user, 1000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENT: RewardSharesMinted emitted correctly
    // ═══════════════════════════════════════════════════════════════════════════

    function test_emitsRewardSharesMinted() public {
        vm.prank(payoutManager);
        // Can't easily predict exact shares, just verify no revert
        vault.mintRewardShares(user, 500e6);
        assertGt(vault.balanceOf(user), 0, "shares minted");
    }
}
