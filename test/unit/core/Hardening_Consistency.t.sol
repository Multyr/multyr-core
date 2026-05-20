// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";
import { SelectorLib } from "../../../src/core/libraries/SelectorLib.sol";
import { QueueModule } from "../../../src/core/modules/QueueModule.sol";
import { AdminModule } from "../../../src/core/modules/AdminModule.sol";
import { ERC4626Module } from "../../../src/core/modules/ERC4626Module.sol";

interface IQueueModule {
    function requestClaim(bool immediate, uint256 shares) external;
    function settleFeesAndProcessQueue(uint256 maxClaims) external;
    function processQueuedRedemptions(uint256 maxClaims) external;
    function endEpochCrystallize() external;
    function queueLength() external view returns (uint256);
    function pendingShares() external view returns (uint256);
}

/// @title Hardening: canX/performX Consistency + Event Correctness + Wiring
contract Hardening_Consistency is Test {
    CoreHarness public vault;
    ERC20Mock public usdc;
    MockParamsProvider public params;

    address public owner;
    address public feeCollector = address(0xFEE);
    address public user1 = address(0xA001);

    function setUp() public {
        owner = address(this);
        usdc = new ERC20Mock("USDC", "USDC", 6);
        params = new MockParamsProvider();
        params.setLockPeriod(0);
        params.setCapPerEpochBps(1000);

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Vault", "vUSDC",
            owner, feeCollector, address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(vault));
        vault.setBufferManagerUnsafe(address(mockBM));
        vault.setFeeParamsUnsafe(0, 25, feeCollector);
        vault.setExitFeesUnsafe(25, 50, 150);
        vault.unpause();

        usdc._mint(user1, 100_000_000e6);
        vm.prank(user1);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(user1);
        vault.deposit(10_000_000e6, user1);
    }

    // ════════════════════════════════════════════════���══════════════════════════
    // canX vs performX CONSISTENCY
    // ════════════════════════════════════════���══════════════════════════════════

    function test_canSettle_vs_settle() public {
        // Create a claim to make canSettle true
        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(false, 100_000e6);

        bool canSettle = vault.canSettle();
        assertTrue(canSettle, "canSettle should be true with pending claims");

        // performX should succeed
        IQueueModule(address(vault)).settleFeesAndProcessQueue(10);
        // No revert = success
    }

    function test_canCrystallize_vs_crystallize() public {
        // Setup: add profit and set perf params
        usdc._mint(address(vault), 500_000e6);
        vault.setPerfParamsUnsafe(10e16, 3600);
        vm.warp(block.timestamp + 1 days);

        bool canCryst = vault.canCrystallize();
        // canCrystallize may be false if HWM not exceeded — that's OK
        // The invariant: if canCrystallize is true, endEpochCrystallize must not revert

        // Always callable (just may be a no-op)
        IQueueModule(address(vault)).endEpochCrystallize();
    }

    function test_settle_noRevert_whenQueueEmpty() public {
        // No claims in queue
        assertEq(IQueueModule(address(vault)).queueLength(), 0, "queue empty");

        // Should not revert even if nothing to settle
        IQueueModule(address(vault)).settleFeesAndProcessQueue(10);
    }

    function test_processQueuedRedemptions_noRevert_whenEmpty() public {
        IQueueModule(address(vault)).processQueuedRedemptions(10);
    }

    // ═════════════════════════════════════════════════════���═════════════════════
    // EVENT CORRECTNESS
    // ══════════════════════════════��════════════════════════════════════════════

    function test_instantClaim_emitsCorrectEvents() public {
        vm.recordLogs();

        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(true, 500_000e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Check for InstantExit event
        bytes32 instantExitSig = keccak256("InstantExit(address,uint256,uint256,uint256)");
        bool foundInstantExit = false;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == instantExitSig) {
                foundInstantExit = true;
                // Verify it's emitted exactly once
                uint256 count = 0;
                for (uint256 j; j < logs.length; j++) {
                    if (logs[j].topics.length > 0 && logs[j].topics[0] == instantExitSig) count++;
                }
                assertEq(count, 1, "InstantExit emitted exactly once");
                break;
            }
        }
        assertTrue(foundInstantExit, "InstantExit event emitted");

        // Check for FeePaid event
        bytes32 feePaidSig = keccak256("FeePaid(address,address,uint256)");
        bool foundFeePaid = false;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == feePaidSig) {
                foundFeePaid = true;
                break;
            }
        }
        assertTrue(foundFeePaid, "FeePaid event emitted");

        // Check for ClaimSettled event
        bytes32 claimSettledSig = keccak256("ClaimSettled(uint256,address,uint256)");
        bool foundSettled = false;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == claimSettledSig) {
                foundSettled = true;
                break;
            }
        }
        assertTrue(foundSettled, "ClaimSettled event emitted");
    }

    function test_queuedClaim_emitsClaimQueued() public {
        vm.recordLogs();

        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(false, 500_000e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 claimQueuedSig = keccak256("ClaimQueued(uint256)");
        bool found = false;
        uint256 count = 0;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == claimQueuedSig) {
                found = true;
                count++;
            }
        }
        assertTrue(found, "ClaimQueued emitted");
        assertEq(count, 1, "ClaimQueued exactly once");
    }

    function test_settlement_emitsFeePaidAndSettled() public {
        // Queue claim
        vm.prank(user1);
        IQueueModule(address(vault)).requestClaim(false, 200_000e6);

        vm.recordLogs();

        // Settle
        IQueueModule(address(vault)).settleFeesAndProcessQueue(10);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // FeePaid should be emitted during settlement
        bytes32 feePaidSig = keccak256("FeePaid(address,address,uint256)");
        bool foundFeePaid = false;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == feePaidSig) {
                foundFeePaid = true;
                break;
            }
        }
        assertTrue(foundFeePaid, "FeePaid emitted on settlement");

        // ClaimSettled
        bytes32 claimSettledSig = keccak256("ClaimSettled(uint256,address,uint256)");
        bool foundSettled = false;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == claimSettledSig) {
                foundSettled = true;
                break;
            }
        }
        assertTrue(foundSettled, "ClaimSettled emitted on settlement");
    }

    // ════════════════════════════��═════════════════════════════════════════���════
    // SELECTOR/MODULE WIRING
    // ═════════════════════════��═════════════════════════════════════════════════

    function test_criticalSelectors_wired() public view {
        // Queue selectors
        assertTrue(
            vault.moduleOf(QueueModule.requestClaim.selector) != address(0),
            "requestClaim wired"
        );
        assertTrue(
            vault.moduleOf(QueueModule.cancelClaim.selector) != address(0),
            "cancelClaim wired"
        );
        assertTrue(
            vault.moduleOf(QueueModule.settleFeesAndProcessQueue.selector) != address(0),
            "settleFeesAndProcessQueue wired"
        );
        assertTrue(
            vault.moduleOf(QueueModule.processQueuedRedemptions.selector) != address(0),
            "processQueuedRedemptions wired"
        );
        assertTrue(
            vault.moduleOf(QueueModule.endEpochCrystallize.selector) != address(0),
            "endEpochCrystallize wired"
        );

        // ERC4626 — deposit/mint must be wired (via fallback or module)
        // withdraw/redeem also wired (they revert, but still routed)
        bytes4 depositSel = bytes4(keccak256("deposit(uint256,address)"));
        bytes4 mintSel = bytes4(keccak256("mint(uint256,address)"));
        bytes4 withdrawSel = bytes4(keccak256("withdraw(uint256,address,address)"));
        bytes4 redeemSel = bytes4(keccak256("redeem(uint256,address,address)"));

        assertTrue(vault.moduleOf(depositSel) != address(0), "deposit wired");
        assertTrue(vault.moduleOf(mintSel) != address(0), "mint wired");
        assertTrue(vault.moduleOf(withdrawSel) != address(0), "withdraw wired");
        assertTrue(vault.moduleOf(redeemSel) != address(0), "redeem wired");
    }

    function test_noLegacySelectors() public view {
        // These selectors should NOT exist in the routing (legacy from old architecture)
        bytes4 oldRedeem = bytes4(keccak256("requestRedeem(uint256)"));
        bytes4 oldWithdraw = bytes4(keccak256("requestWithdraw(uint256)"));

        assertEq(vault.moduleOf(oldRedeem), address(0), "no legacy requestRedeem");
        assertEq(vault.moduleOf(oldWithdraw), address(0), "no legacy requestWithdraw");
    }

    function test_freezeRouting_preservesViewOps() public {
        // Freeze routing
        vault.freezeRouting();

        // View functions should still work
        vault.totalAssets();
        vault.totalSupply();
        vault.balanceOf(user1);
        vault.convertToAssets(1e6);
        vault.convertToShares(1e6);
        vault.maxWithdraw(user1);
        vault.maxRedeem(user1);
        vault.previewDeposit(1e6);
        vault.previewMint(1e6);

        // Module-routed views should still work
        IQueueModule(address(vault)).queueLength();
        IQueueModule(address(vault)).pendingShares();
    }
}
