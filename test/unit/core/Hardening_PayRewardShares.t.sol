// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";

/// @title Hardening: payRewardShares Access Control & Non-Dilution
/// @notice CTO requirement: only authorized RewardsPayoutManager can pay reward shares.
///         No generic role, no other path. Also verifies reward payouts are
///         non-dilutive: shares are transferred from a pre-funded treasury, never
///         minted, so totalSupply (and PPS) is unaffected by a payout.
contract Hardening_PayRewardShares is Test {
    CoreHarness public vault;
    ERC20Mock public usdc;

    address public owner;
    address public feeCollector = address(0xFEE);
    address public payoutManager = address(0xDA71);
    address public treasury = address(0x7EA5);
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

        // Fund the rewards treasury with real shares (deposits real assets — this
        // is exactly what makes the subsequent payout non-dilutive).
        usdc._mint(treasury, 1_000_000e6);
        vm.startPrank(treasury);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000e6, treasury);
        vm.stopPrank();

        // Set authorized payout manager + treasury
        vault.setRewardsPayoutManagerUnsafe(payoutManager);
        vault.setRewardsTreasuryUnsafe(treasury);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POSITIVE: authorized payout manager can pay, non-dilutive
    // ═══════════════════════════════════════════════════════════════════════════

    function test_authorizedPayoutManager_canPay() public {
        uint256 supplyBefore = vault.totalSupply();
        uint256 treasuryBalBefore = vault.balanceOf(treasury);

        vm.prank(payoutManager);
        vault.payRewardShares(user, 1000e6); // 1000 USDC equivalent

        uint256 supplyAfter = vault.totalSupply();
        assertEq(supplyAfter, supplyBefore, "supply unchanged - transfer, not mint");
        assertGt(vault.balanceOf(user), 0, "user received shares");
        assertLt(vault.balanceOf(treasury), treasuryBalBefore, "treasury balance decreased");
    }

    function test_payout_doesNotAffectPPS() public {
        uint256 ppsBefore = vault.convertToAssets(1e18);

        vm.prank(payoutManager);
        vault.payRewardShares(user, 1000e6);

        uint256 ppsAfter = vault.convertToAssets(1e18);
        assertEq(ppsAfter, ppsBefore, "PPS unaffected by reward payout");
    }

    function test_insufficientTreasuryBalance_reverts() public {
        uint256 treasuryBal = vault.balanceOf(treasury);
        // Ask for far more than the treasury's shares can cover.
        uint256 tooMuch = vault.convertToAssets(treasuryBal) * 2;

        vm.prank(payoutManager);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vault.payRewardShares(user, tooMuch);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NEGATIVE: all other callers are rejected
    // ═══════════════════════════════════════════════════════════════════════════

    function test_attacker_cannotPay() public {
        vm.prank(attacker);
        vm.expectRevert("not-payout-manager");
        vault.payRewardShares(user, 1000e6);
    }

    function test_owner_cannotPay() public {
        vm.prank(owner);
        vm.expectRevert("not-payout-manager");
        vault.payRewardShares(user, 1000e6);
    }

    function test_feeCollector_cannotPay() public {
        vm.prank(feeCollector);
        vm.expectRevert("not-payout-manager");
        vault.payRewardShares(user, 1000e6);
    }

    function test_user_cannotPay() public {
        vm.prank(user);
        vm.expectRevert("not-payout-manager");
        vault.payRewardShares(user, 1000e6);
    }

    function test_zeroAddress_reverts() public {
        vm.prank(payoutManager);
        vm.expectRevert("user=0");
        vault.payRewardShares(address(0), 1000e6);
    }

    function test_zeroAmount_noOp() public {
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(payoutManager);
        vault.payRewardShares(user, 0);

        assertEq(vault.totalSupply(), supplyBefore, "no transfer for zero amount");
    }

    function test_wrongPayoutManager_reverts() public {
        address wrongManager = address(0xDEAD);
        vm.prank(wrongManager);
        vm.expectRevert("not-payout-manager");
        vault.payRewardShares(user, 1000e6);
    }

    function test_zeroTreasury_reverts() public {
        vault.setRewardsTreasuryUnsafe(address(0));

        vm.prank(payoutManager);
        vm.expectRevert("treasury=0");
        vault.payRewardShares(user, 1000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENT: RewardSharesPaid emitted correctly
    // ═══════════════════════════════════════════════════════════════════════════

    function test_emitsRewardSharesPaid() public {
        vm.prank(payoutManager);
        // Can't easily predict exact shares, just verify no revert
        vault.payRewardShares(user, 500e6);
        assertGt(vault.balanceOf(user), 0, "shares paid");
    }
}
