// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BaseVaultTest } from "../../helpers/BaseVaultTest.t.sol";
import { Vm } from "forge-std/Vm.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { QueueModule } from "../../../src/core/modules/QueueModule.sol";
import { SelectorLib } from "../../../src/core/libraries/SelectorLib.sol";
import { ModuleSetter } from "../../helpers/ModuleSetter.sol";

interface IQueueModule {
    function requestClaim(bool immediate, uint256 shares) external;
}

contract CoreVault_Events is BaseVaultTest {
    function setUp() public override {
        super.setUp();

        // Wire QueueModule for requestClaim
        QueueModule qm = new QueueModule();
        bytes4[] memory queueSels = SelectorLib.getQueueModuleSelectors();
        ModuleSetter.setModulesSame(
            vaultAddr, queueSels, address(qm), SelectorLib.ROLE_PUBLIC
        );
    }

    function test_events_emitted_on_deposit_withdraw_and_crystallize() public {
        uint256 amt = 100_000e6;
        require(assetToken.transfer(user, amt), "transfer fail");

        // Set fees so events are emitted (1% deposit, 0.5% withdraw)
        CoreHarness(payable(vaultAddr)).setFeeParamsUnsafe(100, 50, address(this));
        // Set perf params so crystallization works (10% perf fee, 1 hour min interval)
        CoreHarness(payable(vaultAddr)).setPerfParamsUnsafe(10e16, 3600);

        // record and deposit
        vm.recordLogs();
        vm.startPrank(user);
        assetToken.approve(vaultAddr, amt);
        vault.deposit(amt, user);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 depSig = keccak256("DepositFeeTaken(address,uint256,uint256)");
        bool depFound = false;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == vaultAddr && logs[i].topics.length > 0
                    && logs[i].topics[0] == depSig
            ) {
                depFound = true;
                break;
            }
        }
        assertTrue(depFound, "DepositFeeTaken not emitted");

        // instant claim and check FeePaid event (queued protocol: use requestClaim(true))
        vm.recordLogs();
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 claimShares = userShares / 10; // claim 10%
        IQueueModule(vaultAddr).requestClaim(true, claimShares);
        vm.stopPrank();
        logs = vm.getRecordedLogs();
        bytes32 feePaidSig = keccak256("FeePaid(address,address,uint256)");
        bool feePaidFound = false;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == vaultAddr && logs[i].topics.length > 0
                    && logs[i].topics[0] == feePaidSig
            ) {
                feePaidFound = true;
                break;
            }
        }
        assertTrue(feePaidFound, "FeePaid not emitted on instant claim");

        // crystallize and check perf event
        vm.warp(block.timestamp + 1 days);
        // simulate profit
        require(assetToken.transfer(vaultAddr, 5_000e6), "transfer fail");
        vm.recordLogs();
        vault.endEpochCrystallize();
        logs = vm.getRecordedLogs();
        bytes32 perfSig = keccak256("PerfFeeMinted(uint256,uint256,uint256,uint256)");
        bool perfFound = false;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == vaultAddr && logs[i].topics.length > 0
                    && logs[i].topics[0] == perfSig
            ) {
                perfFound = true;
                break;
            }
        }
        assertTrue(perfFound, "PerfFeeMinted not emitted");
    }
}
