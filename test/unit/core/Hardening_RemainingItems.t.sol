// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";
import { VaultUpkeep } from "../../../src/automation/VaultUpkeep.sol";

interface IQueueModule {
    function requestInstantWithdrawal(uint256 shares)
        external
        returns (bool settledImmediately, uint256 epochId, uint256 claimId);
    function requestEpochWithdrawal(uint256 shares)
        external
        returns (uint256 epochId, uint256 claimId);
    function closeCurrentEpoch() external;
    function fundEpoch(uint256 epochId) external;
    function claimEpochAssets(uint256 epochId, uint256 claimId) external returns (uint256 assets);
    function totalEscrowedShares() external view returns (uint256);
    function outstandingClaimCount() external view returns (uint256);
}

/// @title Hardening: C1 no-arbitrage invariant, M3 failure counter reset, queue compaction
contract Hardening_RemainingItems is Test {
    CoreHarness public vault;
    ERC20Mock public usdc;
    MockParamsProvider public params;

    address public owner;
    address public feeCollector = address(0xFEE);
    address public user1 = address(0xA001);
    address public user2 = address(0xA002);

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
        vault.setFeeParamsUnsafe(100, 25, feeCollector); // 1% deposit fee
        vault.setExitFeesUnsafe(25, 50, 150);
        vault.unpause();

        usdc._mint(user1, 1_000_000_000e6);
        usdc._mint(user2, 1_000_000_000e6);
        vm.prank(user1);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(vault), type(uint256).max);

        // Seed vault
        usdc._mint(owner, 10_000_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10_000_000e6, owner);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // C1: NO SYSTEMATIC ARBITRAGE — mint vs deposit
    // CTO invariant: no user can obtain systematic advantage choosing mint over deposit
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz: for any amount and fee, mint and deposit produce same cost
    function testFuzz_C1_noSystematicArbitrage(uint256 amount) public {
        amount = bound(amount, 10_000e6, 10_000_000e6);

        // Path A: deposit on fresh state
        uint256 snap = vm.snapshotState();

        uint256 usdcBefore_d = usdc.balanceOf(user1);
        vm.prank(user1);
        uint256 shares_d = vault.deposit(amount, user1);
        uint256 cost_d = usdcBefore_d - usdc.balanceOf(user1);

        vm.revertToState(snap);

        // Path B: mint same shares on same state (snapshot restored)
        uint256 usdcBefore_m = usdc.balanceOf(user2);
        vm.prank(user2);
        uint256 cost_m = vault.mint(shares_d, user2);

        // INVARIANT: no systematic advantage
        // Allow 2 units rounding (ceil in gross-up + ceil in previewMint)
        assertApproxEqAbs(cost_d, cost_m, 2, "C1: no arbitrage deposit vs mint");

        // Mint must NOT be cheaper
        assertGe(cost_m, cost_d - 2, "C1: mint not cheaper than deposit");
    }

    /// @notice previewMint reflects actual cost (no hidden discount)
    function testFuzz_C1_previewMintReflectsActualCost(uint256 shares) public {
        shares = bound(shares, 1_000e6, 5_000_000e6);

        uint256 preview = vault.previewMint(shares);

        uint256 usdcBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        vault.mint(shares, user1);
        uint256 actualCost = usdcBefore - usdc.balanceOf(user1);

        // Actual cost must match preview (allow 1 unit)
        assertApproxEqAbs(actualCost, preview, 1, "C1: previewMint == actual cost");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // QUEUE: epoch close/fund/claim cycle preserves invariants
    // (No compaction in the epoch model -- epochs are immutable once closed,
    // there is no live FIFO array to compact.)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Queue close + fund + claim cycle preserves invariants
    function test_queue_settleAndCompact() public {
        // 10 users queue claims into the same open epoch
        address[10] memory claimants;
        uint256[10] memory claimIds;
        uint256 epochId;
        for (uint256 i = 0; i < 10; i++) {
            address u = address(uint160(0xB000 + i));
            claimants[i] = u;
            usdc._mint(u, 1_000_000e6);
            vm.startPrank(u);
            usdc.approve(address(vault), type(uint256).max);
            vault.deposit(1_000_000e6, u);
            (epochId, claimIds[i]) = IQueueModule(address(vault)).requestEpochWithdrawal(500_000e6);
            vm.stopPrank();
        }

        assertEq(IQueueModule(address(vault)).outstandingClaimCount(), 10, "10 claims queued");

        // Close + fund the epoch (single liquidity pull covers all 10 claims)
        vm.warp(block.timestamp + 7 days + 1);
        IQueueModule(address(vault)).closeCurrentEpoch();
        IQueueModule(address(vault)).fundEpoch(epochId);

        // Settle 5 (each user pulls their own claim -- pull-based, not keeper-push)
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(claimants[i]);
            IQueueModule(address(vault)).claimEpochAssets(epochId, claimIds[i]);
        }

        uint256 ql = IQueueModule(address(vault)).outstandingClaimCount();
        console2.log("Outstanding claims after settling 5:", ql);
        assertEq(ql, 5, "5 claims remain outstanding");

        // Settle remaining
        for (uint256 i = 5; i < 10; i++) {
            vm.prank(claimants[i]);
            IQueueModule(address(vault)).claimEpochAssets(epochId, claimIds[i]);
        }

        assertEq(IQueueModule(address(vault)).totalEscrowedShares(), 0, "all claims settled");
    }

    /// @notice Fallback-to-queue claims are retrievable once the epoch is funded
    function test_queue_instantFallbackBecomesStandard() public {
        // User deposits and queues immediate claim that exceeds cap
        vm.prank(user1);
        vault.deposit(50_000_000e6, user1);

        // Exhaust cap with first instant claim
        vm.prank(user1);
        IQueueModule(address(vault)).requestInstantWithdrawal(4_000_000e6);

        // Second instant claim falls back to queue — becomes a standard epoch claim
        vm.prank(user1);
        (bool settledImmediately, uint256 epochId, uint256 claimId) =
            IQueueModule(address(vault)).requestInstantWithdrawal(3_000_000e6);

        assertFalse(settledImmediately, "claim queued due to cap");
        uint256 pending = IQueueModule(address(vault)).totalEscrowedShares();
        assertGt(pending, 0, "claim queued due to cap");

        // Settle: close + fund the epoch, then user1 self-claims (standard claims
        // have no cap check, only the epoch's liquidity/maturity gates)
        vm.warp(block.timestamp + 7 days + 1);
        IQueueModule(address(vault)).closeCurrentEpoch();
        IQueueModule(address(vault)).fundEpoch(epochId);
        vm.prank(user1);
        IQueueModule(address(vault)).claimEpochAssets(epochId, claimId);
        uint256 pendingAfter = IQueueModule(address(vault)).totalEscrowedShares();

        // Claim should be settled (standard claims have no cap, only lock period)
        assertEq(pendingAfter, 0, "standard claim settled after epoch funded");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // C1: deposit/mint divergence is ONLY from rounding, not economic
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The max divergence between deposit and mint cost is bounded by rounding
    function test_C1_divergenceBounded() public {
        uint256[5] memory amounts = [uint256(1e6), 1_000e6, 100_000e6, 1_000_000e6, 10_000_000e6];

        for (uint256 j = 0; j < 5; j++) {
            uint256 amount = amounts[j];
            uint256 snap = vm.snapshotState();

            // Deposit
            uint256 before_d = usdc.balanceOf(user1);
            vm.prank(user1);
            uint256 shares = vault.deposit(amount, user1);
            uint256 cost_d = before_d - usdc.balanceOf(user1);

            vm.revertToState(snap);

            // Mint same shares
            uint256 before_m = usdc.balanceOf(user2);
            vm.prank(user2);
            uint256 cost_m = vault.mint(shares, user2);

            uint256 diff = cost_d > cost_m ? cost_d - cost_m : cost_m - cost_d;

            console2.log("Amount:", amount, "Diff:", diff);

            // Max 2 units divergence at any amount
            assertLe(diff, 2, "C1: divergence bounded by 2 units");
        }
    }
}
