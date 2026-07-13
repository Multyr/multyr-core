// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// SPRINT SECURITY TEST -- EpochedQueueModule withdraw-flow fixes
//
// ORIGINAL BUGS (now fixed):
// ─────────────────────────
// Bug A (CRITICAL) -- msg.sender corruption in the instant->queue fallback:
//   requestInstantWithdrawal() fell back to `this.requestEpochWithdrawal(shares)`,
//   an EXTERNAL self-call. CoreVault's fallback() does `module.delegatecall(...)`,
//   so the re-entered call's msg.sender became address(this) (the vault itself),
//   not the real withdrawing user. The queued claim was silently attributed to
//   the vault, and the share transfer FROM msg.sender (now the vault) reverted
//   in practice, since the vault does not hold its own shares.
//
// Bug B (HIGH) -- escrowedShares accounting drift:
//   closeCurrentEpoch() transferred totalFeeShares out of vault escrow to the
//   feeCollector but never decremented `escrowedShares`. claimEpochAssets()
//   patched around this with a subtract-then-add-back dance that only partially
//   corrected it, and batchClaimEpochAssets() didn't touch escrowedShares at all
//   -- so the tracked total diverged from reality, and diverged differently
//   depending on which claim path a user used.
//
// Bug C (MEDIUM) -- batchClaimEpochAssets() never emitted IERC4626.Withdraw:
//   Indexers/dashboards relying on the standard ERC4626 event silently missed
//   every batch-claimed withdrawal.
//
// Bug D (MEDIUM) -- instant-withdrawal cap check ignored dynamic cap policy:
//   _canInstant() hand-rolled `cap = totalAssets * capPerEpochBps / 10000`
//   instead of routing through WithdrawalCapLib (the shared single source of
//   truth also used by ExitEngineLib.calculateCapRemaining), so a vault with
//   dynamic-cap tightening enabled under queue stress still let instant exits
//   through at the static/unlimited cap.
//
// FIXES APPLIED (see src/core/modules/EpochedQueueModule.sol):
// ─────────────────────────────────────────────────────────────────────
// Fix A: extracted _requestEpochWithdrawal(address user, uint256 shares) as an
//        internal function; both requestEpochWithdrawal() and the instant
//        fallback call it directly (no external self-call), preserving the
//        real caller's identity.
// Fix B: closeCurrentEpoch() now decrements escrowedShares by totalFeeShares
//        when fee shares leave escrow; both claim paths decrement it by
//        claim.netShares only, consistently.
// Fix C: batchClaimEpochAssets() now emits IERC4626.Withdraw per claim, same
//        as the single-claim path.
// Fix D: _canInstant() now calls _epochCapRemaining(), which mirrors
//        ExitEngineLib.calculateCapRemaining()'s bps-selection logic via
//        WithdrawalCapLib, including dynamic-cap scaling (using this module's
//        own open-epoch claimCount as the queue-depth signal).
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "lib/forge-std/src/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IParamsProvider } from "../../src/interfaces/IParamsProvider.sol";

import { CoreHarness } from "../helpers/CoreHarness.sol";
import { MockUSDC } from "../helpers/MockUSDC.sol";
import { ERC4626Module } from "../../src/core/modules/ERC4626Module.sol";
import { EpochedQueueModule } from "../../src/core/modules/EpochedQueueModule.sol";
import { EpochQueueStorage } from "../../src/core/modules/EpochedQueueModule.sol";

/// @dev Standalone IParamsProvider with the knobs these POCs need: lock period,
///      static withdrawal cap, dynamic cap, and queue-settlement epoch duration.
contract MockQueueEpochParamsProvider is IParamsProvider {
    uint16 private _capPerEpochBps = 10000; // 100% == effectively unlimited
    uint64 private _lockPeriod;
    uint16 private _dcpMinBps = 100;
    uint16 private _dcpMaxBps = 10000;
    uint256 private _dcpThreshold;
    bool private _dcpEnabled;
    uint64 private _epochDuration = 1 days;

    function setLockPeriod(uint64 v) external { _lockPeriod = v; }
    function setCapPerEpochBps(uint16 v) external { _capPerEpochBps = v; }
    function setDynamicCap(bool enabled, uint16 minBps, uint16 maxBps, uint256 threshold) external {
        _dcpEnabled = enabled;
        _dcpMinBps = minBps;
        _dcpMaxBps = maxBps;
        _dcpThreshold = threshold;
    }
    function setEpochDuration(uint64 v) external { _epochDuration = v; }

    function getFeeParams(address) external pure returns (FeeParams memory) {
        return FeeParams({ depositFeeBps: 0, withdrawFeeBps: 0, perfRateX: 0, minCrystallizeInterval: 0, treasury: address(0) });
    }
    function getWithdrawalParams(address) external view returns (WithdrawalParams memory) {
        return WithdrawalParams({
            capPerEpochBps: _capPerEpochBps,
            maxWithdrawalPerBlock: 0,
            maxWithdrawalPerTx: 0,
            minClaimAmount: 0,
            lockPeriod: _lockPeriod
        });
    }
    function getDynamicCapParams(address) external view returns (DynamicCapParams memory) {
        return DynamicCapParams({
            minBps: _dcpMinBps, maxBps: _dcpMaxBps, queueStressThreshold: _dcpThreshold, enabled: _dcpEnabled
        });
    }
    function getQueueParams(address) external view returns (QueueParams memory) {
        return QueueParams({ maxClaimsPerUserPerEpoch: 255, cooldownPerClaim: 0, epochDuration: _epochDuration });
    }
    function getSecurityParams(address) external pure returns (SecurityParams memory) {
        return SecurityParams({ circuitBreakerBps: 0, tvlSnapshotInterval: 1 hours, oracle: address(0), oracleStalenessLimit: 1 hours });
    }
    function getBufferParams(address) external pure returns (BufferParams memory) {
        return BufferParams({ targetHotBps: 300, minHotBps: 200, targetWarmBps: 700, maxWarmBps: 1000, opsReserveTargetBps: 100, maxWarmSlippageBps: 50 });
    }
    function getStrategyParams(address) external pure returns (StrategyParams memory) {
        return StrategyParams({ maxStrategyBps: 2000, lossCapBps: 100, aggregateLossCapBps: 500, gasPerStrategyWithdraw: 100000 });
    }
    function getBatchGuardrails(address) external pure returns (BatchGuardrails memory) {
        return BatchGuardrails({ maxActionsPerBatch: 100, maxNavDeltaBps: 1000, maxStaleness: 1 hours });
    }
    function getDepositLimits(address) external pure returns (DepositLimits memory) {
        return DepositLimits({ vaultDepositCap: 0, userDepositCap: 0, minDepositAmount: 0 });
    }
    function getNavSmoothingParams(address) external pure returns (NavSmoothingParams memory) {
        return NavSmoothingParams({ alphaBps: 200, interval: 3600, enabled: false });
    }
    function hasOverrides(address) external pure returns (bool) { return false; }
    function isAdapterAllowed(address) external pure returns (bool) { return true; }
    function adapterCap(address) external pure returns (uint256) { return type(uint256).max; }
    function oracleFor(address) external pure returns (address) { return address(0); }
    function oracleConfigFor(address, address) external pure returns (address, uint256) { return (address(0), 3600); }
    function maxActionsPerBatch() external pure returns (uint8) { return 100; }
    function maxNavDeltaBps() external pure returns (uint16) { return 10000; }
    function maxStaleness() external pure returns (uint256) { return 3600; }
    function minRebalanceCooldown() external pure returns (uint256) { return 0; }
    function version() external pure returns (uint16) { return 1; }
    function minParamDelay(address) external pure returns (uint64) { return 2 days; }
    function maxPerfRate(address) external pure returns (uint256) { return 5e17; }
    function maxFeeBps(address) external pure returns (uint16) { return 500; }
    function maxImmediateExitPenaltyBps(address) external pure returns (uint16) { return 200; }
    function maxForceExitPenaltyBps(address) external pure returns (uint16) { return 200; }
    function guardianPauseCooldown(address) external pure returns (uint64) { return 7 days; }
    function minDeployAmount(address) external pure returns (uint256) { return 10e6; }
    function stratTaGas(address) external pure returns (uint256) { return 1_000_000; }
    function opsMaxBps(address) external pure returns (uint16) { return 3000; }
}

contract QueueEpochModule_WithdrawFlow_POC is Test {
    address constant USDC_UNDERLYING = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address internal user;
    address internal userB;

    CoreHarness internal core;
    MockUSDC internal mock;
    MockQueueEpochParamsProvider internal params;

    bytes32 internal constant WITHDRAW_TOPIC = keccak256("Withdraw(address,address,address,uint256,uint256)");

    function setUp() public {
        user = makeAddr("user");
        userB = makeAddr("userB");

        mock = new MockUSDC();
        vm.etch(USDC_UNDERLYING, address(mock).code);

        params = new MockQueueEpochParamsProvider();
        core = new CoreHarness(
            IERC20Metadata(USDC_UNDERLYING),
            "USDC Agg",
            "agUSDC",
            address(this), // owner
            address(this), // feeCollector
            address(params)
        );

        // Cap-epoch duration required by ExitEngineLib.rollEpochIfNeeded (deploy-time guarantee).
        core.setEpochDurationUnsafe(7 days);

        MockUSDC(USDC_UNDERLYING).mint(user, 10_000_000e6);
        MockUSDC(USDC_UNDERLYING).mint(userB, 10_000_000e6);
        vm.prank(user);
        IERC20(USDC_UNDERLYING).approve(address(core), type(uint256).max);
        vm.prank(userB);
        IERC20(USDC_UNDERLYING).approve(address(core), type(uint256).max);
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = ERC4626Module(address(core)).deposit(assets, who);
    }

    // =========================================================================
    // BUG A (CRITICAL) -- msg.sender corruption in instant->queue fallback
    // =========================================================================
    //
    // Lock period blocks instant settlement, forcing the fallback path. With
    // the bug, the fallback used `this.requestEpochWithdrawal(shares)`, which
    // re-entered as an external call with msg.sender rebound to the vault --
    // so the share transfer FROM msg.sender (now the vault, holding 0 of its
    // own shares) reverted, and the whole requestInstantWithdrawal() call
    // reverted instead of gracefully queueing the claim as documented.
    function test_instantWithdrawalFallback_attributesClaimToRealUser() public {
        params.setLockPeriod(1 days);
        uint256 shares = _deposit(user, 1_000_000e6);

        // Still within the lock period -> _canInstant() must fail -> fallback.
        vm.prank(user);
        (bool settledImmediately, uint256 epochId, uint256 claimId) =
            EpochedQueueModule(address(core)).requestInstantWithdrawal(shares);

        assertFalse(settledImmediately, "FIX CONFIRMED: locked withdrawal falls back to queue instead of reverting");

        EpochQueueStorage.EpochClaim memory claim =
            EpochedQueueModule(address(core)).epochClaim(epochId, claimId);

        assertEq(claim.user, user, "FIX CONFIRMED: claim is attributed to the real user, not the vault");
        assertEq(claim.netShares + claim.feeShares, shares, "FIX CONFIRMED: full gross shares escrowed under the user's claim");

        // Shares actually left the user's balance into vault escrow.
        assertEq(core.balanceOf(user), 0, "user's shares moved into escrow");
        assertEq(core.balanceOf(address(core)), shares, "escrow holds the user's gross shares");
    }

    // =========================================================================
    // BUG B (HIGH) -- escrowedShares accounting drift
    // =========================================================================

    /// @dev Full single-claim lifecycle: escrowedShares must return to exactly
    ///      zero once the only claim in the epoch is closed, funded, and claimed.
    ///      Before the fix, the fee shares removed from escrow at close were
    ///      never un-tracked, so escrowedShares got stuck at totalFeeShares > 0.
    function test_escrowedShares_zeroAfterFullSingleClaimLifecycle() public {
        core.setExitFeesUnsafe(100, 0, 0); // 1% withdrawal fee -> non-zero feeShares
        uint256 shares = _deposit(user, 1_000_000e6);

        vm.prank(user);
        (uint256 epochId, uint256 claimId) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(shares);

        vm.warp(block.timestamp + 1 days + 1);
        EpochedQueueModule(address(core)).closeCurrentEpoch();
        EpochedQueueModule(address(core)).fundEpoch(epochId);

        EpochQueueStorage.EpochData memory epoch =
            EpochedQueueModule(address(core)).epochData(epochId);
        assertTrue(epoch.state == EpochQueueStorage.EpochState.Funded, "epoch funded (ample hot liquidity, no strategy deployed)");

        vm.prank(user);
        EpochedQueueModule(address(core)).claimEpochAssets(epochId, claimId);

        assertEq(
            EpochedQueueModule(address(core)).totalEscrowedShares(),
            0,
            "FIX CONFIRMED: escrowedShares returns to 0 once the only claim is fully settled"
        );
    }

    /// @dev Two equal-sized claims in the same epoch, one settled via
    ///      claimEpochAssets(), the other via batchClaimEpochAssets(). Both
    ///      paths must reduce escrowedShares by the same amount (netShares).
    ///      Before the fix, batchClaimEpochAssets() never touched
    ///      escrowedShares at all, so the two paths diverged.
    function test_escrowedShares_consistentAcrossClaimAndBatchClaimPaths() public {
        core.setExitFeesUnsafe(100, 0, 0); // 1% fee, applies identically to both claims
        uint256 sharesA = _deposit(user, 500_000e6);
        uint256 sharesB = _deposit(userB, 500_000e6);

        vm.prank(user);
        (uint256 epochId, uint256 claimIdA) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(sharesA);
        vm.prank(userB);
        (, uint256 claimIdB) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(sharesB);

        vm.warp(block.timestamp + 1 days + 1);
        EpochedQueueModule(address(core)).closeCurrentEpoch();
        EpochedQueueModule(address(core)).fundEpoch(epochId);

        uint256 escrowBeforeA = EpochedQueueModule(address(core)).totalEscrowedShares();
        vm.prank(user);
        EpochedQueueModule(address(core)).claimEpochAssets(epochId, claimIdA);
        uint256 deltaA = escrowBeforeA - EpochedQueueModule(address(core)).totalEscrowedShares();

        uint256 escrowBeforeB = EpochedQueueModule(address(core)).totalEscrowedShares();
        uint256[] memory ids = new uint256[](1);
        ids[0] = claimIdB;
        vm.prank(userB);
        EpochedQueueModule(address(core)).batchClaimEpochAssets(epochId, ids);
        uint256 deltaB = escrowBeforeB - EpochedQueueModule(address(core)).totalEscrowedShares();

        assertEq(
            deltaA,
            deltaB,
            "FIX CONFIRMED: claimEpochAssets and batchClaimEpochAssets reduce escrowedShares identically"
        );
        assertEq(
            EpochedQueueModule(address(core)).totalEscrowedShares(),
            0,
            "FIX CONFIRMED: both equal-fee claims fully settled -> escrow back to 0"
        );
    }

    // =========================================================================
    // BUG C (MEDIUM) -- batchClaimEpochAssets() must emit IERC4626.Withdraw
    // =========================================================================
    function test_batchClaimEpochAssets_emitsWithdrawEvent() public {
        uint256 shares = _deposit(user, 1_000_000e6);

        vm.prank(user);
        (uint256 epochId, uint256 claimId) =
            EpochedQueueModule(address(core)).requestEpochWithdrawal(shares);

        vm.warp(block.timestamp + 1 days + 1);
        EpochedQueueModule(address(core)).closeCurrentEpoch();
        EpochedQueueModule(address(core)).fundEpoch(epochId);

        uint256[] memory ids = new uint256[](1);
        ids[0] = claimId;

        vm.recordLogs();
        vm.prank(user);
        EpochedQueueModule(address(core)).batchClaimEpochAssets(epochId, ids);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 withdrawEvents = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == WITHDRAW_TOPIC) {
                withdrawEvents++;
            }
        }

        assertEq(withdrawEvents, 1, "FIX CONFIRMED: batchClaimEpochAssets emits one IERC4626.Withdraw per claim");
    }

    // =========================================================================
    // BUG D (MEDIUM) -- instant cap check must honor dynamic cap policy
    // =========================================================================
    //
    // Dynamic cap enabled: min 1% (stressed) / max 20% (empty queue), stress
    // threshold of 1 pending claim. userB queues one claim first (claimCount
    // becomes 1 in the open epoch -> "stressed" -> effective cap = 1%).
    // With the bug, _canInstant() ignored dynamic cap params entirely and used
    // the (100%, i.e. unlimited) static capPerEpochBps, letting a 5%-of-TVL
    // instant withdrawal straight through despite queue stress.
    function test_instantWithdrawal_respectsDynamicCapUnderQueueStress() public {
        params.setDynamicCap(true, 100, 2000, 1); // enabled, min 1%, max 20%, threshold 1
        uint256 sharesA = _deposit(user, 1_000_000e6);
        _deposit(userB, 10_000e6);

        // userB queues a small claim -> current-epoch claimCount = 1 -> stressed.
        vm.prank(userB);
        EpochedQueueModule(address(core)).requestEpochWithdrawal(1_000e6);

        // userA requests an instant withdrawal worth ~5% of TVL -- exceeds the
        // 1%-under-stress dynamic cap, so it must NOT settle immediately.
        uint256 fivePctShares = sharesA / 20;
        vm.prank(user);
        (bool settledImmediately,,) =
            EpochedQueueModule(address(core)).requestInstantWithdrawal(fivePctShares);

        assertFalse(
            settledImmediately,
            "FIX CONFIRMED: 5% instant withdrawal correctly rejected under a 1% dynamic cap while queue is stressed"
        );
    }
}
