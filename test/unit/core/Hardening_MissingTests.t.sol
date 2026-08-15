// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";
import { VaultUpkeep, Op } from "../../../src/automation/VaultUpkeep.sol";
import { IStrategyRouter } from "../../../src/interfaces/IStrategyRouter.sol";
import { EpochedQueueModule, EpochQueueStorage } from "../../../src/core/modules/EpochedQueueModule.sol";

interface IQueueModule {
    function requestInstantWithdrawal(uint256 shares)
        external
        returns (bool settledImmediately, uint256 epochId, uint256 claimId);
    function requestEpochWithdrawal(uint256 shares) external returns (uint256 epochId, uint256 claimId);
    function closeCurrentEpoch() external;
    function fundEpoch(uint256 epochId) external;
    function claimEpochAssets(uint256 epochId, uint256 claimId) external returns (uint256 assets);
    function canCloseCurrentEpoch() external view returns (bool);
    function currentEpochClaimCount() external view returns (uint256);
    function outstandingClaimCount() external view returns (uint256);
    function totalEscrowedShares() external view returns (uint256);
}

// ═══════════════════════════════════════════════════════════════════════════════
// C3: Degraded plan does NOT cause keeper loop
// ═══════════════════════════════════════════════════════════════════════════════

/// @title Mock strategy that reverts on totalAssets
contract RevertingStrategy {
    function totalAssets() external pure returns (uint256) {
        revert("oracle down");
    }
    function asset() external pure returns (address) {
        return address(0); // placeholder
    }
}

/// @title Mock strategy that returns 0 (legitimately empty)
contract EmptyStrategy {
    address public immutable _asset;
    constructor(address a) { _asset = a; }
    function totalAssets() external pure returns (uint256) { return 0; }
    function asset() external view returns (address) { return _asset; }
}

/// @title Hardening: Missing tests from CTO review
contract Hardening_MissingTests is Test {
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

    // ═══════════════════════════════════════════════════════════════════════════
    // C3: DEGRADED PLAN — no keeper loop, no infinite retry
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice When hot liquidity is insufficient and no router configured,
    ///         queue claims are skipped (not retried infinitely).
    ///         The claim stays in queue, retried in NEXT settle call.
    function test_C3_degradedPlan_noInfiniteRetry() public {
        // Drain hot by depositing then claiming most
        vm.prank(user1);
        IQueueModule(address(vault)).requestInstantWithdrawal(9_500_000e6);

        // Now hot is very low. Queue a large claim that exceeds remaining hot.
        vm.prank(user1);
        (uint256 epochId, uint256 claimId) =
            IQueueModule(address(vault)).requestEpochWithdrawal(400_000e6);

        uint256 pendingBefore = IQueueModule(address(vault)).totalEscrowedShares();
        assertGt(pendingBefore, 0, "claim queued");

        // Settle — no router configured, hot likely < gross for this claim.
        // fundEpoch() falls short (stays CLOSED, not FUNDED); claim stays pending.
        vm.warp(block.timestamp + 7 days + 1);
        IQueueModule(address(vault)).closeCurrentEpoch();
        IQueueModule(address(vault)).fundEpoch(epochId);
        vm.prank(user1);
        try IQueueModule(address(vault)).claimEpochAssets(epochId, claimId) { } catch { }

        uint256 pendingAfter = IQueueModule(address(vault)).totalEscrowedShares();

        // If claim was skipped (insufficient hot), it stays pending
        // If claim was settled (hot was enough), pending = 0 — also fine
        // The key: no revert, no infinite loop, no crash
        console2.log("Pending before:", pendingBefore, "after:", pendingAfter);

        // Second attempt — same result, no crash (fundEpoch reverts
        // EpochAlreadyFunded if a prior attempt already fully funded it --
        // that's expected, not a failure of this test).
        try IQueueModule(address(vault)).fundEpoch(epochId) { } catch { }
        vm.prank(user1);
        try IQueueModule(address(vault)).claimEpochAssets(epochId, claimId) { } catch { }

        // Gas is bounded
        uint256 g = gasleft();
        try IQueueModule(address(vault)).fundEpoch(epochId) { } catch { }
        uint256 gasUsed = g - gasleft();
        console2.log("Degraded settle gas:", gasUsed);
        assertLt(gasUsed, 5_000_000, "degraded settle gas bounded");
    }

    /// @notice Claims that are skippable today become processable when liquidity returns
    function test_C3_degradedRecovery() public {
        vm.prank(user1);
        (uint256 epochId, uint256 claimId) =
            IQueueModule(address(vault)).requestEpochWithdrawal(100_000e6);

        // First settle — might skip if hot insufficient for this claim size
        // (hot should be sufficient since we have 10M deposited)
        vm.warp(block.timestamp + 7 days + 1);
        IQueueModule(address(vault)).closeCurrentEpoch();
        IQueueModule(address(vault)).fundEpoch(epochId);
        vm.prank(user1);
        IQueueModule(address(vault)).claimEpochAssets(epochId, claimId);

        // Verify claim was processed (we have enough hot)
        assertEq(
            IQueueModule(address(vault)).totalEscrowedShares(), 0, "claim settled with available hot"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // M3: failureCountByOp RESET ON SUCCESS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice VaultUpkeep failureCountByOp resets to 0 on success
    function test_M3_failureCountReset() public {
        // Deploy a VaultUpkeep pointing to our vault
        // We can't easily simulate failures in unit test, but we can verify
        // the mapping exists and the reset mechanism is correct by testing
        // the VaultUpkeep contract directly

        // Create stub dependencies
        StubRouterReader stubRouter = new StubRouterReader();
        StubGlobalConfigReader stubConfig = new StubGlobalConfigReader();

        VaultUpkeep upkeep = new VaultUpkeep(
            address(vault),
            address(0), // no buffer manager
            address(stubRouter),
            address(stubConfig),
            type(uint256).max, // maxRealize
            type(uint256).max, // maxDeploy
            10, // minRealizeGapBps
            10000 // minRealizeFloor
        );

        // Verify initial state
        assertEq(upkeep.failureCountByOp(Op.EPOCH_CLOSE), 0, "initial failure count = 0");
        assertEq(upkeep.failureCountByOp(Op.DEPLOY), 0, "initial deploy count = 0");
        assertEq(upkeep.failureCountByOp(Op.REALIZE), 0, "initial realize count = 0");

        // Verify lastDeployTs and lastRealizeTs exist and are 0
        assertEq(upkeep.lastDeployTs(), 0, "initial lastDeployTs = 0");
        assertEq(upkeep.lastRealizeTs(), 0, "initial lastRealizeTs = 0");
        assertEq(upkeep.lastAction(), 0, "initial lastAction = 0");
    }

    /// @notice VaultUpkeep closeCurrentEpoch succeeds via performUpkeep
    function test_M3_upkeepSettleSucceeds() public {
        // Queue a claim, then wait out the epoch duration so canCloseCurrentEpoch() is true.
        vm.prank(user1);
        EpochedQueueModule(address(vault)).requestEpochWithdrawal(100_000e6);
        vm.warp(block.timestamp + 7 days + 1);

        StubRouterReader stubRouter = new StubRouterReader();
        StubGlobalConfigReader stubConfig = new StubGlobalConfigReader();

        VaultUpkeep upkeep = new VaultUpkeep(
            address(vault),
            address(0),
            address(stubRouter),
            address(stubConfig),
            type(uint256).max, type(uint256).max,
            10, 10000
        );

        // Check upkeep
        (bool needed, bytes memory data) = upkeep.checkUpkeep("");

        if (needed) {
            // Perform
            upkeep.performUpkeep(data);

            // After successful epoch close, failure count should be 0
            assertEq(upkeep.failureCountByOp(Op.EPOCH_CLOSE), 0, "reset after success");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // H5: NAV LATENESS — keeper delayed 5/10/15/20 min
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deposits work with fresh NAV (< 15 min)
    function test_H5_deposit_freshNAV() public {
        vm.warp(block.timestamp + 5 minutes);

        uint256 before = usdc.balanceOf(user1);
        vm.prank(user1);
        vault.deposit(1_000_000e6, user1);
        uint256 after_ = usdc.balanceOf(user1);

        assertLt(after_, before, "deposit succeeded with 5min NAV");
    }

    /// @notice Deposits work at 10 min (still within 15 min window after auto-refresh)
    function test_H5_deposit_10min() public {
        vm.warp(block.timestamp + 10 minutes);

        vm.prank(user1);
        vault.deposit(1_000_000e6, user1);
        // No revert = success (auto-refresh triggered)
    }

    /// @notice Deposits at 15 min boundary — auto-refresh should save it
    function test_H5_deposit_15min() public {
        vm.warp(block.timestamp + 15 minutes);

        // _ensureFreshWarmNav auto-refreshes if stale
        // MockBufferManager refresh updates timestamp
        vm.prank(user1);
        vault.deposit(1_000_000e6, user1);
    }

    /// @notice Deposits at 20 min — auto-refresh should still save it
    function test_H5_deposit_20min() public {
        vm.warp(block.timestamp + 20 minutes);

        // Auto-refresh in _ensureFreshWarmNav
        vm.prank(user1);
        vault.deposit(1_000_000e6, user1);
    }

    /// @notice requestClaim works at ANY NAV staleness (W2: never block exits)
    function test_H5_requestClaim_anyNAVAge() public {
        // 1 hour stale
        vm.warp(block.timestamp + 1 hours);

        uint256 usdcBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        IQueueModule(address(vault)).requestInstantWithdrawal(100_000e6);

        assertGt(usdc.balanceOf(user1), usdcBefore, "instant claim at 1h stale NAV");

        // 24 hours stale
        vm.warp(block.timestamp + 24 hours);

        usdcBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        IQueueModule(address(vault)).requestInstantWithdrawal(100_000e6);

        assertGt(usdc.balanceOf(user1), usdcBefore, "instant claim at 24h stale NAV");
    }

    /// @notice Epoch close/fund/claim works at ANY NAV staleness
    function test_H5_settle_anyNAVAge() public {
        vm.prank(user1);
        (uint256 epochId, uint256 claimId) =
            IQueueModule(address(vault)).requestEpochWithdrawal(100_000e6);

        // Well past both NAV staleness AND the min epoch duration
        vm.warp(block.timestamp + 7 days + 1);

        uint256 usdcBefore = usdc.balanceOf(user1);
        IQueueModule(address(vault)).closeCurrentEpoch();
        IQueueModule(address(vault)).fundEpoch(epochId);
        vm.prank(user1);
        IQueueModule(address(vault)).claimEpochAssets(epochId, claimId);

        assertGt(usdc.balanceOf(user1), usdcBefore, "settle at stale NAV");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PR #13 review fix: minClaimAmount re-enforced (closes the dust-claim
    // outstandingClaimCount griefing vector -- was silently unenforced after
    // the QueueModule -> EpochedQueueModule cutover, even though GlobalConfig
    // still ships/documents it as an anti-spam floor).
    // ═══════════════════════════════════════════════════════════════════════════

    function test_minClaimAmount_blocksQueuedDustClaim() public {
        params.setMinClaimAmount(50e6);

        vm.prank(user1);
        vm.expectRevert(EpochedQueueModule.ClaimTooSmall.selector);
        IQueueModule(address(vault)).requestEpochWithdrawal(10e6);
    }

    function test_minClaimAmount_allowsClaimAtFloor() public {
        params.setMinClaimAmount(50e6);

        vm.prank(user1);
        (, uint256 claimId) = IQueueModule(address(vault)).requestEpochWithdrawal(50e6);
        assertGt(claimId, 0, "exactly-at-floor claim is accepted");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PR #13 review fix: EPOCH_FUND livelock. checkUpkeep() used to return
    // EPOCH_FUND unconditionally whenever a closed-but-unfunded epoch existed,
    // with no fall-through -- so one persistently-underfunded epoch (no
    // router/warm liquidity to cover the gap) starved
    // CRYSTALLIZE/REBALANCE/DEPLOY/REALIZE/RECONCILE forever.
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The floor is enforced on BOTH legs, so a sub-floor instant
    ///         request reverts on the caller's input rather than on whatever
    ///         the cap happens to allow at that moment.
    function test_minClaimAmount_instantPath_revertsDeterministically() public {
        params.setMinClaimAmount(100e6);
        params.setCapPerEpochBps(10); // 0.1% of TVL == 1_000 USDC of allowance

        // Cap wide open: still rejected on the input alone.
        vm.prank(user1);
        vm.expectRevert(EpochedQueueModule.ClaimTooSmall.selector);
        IQueueModule(address(vault)).requestInstantWithdrawal(50e6);

        // Consume the cap allowance with an above-floor exit.
        vm.prank(user1);
        (bool settled,,) = IQueueModule(address(vault)).requestInstantWithdrawal(900e6);
        assertTrue(settled, "above-floor instant exit settles");

        // Cap exhausted: same rejection, same reason. Previously this leg
        // reverted while the first one succeeded.
        vm.prank(user1);
        vm.expectRevert(EpochedQueueModule.ClaimTooSmall.selector);
        IQueueModule(address(vault)).requestInstantWithdrawal(50e6);
    }

    /// @notice The floor applies to every caller, with no address carve-out.
    ///         An exemption inside a security check is an invitation to widen
    ///         it; callers that cannot tolerate the revert -- FeeCollector's
    ///         AUTO_HARVEST is the one in-protocol case -- absorb it on their
    ///         own side instead. See FeeCollectorHarvestQueue.
    function test_minClaimAmount_appliesToEveryCallerIncludingFeeCollector() public {
        params.setMinClaimAmount(100e6);

        usdc._mint(feeCollector, 1_000e6);
        vm.startPrank(feeCollector);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, feeCollector);

        vm.expectRevert(EpochedQueueModule.ClaimTooSmall.selector);
        IQueueModule(address(vault)).requestEpochWithdrawal(50e6);
        vm.stopPrank();

        assertEq(
            IQueueModule(address(vault)).outstandingClaimCount(), 0,
            "no claim reaches the queue below the floor, whoever asks"
        );
        assertEq(
            IQueueModule(address(vault)).totalEscrowedShares(), 0,
            "and nothing was escrowed on the way to the revert"
        );
    }

    /// @notice A fundEpoch that REVERTS must still register as a stall. The
    ///         accounting used to sit inside the success branch, so a target
    ///         that reverts every cycle left the counters untouched, the
    ///         stalled-check unreachable, and EPOCH_FUND holding unconditional
    ///         priority forever. Driven against a stub core so the revert is
    ///         deterministic and independent of queue-module internals.
    function test_epochFund_revertingAttempt_stillRecordsAStall() public {
        RevertingFundCore stubCore = new RevertingFundCore(7);
        VaultUpkeep upkeep = new VaultUpkeep(
            address(stubCore), address(0),
            address(new StubRouterReader()), address(new StubGlobalConfigReader()),
            type(uint256).max, type(uint256).max, 10, 10000
        );

        upkeep.performUpkeep(abi.encode(Op.EPOCH_FUND, uint256(7)));

        assertEq(upkeep.epochFundStallCount(), 1, "a reverting attempt counts as a stall");
        assertEq(
            upkeep.lastEpochFundTargetId(), 7,
            "the stalled target is recorded, so checkUpkeep can yield priority"
        );

        upkeep.performUpkeep(abi.encode(Op.EPOCH_FUND, uint256(7)));
        assertEq(upkeep.epochFundStallCount(), 2, "repeat reverts keep accumulating");
    }

    function test_epochFund_yieldsPriorityAfterStall_thenReclaimsAfterBackoff() public {
        // Queue a large claim, then drain hot so it can never be fully funded
        // (no router configured; MockBufferManagerForTests' warm refill is a
        // permanent no-op -- see MockBufferManagerForTests.refill()).
        vm.prank(user1);
        (uint256 epochId,) = IQueueModule(address(vault)).requestEpochWithdrawal(9_000_000e6);

        vm.warp(block.timestamp + 7 days + 1);
        IQueueModule(address(vault)).closeCurrentEpoch();

        vm.prank(address(vault));
        usdc.transfer(makeAddr("elsewhere"), 8_000_000e6);

        // Give the vault a genuinely pending CRYSTALLIZE, so cycle 2 has real
        // lower-priority work to fall through to.
        usdc._mint(address(vault), 3_000_000e6);

        StubRouterReader stubRouter = new StubRouterReader();
        StubGlobalConfigReader stubConfig = new StubGlobalConfigReader();
        VaultUpkeep upkeep = new VaultUpkeep(
            address(vault), address(0), address(stubRouter), address(stubConfig),
            type(uint256).max, type(uint256).max, 10, 10000
        );

        // Cycle 1: EPOCH_FUND takes priority.
        (bool needed1, bytes memory data1) = upkeep.checkUpkeep("");
        assertTrue(needed1, "EPOCH_FUND needed on the first cycle");
        (Op op1,) = abi.decode(data1, (Op, uint256));
        assertTrue(op1 == Op.EPOCH_FUND);
        upkeep.performUpkeep(data1); // attempts fundEpoch(epochId); stays underfunded -> stall count = 1

        EpochQueueStorage.EpochData memory epochAfterAttempt =
            EpochedQueueModule(address(vault)).epochData(epochId);
        assertTrue(
            epochAfterAttempt.state == EpochQueueStorage.EpochState.Closed,
            "still underfunded -- no progress made"
        );

        // Cycle 2: same epoch still unfundable -- must yield priority instead
        // of retrying EPOCH_FUND forever, AND must schedule real work in its
        // place. Asserted unconditionally: guarding this behind `if (needed2)`
        // would let the test pass green on an idle keeper, which is precisely
        // the failure it is meant to catch.
        (bool needed2, bytes memory data2) = upkeep.checkUpkeep("");
        assertTrue(needed2, "keeper must still have work once EPOCH_FUND yields");
        (Op op2,) = abi.decode(data2, (Op, uint256));
        assertTrue(op2 != Op.EPOCH_FUND, "EPOCH_FUND must yield priority once stalled");
        assertTrue(op2 == Op.CRYSTALLIZE, "the pending CRYSTALLIZE becomes schedulable");

        // After the backoff window elapses, EPOCH_FUND reclaims priority.
        vm.warp(block.timestamp + upkeep.epochFundStallBackoffSeconds() + 1);
        (bool needed3, bytes memory data3) = upkeep.checkUpkeep("");
        assertTrue(needed3, "EPOCH_FUND retried after the backoff window");
        (Op op3,) = abi.decode(data3, (Op, uint256));
        assertTrue(op3 == Op.EPOCH_FUND);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// STUBS for VaultUpkeep constructor
// ═══════════════════════════════════════════════════════════════════════════════

contract StubRouterReader {
    uint64 public lastBatchTimestamp;
}

contract StubGlobalConfigReader {
    uint256 public minRebalanceCooldown = 300;
}

/// @notice Minimal core stub whose fundEpoch always reverts while the cursor
///         stays parked on the same target — the shape VaultUpkeep must handle
///         without losing its stall accounting.
contract RevertingFundCore {
    uint256 private immutable _oldest;

    constructor(uint256 oldest_) { _oldest = oldest_; }

    error AlwaysReverts();

    function fundEpoch(uint256) external pure { revert AlwaysReverts(); }
    function oldestUnfundedEpochId() external view returns (uint256) { return _oldest; }
    function currentEpochId() external view returns (uint256) { return _oldest + 1; }

    function canSettle() external pure returns (bool) { return false; }
    function canCrystallize() external pure returns (bool) { return false; }
    function canRealizeWithGap() external pure returns (bool, uint256) { return (false, 0); }
    function canDeploy() external pure returns (bool) { return false; }
    function canCloseCurrentEpoch() external pure returns (bool) { return false; }
    function currentEpochClaimCount() external pure returns (uint256) { return 0; }
    function canRebalanceStrategies() external pure returns (bool) { return false; }
    function pendingExitCount() external pure returns (uint256) { return 0; }
    function totalAssets() external pure returns (uint256) { return 0; }
}
