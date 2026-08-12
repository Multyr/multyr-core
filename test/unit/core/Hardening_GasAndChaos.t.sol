// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";

interface IQueueModule {
    function requestInstantWithdrawal(uint256 shares)
        external
        returns (bool settledImmediately, uint256 epochId, uint256 claimId);
    function requestEpochWithdrawal(uint256 shares)
        external
        returns (uint256 epochId, uint256 claimId);
    function cancelEpochWithdrawal(uint256 epochId, uint256 claimId) external;
    function closeCurrentEpoch() external;
    function fundEpoch(uint256 epochId) external;
    function claimEpochAssets(uint256 epochId, uint256 claimId) external returns (uint256 assets);
    function currentEpochId() external view returns (uint256);
    function canCloseCurrentEpoch() external view returns (bool);
    function currentEpochClaimCount() external view returns (uint256);
    function outstandingClaimCount() external view returns (uint256);
    function totalEscrowedShares() external view returns (uint256);
    function endEpochCrystallize() external;
}

interface IForceWithdrawAll {
    function forceWithdrawAll(address receiver, uint256 minAssetsOut) external returns (uint256);
}

/// @title Hardening: Gas Characterization + Chaos + Low TVL
contract Hardening_GasAndChaos is Test {
    CoreHarness public vault;
    ERC20Mock public usdc;
    MockParamsProvider public params;

    address public owner;
    address public feeCollector = address(0xFEE);

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
    }

    function _fundAndDeposit(address user, uint256 amount) internal {
        usdc._mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GAS CHARACTERIZATION: Queue 100 / 500 / 1000 / 5000
    // ═══════════════════════════════════════════════════════════════════════════

    function test_gasCharacterization_queue100() public {
        _runGasCharacterization(100);
    }

    function test_gasCharacterization_queue500() public {
        _runGasCharacterization(500);
    }

    function test_gasCharacterization_queue1000() public {
        _runGasCharacterization(1000);
    }

    function _runGasCharacterization(uint256 queueSize) internal {
        // Seed vault with enough TVL
        _fundAndDeposit(owner, 100_000_000e6);

        // Create N users and queue claims into the same epoch
        uint256 epochId;
        for (uint256 i = 0; i < queueSize; i++) {
            address user = address(uint160(0xC000 + i));
            _fundAndDeposit(user, 10_000e6);
            vm.prank(user);
            (epochId,) = IQueueModule(address(vault)).requestEpochWithdrawal(5_000e6);
        }

        uint256 ql = IQueueModule(address(vault)).outstandingClaimCount();
        console2.log("Queue size:", ql);

        // Measure fundEpoch() gas: unlike QueueModule's per-batch keeper scan
        // (cost scales with min(batchSize, queueDepth)), a single fundEpoch()
        // call pulls liquidity for the ENTIRE epoch regardless of how many
        // claims it contains — gas here should stay roughly flat as queueSize grows.
        vm.warp(block.timestamp + 7 days + 1);
        IQueueModule(address(vault)).closeCurrentEpoch();
        uint256 g = gasleft();
        IQueueModule(address(vault)).fundEpoch(epochId);
        uint256 gasUsed = g - gasleft();
        console2.log("fundEpoch() gas:", gasUsed);

        // Gas report — characterization, not hard assertion
        console2.log("Gas limit check: gasUsed=", gasUsed, "limit=5000000");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LOW TVL STRESS TEST (1K-10K USDC)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_lowTVL_stress() public {
        console2.log("=== LOW TVL STRESS ===");

        // Tiny TVL: 1000 USDC
        address user1 = address(0xE001);
        address user2 = address(0xE002);
        _fundAndDeposit(user1, 500e6);
        _fundAndDeposit(user2, 500e6);

        console2.log("TVL:", vault.totalAssets());
        assertEq(vault.totalAssets(), 1000e6, "TVL = 1000 USDC");

        // Instant claim — small amount
        uint256 usdcBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        IQueueModule(address(vault)).requestInstantWithdrawal(100e6);
        uint256 received = usdc.balanceOf(user1) - usdcBefore;
        assertGt(received, 0, "received USDC on tiny TVL");
        console2.log("Instant claim 100 shares, received:", received);

        // Queued claim + settle (close + fund the epoch, then user2 self-claims)
        vm.prank(user2);
        (uint256 epochId, uint256 claimId) =
            IQueueModule(address(vault)).requestEpochWithdrawal(100e6);

        uint256 usdcBefore2 = usdc.balanceOf(user2);
        vm.warp(block.timestamp + 7 days + 1);
        IQueueModule(address(vault)).closeCurrentEpoch();
        IQueueModule(address(vault)).fundEpoch(epochId);
        vm.prank(user2);
        IQueueModule(address(vault)).claimEpochAssets(epochId, claimId);
        uint256 received2 = usdc.balanceOf(user2) - usdcBefore2;
        assertGt(received2, 0, "settled on tiny TVL");
        console2.log("Queued settle 100 shares, received:", received2);

        // Fee rounding on tiny amounts
        uint256 feeShares = vault.balanceOf(feeCollector);
        console2.log("Fee shares accumulated:", feeShares);
        // Fee should exist even on small amounts (rounded UP)
        assertGt(feeShares, 0, "fee collected on tiny amounts");

        // Force exit on remaining
        vm.prank(user1);
        IForceWithdrawAll(address(vault)).forceWithdrawAll(user1, 0);
        assertEq(vault.balanceOf(user1), 0, "user1 fully exited");

        // Supply only decreased
        assertLt(vault.totalSupply(), 1000e6, "supply decreased");

        console2.log("=== LOW TVL STRESS PASSED ===");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CHAOS TEST: mixed operations under stress
    // ═══════════════════════════════════════════════════════════════════════════

    function test_chaos_mixedOpsUnderStress() public {
        console2.log("=== CHAOS TEST ===");

        // 20 users deposit
        address[20] memory users;
        for (uint256 i = 0; i < 20; i++) {
            users[i] = address(uint160(0xF000 + i));
            _fundAndDeposit(users[i], 1_000_000e6);
        }
        console2.log("TVL after deposits:", vault.totalAssets() / 1e6, "M");

        // Wave 1: mix of instant + queued claims (even i = instant, odd i = queued)
        uint256 epochId;
        bool hasQueuedClaims;
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(users[i]);
            if (i % 2 == 0) {
                IQueueModule(address(vault)).requestInstantWithdrawal(200_000e6);
            } else {
                (epochId,) = IQueueModule(address(vault)).requestEpochWithdrawal(200_000e6);
                hasQueuedClaims = true;
            }
        }

        // Settle batch: close + fund the epoch the queued (odd-i) claims landed in
        if (hasQueuedClaims) {
            vm.warp(block.timestamp + 7 days + 1);
            IQueueModule(address(vault)).closeCurrentEpoch();
            IQueueModule(address(vault)).fundEpoch(epochId);
        }

        // Wave 3: epoch rollover + fresh claims
        vm.warp(block.timestamp + 7 days + 1);
        for (uint256 i = 10; i < 15; i++) {
            vm.prank(users[i]);
            IQueueModule(address(vault)).requestInstantWithdrawal(100_000e6);
        }

        // Wave 4: force exits
        for (uint256 i = 15; i < 18; i++) {
            vm.prank(users[i]);
            IForceWithdrawAll(address(vault)).forceWithdrawAll(users[i], 0);
            assertEq(vault.balanceOf(users[i]), 0, "force exit complete");
        }

        // Final settle: close + fund whatever landed in the queue during Wave 3
        // (instant claims that fell back to the queue due to cap exhaustion)
        if (
            IQueueModule(address(vault)).canCloseCurrentEpoch()
                && IQueueModule(address(vault)).currentEpochClaimCount() > 0
        ) {
            uint256 curEpochId = IQueueModule(address(vault)).currentEpochId();
            IQueueModule(address(vault)).closeCurrentEpoch();
            IQueueModule(address(vault)).fundEpoch(curEpochId);
        }

        // Crystallize
        usdc._mint(address(vault), 100_000e6);
        vault.setPerfParamsUnsafe(10e16, 3600);
        vm.warp(block.timestamp + 1 days);
        IQueueModule(address(vault)).endEpochCrystallize();

        // INVARIANTS
        uint256 finalSupply = vault.totalSupply();
        uint256 finalAssets = vault.totalAssets();
        uint256 feeShares = vault.balanceOf(feeCollector);

        console2.log("Final TVL:", finalAssets / 1e6, "M");
        console2.log("Final supply:", finalSupply / 1e6, "M");
        console2.log("Fee shares:", feeShares);
        console2.log("Outstanding claims:", IQueueModule(address(vault)).outstandingClaimCount());

        assertGt(feeShares, 0, "fees collected");
        assertLt(finalSupply, 20_000_000e6, "supply < initial");

        console2.log("=== CHAOS TEST PASSED ===");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // QUEUE CANCEL + RE-QUEUE STRESS (no zombie, no leak)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_queueCancelRequeue_noLeak() public {
        address user = address(0xD100);
        _fundAndDeposit(user, 10_000_000e6);

        uint256 initialShares = vault.balanceOf(user);
        uint256 initialSupply = vault.totalSupply();

        // 50 cycles of queue → cancel → re-queue
        for (uint256 i = 0; i < 50; i++) {
            vm.prank(user);
            (uint256 epochId, uint256 claimId) =
                IQueueModule(address(vault)).requestEpochWithdrawal(100_000e6);

            vm.prank(user);
            IQueueModule(address(vault)).cancelEpochWithdrawal(epochId, claimId);
        }

        // No leak
        assertEq(vault.balanceOf(user), initialShares, "no share leak after 50 cancel cycles");
        assertEq(vault.totalSupply(), initialSupply, "no supply leak");
        assertEq(IQueueModule(address(vault)).totalEscrowedShares(), 0, "no pending leak");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CAP BOUNDARY PRECISION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_capBoundaryPrecision() public {
        // TVL = 10M, cap = 10% = 1M
        _fundAndDeposit(owner, 10_000_000e6);

        // Claim exactly at cap boundary
        address user = address(0xD200);
        _fundAndDeposit(user, 5_000_000e6);

        // This should settle (within cap)
        vm.prank(user);
        IQueueModule(address(vault)).requestInstantWithdrawal(999_000e6);

        // This should queue (over cap ~1.5M)
        uint256 pendingBefore = IQueueModule(address(vault)).totalEscrowedShares();
        vm.prank(user);
        IQueueModule(address(vault)).requestInstantWithdrawal(600_000e6);
        uint256 pendingAfter = IQueueModule(address(vault)).totalEscrowedShares();

        assertGt(pendingAfter, pendingBefore, "second claim queued at cap boundary");
    }
}
