// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CoreStorage } from "../storage/CoreStorage.sol";
import { QueueStorage } from "../storage/QueueStorage.sol";
import { FeeStorage } from "../storage/FeeStorage.sol";
import { Events } from "../libraries/Events.sol";
import { Percentage } from "../../libs/Percentage.sol";
import { FixedPoint } from "../../libs/FixedPoint.sol";
import { IParamsProvider } from "../../interfaces/IParamsProvider.sol";
import { IBufferManager } from "../../interfaces/IBufferManager.sol";
import { IStrategyRouter } from "../../interfaces/IStrategyRouter.sol";
import { QueueLib } from "../libraries/QueueLib.sol";
import { ExitEngineLib } from "../libraries/ExitEngineLib.sol";
import { IIncentivesEngine } from "../../interfaces/IIncentivesEngine.sol";
import {
    FixedMaturityStorage,
    _checkStandardExitAllowed, _checkSettlementAllowed
} from "../storage/FixedMaturityStorage.sol";

/// @title QueueModule v6 (ExitEngineLib Architecture)
/// @notice Handles queue processing, claims, and epoch management.
/// @dev v9 changes (ExitEngineLib refactor):
///      - ALL exit policy via ExitEngineLib (epoch rollover, cap, fee computation)
///      - Fee settlement via share TRANSFER (not mint) — no dilution
///      - Reentrancy guard on requestClaim
///      - NAV freshness: _trySoftRefreshWarmNav() before convertToAssets
///      - Escrow invariant check in _settleScan
///
/// EXIT FEE SEMANTICS (via ExitEngineLib → ExitFeeLib):
///   INSTANT (requestClaim(true)): witBps + immediateExitPenaltyBps
///   STANDARD (requestClaim(false)): witBps only
///   FORCE: handled by ERC4626Module
///
/// INVARIANTS:
///   1. totalSupply NEVER increases on exit (no _mint in exit paths)
///   2. feeShares always from owner/escrow via transfer
///   3. epochWithdrawn <= cap (INSTANT only)
///   4. simulateExit == runtime execution
contract QueueModule {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════
    error ZeroAmount();
    error ClaimTooSmall();
    error TooManyClaimsThisEpoch();
    error ClaimCooldownActive();
    error NotClaimOwner();
    error AlreadySettled();
    error ReentrancyGuardLocked();

    uint256 public constant MAX_BATCH = 100;
    uint256 public constant MAX_WARM_NAV_AGE = 15 minutes;

    // Bounded pre-scan parameters (provisional — calibration required)
    uint256 internal constant MAX_SCAN_MULTIPLIER = 2;
    uint256 internal constant MAX_CONSECUTIVE_INELIGIBLE = 32;

    /// @notice Result of bounded pre-scan — single source of truth for settle
    struct PrescanResult {
        uint256 requiredHot;       // total USDC needed for eligible claims
        uint256 eligibleCount;     // number of eligible claims found
        uint256 inspectedCount;    // total entries inspected
        uint256 scanWindowEnd;     // half-open: settle loop uses [head, scanWindowEnd)
        bool hitEarlyExit;         // true if scan stopped by bound, not by maxClaims
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // QUEUE MANAGEMENT (called via delegatecall)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Request a claim (scheduled or immediate)
    /// @dev Called via delegatecall from CoreVault.
    ///      INSTANT: settles immediately if cap + liquidity OK (fee via transfer).
    ///      STANDARD: queues shares as escrow, settled by keeper.
    function requestClaim(bool immediate, uint256 shares) external {
        // FixedMaturity gate: requestClaim only allowed in Matured (or OpenEnded).
        // Blocked in: Funding, Starting, Active, FundingFailed, Closed.
        _checkStandardExitAllowed(FixedMaturityStorage.layout(), immediate);

        _enterNonReentrant();

        if (shares == 0) revert ZeroAmount();

        CoreStorage.Layout storage core = CoreStorage.layout();
        QueueStorage.Layout storage q = QueueStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();

        // NAV freshness before any convertToAssets (W2: never block)
        _trySoftRefreshWarmNav();

        // Epoch rollover (parametric via ExitEngineLib)
        bool rolled = ExitEngineLib.rollEpochIfNeeded(core);
        if (rolled) {
            emit Events.EpochRolled(core.epochStart);
        }

        // Get withdrawal params
        IParamsProvider.WithdrawalParams memory wp =
            core.params.getWithdrawalParams(address(this));

        // Check minimum claim amount
        uint256 gross = _convertToAssets(shares);
        if (wp.minClaimAmount > 0 && gross < wp.minClaimAmount) revert ClaimTooSmall();

        // Check anti-spam
        _checkQueueAntiSpam(msg.sender);

        // Try INSTANT settlement if requested and conditions met
        if (immediate && _canSettleInstant(gross, wp, core)) {
            // Compute fee shares via ExitEngineLib (rounded UP)
            (uint256 feeShares, uint256 userShares) =
                ExitEngineLib.computeFeeShares(shares, ExitEngineLib.ExitMode.INSTANT, f.fee);

            uint256 netAssets = _convertToAssets(userShares);

            // Sync incentives BEFORE burn (assets-based, try/catch)
            _notifyIncentivesExit(msg.sender, gross, core);

            // Fee via TRANSFER (not mint) — no dilution
            if (feeShares > 0) {
                _transferShares(msg.sender, core.feeCollector, feeShares);
                emit Events.FeePaid(msg.sender, core.feeCollector, feeShares);
            }

            // Burn user shares
            _burn(msg.sender, userShares);

            // Transfer net assets to user
            IERC20(_asset()).safeTransfer(msg.sender, netAssets);

            // Consume epoch cap (INSTANT only)
            ExitEngineLib.consumeEpochCap(core, gross);

            // Emit events
            emit Events.ClaimRequested(0, msg.sender, shares, true);
            emit Events.ClaimSettled(0, msg.sender, netAssets);
            emit Events.InstantExit(msg.sender, shares, netAssets, feeShares);
            emit IERC4626.Withdraw(msg.sender, msg.sender, msg.sender, gross, shares);
        } else {
            // Transfer shares to vault as escrow (will be settled later)
            _transferShares(msg.sender, address(this), shares);

            // Create claim in queue — ALWAYS as STANDARD (immediate=false).
            // If an instant claim falls back to queue, it must NOT remain subject
            // to epoch cap at settlement. Queued = standard = no cap, only lock period.
            uint256 claimId = ++q.nextClaimId;
            q.claims[claimId] = QueueStorage.Claim({
                user: msg.sender,
                ts: uint64(block.timestamp),
                immediate: false,
                settled: false,
                shares: shares
            });

            q.pendingShares += shares;
            q.queue.push(claimId);

            emit Events.ClaimRequested(claimId, msg.sender, shares, false);
            emit Events.SharesFrozen(msg.sender, shares, claimId);
            emit Events.ClaimQueued(claimId);
        }

        _exitNonReentrant();
    }

    /// @notice Cancel a pending claim
    function cancelClaim(uint256 claimId) external {
        QueueStorage.Layout storage q = QueueStorage.layout();
        QueueStorage.Claim storage c = q.claims[claimId];

        if (c.user != msg.sender) revert NotClaimOwner();
        if (c.settled) revert AlreadySettled();
        if (c.shares == 0) revert ZeroAmount();

        uint256 shares = c.shares;
        c.shares = 0;
        c.settled = true;
        q.pendingShares -= shares;

        // Return shares to user
        _transferShares(address(this), msg.sender, shares);

        emit Events.ClaimCancelled(claimId, msg.sender);
        emit Events.SharesUnfrozen(msg.sender, shares, claimId);
    }

    /// @notice Process queued redemptions
    function processQueuedRedemptions(uint256 maxClaims) external {
        if (maxClaims == 0 || maxClaims > MAX_BATCH) revert ZeroAmount();

        CoreStorage.Layout storage core = CoreStorage.layout();
        bool rolled = ExitEngineLib.rollEpochIfNeeded(core);
        if (rolled) emit Events.EpochRolled(core.epochStart);

        uint256 cachedTA = _totalAssets();
        uint256 cachedTS = _totalSupply();
        _settleScan(maxClaims, type(uint256).max, cachedTA, cachedTS);
    }

    /// @notice Settle fees and process queue with cap enforcement
    function settleFeesAndProcessQueue(uint256 maxClaims) external {
        // FixedMaturity gate: settlement only allowed in Matured state (or OpenEnded).
        _checkSettlementAllowed(FixedMaturityStorage.layout());

        if (maxClaims == 0 || maxClaims > MAX_BATCH) revert ZeroAmount();

        CoreStorage.Layout storage core = CoreStorage.layout();
        QueueStorage.Layout storage q = QueueStorage.layout();

        bool rolled = ExitEngineLib.rollEpochIfNeeded(core);
        if (rolled) emit Events.EpochRolled(core.epochStart);

        // Cache totalAssets/totalSupply ONCE for entire settle batch.
        // Deterministic pricing: all claims in the same tx use the same PPS.
        uint256 cachedTA = _totalAssets();
        uint256 cachedTS = _totalSupply();

        uint256 capRem = ExitEngineLib.calculateCapRemaining(
            core, q, cachedTA, address(this)
        );
        _settleScan(maxClaims, capRem, cachedTA, cachedTS);

        // Emit PPS snapshot (reuse cached values — no second totalAssets call)
        emit Events.VaultPpsSnapshot(
            uint64(block.timestamp), cachedTA, cachedTS,
            cachedTS == 0 ? 1e18 : (cachedTA * 1e30) / cachedTS
        );
    }

    /// @notice End epoch and crystallize performance fee
    function endEpochCrystallize() external {
        _crystallize();
        _updateNavSmooth();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    function nextClaimId() external view returns (uint256) {
        return QueueStorage.layout().nextClaimId;
    }

    function queueLength() external view returns (uint256) {
        QueueStorage.Layout storage q = QueueStorage.layout();
        return q.queue.length > q.head ? q.queue.length - q.head : 0;
    }

    function pendingShares() external view returns (uint256) {
        return QueueStorage.layout().pendingShares;
    }

    /// @notice Compute total hot USDC required to settle the next batch of claims.
    /// @dev Used by CoreVault.deficitForQueue and VaultUpkeep scheduler.
    ///      VIEW-only: no state changes, ~2K gas per claim.
    function requiredHotForBatch(uint256 maxClaims) external view returns (uint256 required) {
        CoreStorage.Layout storage core = CoreStorage.layout();
        QueueStorage.Layout storage q = QueueStorage.layout();
        IParamsProvider.WithdrawalParams memory wp =
            core.params.getWithdrawalParams(address(this));
        uint256 cachedTA = _totalAssets();
        uint256 cachedTS = _totalSupply();
        uint256 capRem = ExitEngineLib.calculateCapRemaining(
            core, q, cachedTA, address(this)
        );
        PrescanResult memory pr = _boundedPreScan(maxClaims, capRem, wp, cachedTA, cachedTS);
        required = pr.requiredHot;
    }

    /// @notice Preview what settle would do. Used by VaultUpkeep to avoid churn.
    function settlePreview(uint256 maxClaims) external view returns (
        uint256 eligibleCount,
        uint256 requiredHot,
        uint256 inspectedCount,
        bool hitEarlyExit
    ) {
        CoreStorage.Layout storage core = CoreStorage.layout();
        QueueStorage.Layout storage q = QueueStorage.layout();
        IParamsProvider.WithdrawalParams memory wp =
            core.params.getWithdrawalParams(address(this));
        // Cache valuation — identical to execution path for consistency
        uint256 cachedTA = _totalAssets();
        uint256 cachedTS = _totalSupply();
        uint256 capRem = ExitEngineLib.calculateCapRemaining(
            core, q, cachedTA, address(this)
        );
        PrescanResult memory pr = _boundedPreScan(maxClaims, capRem, wp, cachedTA, cachedTS);
        return (pr.eligibleCount, pr.requiredHot, pr.inspectedCount, pr.hitEarlyExit);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL: BOUNDED PRE-SCAN
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Single source of truth for pre-scan. Bounded by maxClaims * MAX_SCAN_MULTIPLIER
    ///      entries and MAX_CONSECUTIVE_INELIGIBLE consecutive ineligible claims.
    function _boundedPreScan(
        uint256 maxClaims,
        uint256 capRem,
        IParamsProvider.WithdrawalParams memory wp,
        uint256 cachedTA,
        uint256 cachedTS
    ) internal view returns (PrescanResult memory result) {
        QueueStorage.Layout storage q = QueueStorage.layout();
        uint256 j = q.head;
        uint256 jLen = q.queue.length;
        uint256 maxEntries = maxClaims * MAX_SCAN_MULTIPLIER;
        uint256 consecutiveIneligible = 0;

        // Invariant: scanWindowEnd >= head (start at head)
        result.scanWindowEnd = j;

        while (j < jLen && result.eligibleCount < maxClaims && result.inspectedCount < maxEntries) {
            QueueStorage.Claim storage sc = q.claims[q.queue[j]];
            unchecked { ++result.inspectedCount; }

            if (sc.settled || sc.shares == 0) {
                unchecked { ++j; }
                result.scanWindowEnd = j;
                continue;
            }

            uint256 gross = _convertToAssetsCached(sc.shares, cachedTA, cachedTS);
            bool eligible = sc.immediate
                ? (gross <= capRem)
                : (wp.lockPeriod == 0 || block.timestamp >= uint256(sc.ts) + wp.lockPeriod);

            if (eligible) {
                result.requiredHot += gross;
                unchecked { ++result.eligibleCount; }
                consecutiveIneligible = 0;
            } else {
                unchecked { ++consecutiveIneligible; }
                if (consecutiveIneligible >= MAX_CONSECUTIVE_INELIGIBLE) {
                    result.hitEarlyExit = true;
                    result.scanWindowEnd = j + 1; // include this entry in window
                    break;
                }
            }
            unchecked { ++j; }
            result.scanWindowEnd = j;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL: SETTLEMENT SCAN
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev O(1) per-claim settlement. No array shifting.
    ///      Iterates from q.head, skips settled/ghost claims, advances head.
    ///      Compaction is a SEPARATE operation (compactQueue), never in settle path.
    function _settleScan(uint256 maxC, uint256 capRem, uint256 cachedTA, uint256 cachedTS) internal {
        CoreStorage.Layout storage core = CoreStorage.layout();
        QueueStorage.Layout storage q = QueueStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();

        IParamsProvider.WithdrawalParams memory wp =
            core.params.getWithdrawalParams(address(this));
        IERC20 token = IERC20(_asset());

        // NAV freshness — one refresh per scan (W2: never block)
        _trySoftRefreshWarmNav();

        // ─── STEP A: Bounded pre-scan (single source of truth) ───────
        PrescanResult memory pr = _boundedPreScan(maxC, capRem, wp, cachedTA, cachedTS);

        if (pr.hitEarlyExit) {
            emit Events.QueuePrescanBoundHit(
                q.head, pr.inspectedCount, pr.eligibleCount,
                pr.requiredHot, true
            );
        }

        if (pr.eligibleCount == 0) return; // nothing to settle

        // ─── STEP B: Warm refill ONLY (no strategy redeem) ───────────
        uint256 hot = token.balanceOf(address(this));
        {
            if (pr.requiredHot > 0 && hot < pr.requiredHot) {
                IBufferManager bm = core.bufferManager;
                if (address(bm) != address(0)) {
                    uint256 warmGap = pr.requiredHot - hot;
                    (uint256 warmNav,, bool valid) = bm.warmNavState();
                    if (valid && warmNav > 0) {
                        uint256 refillAmt = warmGap < warmNav ? warmGap : warmNav;
                        try bm.refill(refillAmt) {}
                        catch (bytes memory reason) {
                            emit Events.QueueWarmRefillFailed(0, refillAmt, reason);
                        }
                    }
                    hot = token.balanceOf(address(this));
                }
            }
        }

        // ─── STEP C: Settle loop [head, scanWindowEnd) ───────────────
        _settleLoop(pr.scanWindowEnd, pr.eligibleCount, wp.lockPeriod, hot, capRem, cachedTA, cachedTS);
    }

    /// @dev Inner settle loop, extracted to avoid stack-too-deep.
    function _settleLoop(
        uint256 scanWindowEnd,
        uint256 maxProc,
        uint256 lockPeriod,
        uint256 hot,
        uint256 capRem,
        uint256 cachedTA,
        uint256 cachedTS
    ) internal {
        CoreStorage.Layout storage core = CoreStorage.layout();
        QueueStorage.Layout storage q = QueueStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();
        IERC20 token = IERC20(_asset());

        uint256 proc = 0;
        uint256 i = q.head;
        uint256 ew = core.epochWithdrawn;
        uint256 ps = q.pendingShares;

        while (i < scanWindowEnd && proc < maxProc && gasleft() > 150_000) {
            uint256 id = q.queue[i];
            QueueStorage.Claim storage c = q.claims[id];

            // Skip settled/ghost claims
            if (c.settled || c.shares == 0) {
                unchecked { ++i; }
                continue;
            }

            // Escrow invariant check
            {
                uint256 escrowBalance = _balanceOf(address(this));
                if (escrowBalance < c.shares) {
                    emit Events.QueueClaimSkippedEscrowUnderflow(
                        id, c.user, c.shares, escrowBalance
                    );
                    unchecked { ++i; }
                    continue;
                }
            }

            uint256 gross = _convertToAssetsCached(c.shares, cachedTA, cachedTS);
            {
                bool ok = c.immediate
                    ? (gross <= capRem)
                    : (lockPeriod == 0
                        || block.timestamp >= uint256(c.ts) + lockPeriod);

                if (!ok) {
                    unchecked { ++i; }
                    continue;
                }
            }

            // Check hot liquidity (in-memory tracker, no external call)
            if (hot < gross) {
                emit Events.QueueClaimSkippedInsufficientHot(id, hot, gross);
                unchecked { ++i; }
                continue;
            }

            // Sync incentives BEFORE burn (assets-based, try/catch)
            _notifyIncentivesExit(c.user, gross, core);

            {
                ExitEngineLib.ExitMode mode = c.immediate
                    ? ExitEngineLib.ExitMode.INSTANT
                    : ExitEngineLib.ExitMode.STANDARD;
                (uint256 feeShares, uint256 userShares) =
                    ExitEngineLib.computeFeeShares(c.shares, mode, f.fee);

                if (feeShares > 0) {
                    _transferShares(address(this), core.feeCollector, feeShares);
                    emit Events.FeePaid(c.user, core.feeCollector, feeShares);
                }

                // CRITICAL: compute net BEFORE burn, using cached TA/TS snapshot.
                uint256 net = _convertToAssetsCached(userShares, cachedTA, cachedTS);
                _burn(address(this), userShares);

                ps -= c.shares;
                c.settled = true;
                token.safeTransfer(c.user, net);

                // Update in-memory hot tracker (avoid redundant balanceOf)
                hot -= net;

                emit Events.ClaimSettled(id, c.user, net);
                emit IERC4626.Withdraw(address(this), c.user, c.user, gross, c.shares);
            }

            if (c.immediate) {
                capRem = capRem >= gross ? capRem - gross : 0;
                ew += gross;
            }

            unchecked { ++i; ++proc; }
        }

        // Advance head past leading settled/ghost claims
        {
            uint256 h = q.head;
            uint256 qLen = q.queue.length;
            while (h < qLen) {
                QueueStorage.Claim storage hc = q.claims[q.queue[h]];
                if (!hc.settled && hc.shares > 0) break;
                unchecked { ++h; }
            }
            q.head = h;
        }

        // Batch commit storage
        core.epochWithdrawn = ew;
        q.pendingShares = ps;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL: INSTANT SETTLEMENT CHECK
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Check if instant settlement is possible
    function _canSettleInstant(
        uint256 grossAssets,
        IParamsProvider.WithdrawalParams memory wp,
        CoreStorage.Layout storage core
    ) internal view returns (bool) {
        // Lock period check
        if (
            wp.lockPeriod > 0
                && block.timestamp < uint256(core.lastDepositTs[msg.sender]) + wp.lockPeriod
        ) {
            return false;
        }

        // Epoch cap check via ExitEngineLib
        QueueStorage.Layout storage q = QueueStorage.layout();
        uint256 capRemaining = ExitEngineLib.calculateCapRemaining(
            core, q, _totalAssets(), address(this)
        );
        if (grossAssets > capRemaining) return false;

        // Liquidity check
        uint256 hot = IERC20(_asset()).balanceOf(address(this));
        if (hot < grossAssets) return false;

        return true;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL: QUEUE MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Compact the queue array by removing processed head entries.
    ///         NEVER called in settle path (O(n)). Call separately when gas is available.
    ///         Safe to call by anyone — idempotent, no economic impact.
    function compactQueue() external {
        QueueStorage.Layout storage q = QueueStorage.layout();
        uint256 h = q.head;
        uint256 len = q.queue.length;
        if (h == 0 || len == 0) return;

        uint256 newLen = len - h;
        for (uint256 i = 0; i < newLen;) {
            q.queue[i] = q.queue[i + h];
            unchecked { ++i; }
        }
        for (uint256 i = 0; i < h;) {
            q.queue.pop();
            unchecked { ++i; }
        }
        q.head = 0;
    }

    function _checkQueueAntiSpam(address user) internal {
        CoreStorage.Layout storage core = CoreStorage.layout();

        IParamsProvider.QueueParams memory qp =
            core.params.getQueueParams(address(this));
        if (qp.maxClaimsPerUserPerEpoch == 0 && qp.cooldownPerClaim == 0) return;

        (bool adv, uint64 ns) = QueueLib.shouldAdvanceEpoch(
            block.timestamp, core.lastEpochReset, qp.epochDuration
        );
        if (adv) {
            unchecked { ++core.currentEpochNumber; }
            core.lastEpochReset = ns;
        }

        if (
            QueueLib.isCooldownActive(
                core.userLastClaimTime[user], block.timestamp, qp.cooldownPerClaim
            )
        ) {
            revert ClaimCooldownActive();
        }

        if (qp.maxClaimsPerUserPerEpoch > 0) {
            uint64 epoch = core.currentEpochNumber;
            if (core.userLastClaimEpoch[user] < epoch) {
                core.userClaimsCount[user] = 0;
                core.userLastClaimEpoch[user] = epoch;
            }
            if (
                QueueLib.isClaimCountExceeded(
                    core.userClaimsCount[user], qp.maxClaimsPerUserPerEpoch
                )
            ) {
                revert TooManyClaimsThisEpoch();
            }
            unchecked { ++core.userClaimsCount[user]; }
        }

        core.userLastClaimTime[user] = uint64(block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL: NAV FRESHNESS (W2 = never block exits)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Best-effort soft NAV refresh. GUARANTEED non-reverting.
    ///      If refresh fails → silently ignored, exit proceeds with stale NAV.
    function _trySoftRefreshWarmNav() internal {
        CoreStorage.Layout storage core = CoreStorage.layout();
        IBufferManager bm = core.bufferManager;
        if (address(bm) == address(0)) return;

        (, uint40 ts,) = bm.warmNavState();
        if (block.timestamp > ts + MAX_WARM_NAV_AGE) {
            try bm.refreshWarmNav() {} catch {}
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL: INCENTIVES EXIT SYNC
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Notify IncentivesEngine on exit. Assets-based, try/catch, never blocks.
    function _notifyIncentivesExit(
        address user,
        uint256 assetsExited,
        CoreStorage.Layout storage core
    ) internal {
        IIncentivesEngine eng = core.incentivesEngine;
        if (address(eng) == address(0)) return;
        try eng.onExitLight(user, assetsExited * 1e12) {} catch {}
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL: REENTRANCY GUARD
    // ═══════════════════════════════════════════════════════════════════════════════

    function _enterNonReentrant() internal {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_REENTRANCY_LOCKED != 0) {
            revert ReentrancyGuardLocked();
        }
        core.packedFlags |= CoreStorage.FLAG_REENTRANCY_LOCKED;
    }

    function _exitNonReentrant() internal {
        CoreStorage.layout().packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VAULT INTERFACE CALLS (delegatecall context → address(this) IS CoreVault)
    // ═══════════════════════════════════════════════════════════════════════════════

    function _asset() internal view returns (address) {
        (bool success, bytes memory data) =
            address(this).staticcall(abi.encodeWithSignature("asset()"));
        require(success, "asset call failed");
        return abi.decode(data, (address));
    }

    function _totalAssets() internal view returns (uint256) {
        (bool success, bytes memory data) =
            address(this).staticcall(abi.encodeWithSignature("totalAssets()"));
        require(success, "totalAssets call failed");
        return abi.decode(data, (uint256));
    }

    function _totalSupply() internal view returns (uint256) {
        (bool success, bytes memory data) =
            address(this).staticcall(abi.encodeWithSignature("totalSupply()"));
        require(success, "totalSupply call failed");
        return abi.decode(data, (uint256));
    }

    /// @dev Cached conversion: uses pre-computed totalAssets/totalSupply snapshot.
    ///      Settle uses snapshot pricing for deterministic intra-batch valuation.
    ///      Intra-batch asset movements do NOT affect other users' conversion rate.
    function _convertToAssetsCached(uint256 shares, uint256 cachedTA, uint256 cachedTS)
        internal pure returns (uint256)
    {
        if (cachedTS == 0) return 0;
        return (shares * cachedTA) / cachedTS;
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        (bool success, bytes memory data) = address(this).staticcall(
            abi.encodeWithSignature("convertToAssets(uint256)", shares)
        );
        require(success, "convertToAssets call failed");
        return abi.decode(data, (uint256));
    }

    function _balanceOf(address account) internal view returns (uint256) {
        (bool success, bytes memory data) = address(this).staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        require(success, "balanceOf call failed");
        return abi.decode(data, (uint256));
    }

    /// @dev Raw asset-to-share conversion WITHOUT deposit fee.
    ///      Used for perf fee minting and settle fee calculation.
    function _previewDeposit(uint256 assets) internal view returns (uint256) {
        (bool success, bytes memory data) = address(this).staticcall(
            abi.encodeWithSignature("convertToShares(uint256)", assets)
        );
        require(success, "convertToShares call failed");
        return abi.decode(data, (uint256));
    }

    function _transferShares(address from, address to, uint256 amount) internal {
        (bool success,) = address(this).call(
            abi.encodeWithSignature(
                "processorTransfer(address,address,uint256)", from, to, amount
            )
        );
        require(success, "transfer failed");
    }

    function _mint(address to, uint256 amount) internal {
        (bool success,) = address(this).call(
            abi.encodeWithSignature("processorMint(address,uint256)", to, amount)
        );
        require(success, "mint failed");
    }

    function _burn(address from, uint256 amount) internal {
        (bool success,) = address(this).call(
            abi.encodeWithSignature("processorBurn(address,uint256)", from, amount)
        );
        require(success, "burn failed");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PERFORMANCE FEE CRYSTALLIZATION
    // ═══════════════════════════════════════════════════════════════════════════════

    function _pps() internal view returns (uint256) {
        uint256 ts = _totalSupply();
        return ts == 0 ? FixedPoint.WAD : FixedPoint.divWadDown(_totalAssets(), ts);
    }

    function _crystallize() internal returns (uint256 newHwm, uint256 feeAssets) {
        FeeStorage.Layout storage f = FeeStorage.layout();
        CoreStorage.Layout storage core = CoreStorage.layout();

        uint256 ts = _totalSupply();
        if (ts == 0) {
            f.highWaterMark = FixedPoint.WAD;
            f.lastCrystallize = uint64(block.timestamp);
            emit Events.Crystallized(0, FixedPoint.WAD, 0);
            return (FixedPoint.WAD, 0);
        }

        uint256 pps = _pps();
        uint256 old = f.highWaterMark == 0 ? FixedPoint.WAD : f.highWaterMark;

        if (pps <= old) {
            f.highWaterMark = pps;
            f.lastCrystallize = uint64(block.timestamp);
            emit Events.Crystallized(old, pps, 0);
            return (pps, 0);
        }

        uint256 total = _totalAssets();
        uint256 oldAssets = FixedPoint.mulWadDown(old, ts);
        uint256 profit = total > oldAssets ? total - oldAssets : 0;
        feeAssets = FixedPoint.mulWadDown(profit, f.perfRateX);

        if (feeAssets > 0) {
            uint256 ppsBefore = pps;
            uint256 feeShares = _previewDeposit(feeAssets);
            if (feeShares > 0) {
                _mint(core.feeCollector, feeShares);
                emit Events.PerfFeeMinted(old, ppsBefore, feeShares, _pps());
            }
        }

        newHwm = _pps();
        f.highWaterMark = newHwm;
        f.lastCrystallize = uint64(block.timestamp);
        emit Events.Crystallized(old, newHwm, feeAssets);
    }

    function _updateNavSmooth() internal {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (address(core.params) == address(0)) return;

        IParamsProvider.NavSmoothingParams memory nsp =
            core.params.getNavSmoothingParams(address(this));
        if (!nsp.enabled) return;

        uint256 navReal = _totalAssets();
        bool initialized =
            (core.packedFlags & CoreStorage.FLAG_NAV_SMOOTH_INIT) != 0;

        if (!initialized) {
            core.navSmooth = navReal;
            core.lastNavSmoothUpdate = uint64(block.timestamp);
            core.packedFlags |= CoreStorage.FLAG_NAV_SMOOTH_INIT;
            emit Events.NavSmoothUpdated(navReal, navReal, block.timestamp);
            return;
        }

        if (
            block.timestamp
                < uint256(core.lastNavSmoothUpdate) + nsp.interval
        ) {
            return;
        }

        uint256 alpha = nsp.alphaBps;
        uint256 newSmooth =
            (alpha * navReal + (10000 - alpha) * core.navSmooth) / 10000;

        core.navSmooth = newSmooth;
        core.lastNavSmoothUpdate = uint64(block.timestamp);

        emit Events.NavSmoothUpdated(navReal, newSmooth, block.timestamp);
    }
}
