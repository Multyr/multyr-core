// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CoreStorage} from "../storage/CoreStorage.sol";
import {FeeStorage} from "../storage/FeeStorage.sol";
import {Events} from "../libraries/Events.sol";
import {ExitEngineLib} from "../libraries/ExitEngineLib.sol";
import {WithdrawalCapLib} from "../libraries/WithdrawalCapLib.sol";
import {Percentage} from "../../libs/Percentage.sol";
import {FixedPoint} from "../../libs/FixedPoint.sol";
import {IParamsProvider} from "../../interfaces/IParamsProvider.sol";
import {IBufferManager} from "../../interfaces/IBufferManager.sol";
import {IStrategyRouter} from "../../interfaces/IStrategyRouter.sol";
import {IIncentivesEngine} from "../../interfaces/IIncentivesEngine.sol";
import {ICoreVault} from "../../interfaces/ICoreVault.sol";
import {
    FixedMaturityStorage,
    _checkStandardExitAllowed,
    _checkSettlementAllowed
} from "../storage/FixedMaturityStorage.sol";

// =============================================================================
// EPOCH QUEUE STORAGE  (EIP-7201 namespaced, separate from QueueStorage)
// =============================================================================

library EpochQueueStorage {
    // keccak256(abi.encode(uint256(keccak256("multyr.storage.EpochQueue.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT =
        0xd8f6996c75206120e7e007afb307a0ab5673f8e6af6fff1bc619c574ef0f3000;

    enum EpochState {
        Open,
        Closed,
        Funded
    }

    // Per-epoch aggregate data. Stored once per epoch.
    //
    // An epoch is a SETTLEMENT BUCKET, not a pricing event: every claim in it
    // was priced (and its shares burned) at request time, so nothing here holds
    // a price. It only groups liabilities so liquidity is prepared and funded
    // in one batch.
    struct EpochData {
        EpochState state;
        uint64 openedAt; // block.timestamp when this epoch opened
        uint64 closedAt; // block.timestamp when closeCurrentEpoch() ran
        uint64 fundedAt; // block.timestamp when fundEpoch() succeeded
        uint256 totalGrossShares; // running sum of all submitted shares (informational)
        uint256 totalNetShares; // running sum after fee deduction (informational)
        uint256 totalFeeShares; // running sum of fee portions (informational)
        uint256 totalAssetsOwed; // running sum of NOMINAL assetsOwed of every claim in the epoch
        uint256 claimedAssets; // running sum of NOMINAL assetsOwed of claims already claimed
        uint256 claimCount; // number of claims submitted
        uint256 reservedRemaining; // liquidity still earmarked for THIS epoch's unclaimed claims
        // Option A -- crystallized recovery ratio for this cohort (WAD, <= 1e18), set EXACTLY
        // ONCE, at the moment fundEpoch() first transitions this epoch Closed -> Funded (after
        // its realize waterfall has run). 1e18 while solvent (identity payout). Immutable from
        // then on: claim timing inside the cohort cannot change it, and a later recovery in
        // gross assets does not reopen it -- it simply raises totalAssets() for remaining
        // shareholders. Every claim in this epoch pays assetsOwed * recoveryIndex / 1e18,
        // never the live, cross-epoch liabilityIndex().
        uint256 recoveryIndex;
    }

    // Per-claim entry. Stored under (epochId => claimId). Immutable after
    // creation apart from the `claimed` flag: assetsOwed is fixed at request.
    struct EpochClaim {
        address user;
        uint64 requestedAt; // block.timestamp of the request
        bool claimed; // user has received assets
        uint256 assetsOwed; // NOMINAL fixed liability, priced at request (rounded down)
        uint256 grossShares; // shares the user submitted (net burned + fee transferred at request)
    }

    struct Layout {
        uint256 currentEpochId;
        // epochId => epoch aggregate
        mapping(uint256 => EpochData) epochs;
        // epochId => claimId => claim
        mapping(uint256 => mapping(uint256 => EpochClaim)) claims;
        // epochId => next claimId counter (starts at 1)
        mapping(uint256 => uint256) nextClaimId;
        // Total unclaimed claims across ALL epochs (open + closed-unfunded +
        // funded-unclaimed). FixedMaturityModule requires zero before Matured->Closed.
        // This counter does not affect the instant cap.
        uint256 outstandingClaimCount;
        // Oldest epoch that is CLOSED but not yet FUNDED. Lets a keeper find
        // "what needs fundEpoch() next" in O(1) instead of scanning epoch IDs
        // from 0. Lazily advanced in fundEpoch() past any now-consecutively-
        // FUNDED epochs (funding can happen out of order, so this only advances
        // when the just-funded epoch IS the current cursor position).
        uint256 oldestUnfundedEpochId;
        // Liquidity EARMARKED by fundEpoch() for FUNDED-but-unclaimed claims.
        // Its only job: every other consumer of hot cash (instant exits,
        // deployToStrategies, funding a LATER epoch, force exit) must treat
        // `hot - reservedForClaims` (saturating) as the only spendable balance.
        // It is NOT subtracted from NAV -- totalOwed already contains everything
        // owed, funded or not, so subtracting both would double count.
        //
        // Funding adds the cohort's crystallized reserve. Claims release their
        // proportional share; the final claim releases all remaining dust.
        uint256 reservedForClaims;
        // Unfunded nominal liabilities plus funded cohorts' remaining reserves.
        // The single source of truth for the vault's fixed liabilities to exited
        // users (CoreVault.totalOwed() reads it). Written only by this module:
        // += at request; -= at funding write-down, claim and instant settlement.
        uint256 totalOwed;
        // Event de-duplication latch ONLY: remembers whether InsolvencyEntered
        // was the last insolvency event emitted. Insolvency itself is derived
        // (grossAssets < totalOwed) and never read from here.
        bool insolvencyLatched;
        // Count of unclaimed claims in Funded epochs, including zero-recovery claims.
        uint256 fundedOutstandingClaimCount;
        // Number of Closed -> Funded transitions. Only ever increases, so a keeper can detect a
        // new funding even when claims settled in the same block leave
        // fundedOutstandingClaimCount unchanged.
        uint256 fundedEpochCount;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly { l.slot := slot }
    }
}

// =============================================================================
// MODULE
// =============================================================================

/// @title EpochedQueueModule
/// @notice Economic-exit withdrawal engine: price once at request, settle later
///         through epoch buckets.
///
/// @dev THE MODEL ("Withdrawal Model -- Economic Exit at Request")
///
///   Once a standard/instant withdrawal request is accepted the user has
///   ECONOMICALLY EXITED the vault. In one transaction, in this order:
///     1. the price is fixed at the current share price      (convertToAssets)
///     2. the amount owed is recorded as a fixed liability   (totalOwed += owed)
///     3. the user's net shares are burned
///   From that instant the user is a creditor with a fixed claim in assets and
///   no longer participates in NAV gains or losses. Remaining holders own the
///   residual. There is no cancel: an accepted request cannot be cancelled,
///   modified, transferred or re-priced.
///
///   The epoch prices nothing. It is a settlement bucket that groups claims so
///   liquidity is prepared and funded in one batch:
///
///     REQUEST -> crystallize price -> fixed assetsOwed -> burn -> liability
///             -> epoch settlement bucket -> funding -> claim
///
/// ACCOUNTING PRIMITIVES (each has exactly one source of truth, on CoreVault)
///   grossAssets()   hot + warm + sum(strategy assets)   physical portfolio value
///   totalOwed()     sum of nominal assetsOwed, unclaimed claims, funded or not
///   totalAssets()   max(0, grossAssets - totalOwed)     active shareholder NAV
///   liabilityIndex  1e18 if solvent, else grossAssets * 1e18 / totalOwed
///
/// EPOCH STATE MACHINE
///   OPEN    -- current epoch, accepting new claims
///   CLOSED  -- epoch closed to new claims, awaiting liquidity
///   FUNDED  -- liquidity earmarked (reservedForClaims); users can self-claim
///
///   OPEN ---[closeCurrentEpoch()]---> CLOSED ---[fundEpoch()]---> FUNDED
///                                                  (repeatable until funded)
///
contract EpochedQueueModule {
    using SafeERC20 for IERC20;

    // =========================================================================
    // ERRORS
    // =========================================================================
    error ZeroAmount();
    error EpochNotOpen();
    error EpochNotClosed();
    error EpochNotFunded();
    error EpochTooYoung(); // closeCurrentEpoch() called before epochDuration
    error ClaimAlreadySettled();
    error NotClaimOwner();
    error ReentrancyGuardLocked();
    error EpochAlreadyFunded();
    /// @notice grossAssets < totalOwed: new standard/instant requests revert (W-3).
    error VaultInsolvent();
    /// @notice A claim pays more than its epoch's earmark (the index recovered after funding) and
    ///         free liquidity cannot cover the difference yet. Retry once liquidity is back.
    error InsufficientFreeLiquidity();
    /// @notice The warm NAV cache is flagged invalid, or no BufferManager is wired.
    error NavInvalid();
    /// @notice The warm NAV cache is older than MAX_WARM_NAV_AGE.
    error NavStale();
    /// @notice A strategy valuation, strategy health status or oracle input required by the NAV
    ///         failed validation (reason: 4 strategy valuation, 5 strategy unhealthy, 6 oracle).
    error NavInputInvalid(uint8 reason);
    /// @notice Standard and instant requests are both blocked during the post-deposit lock
    ///         period. Force exit remains the intended bypass.
    error DepositLockActive();
    // Granular withdrawal circuit breakers. FLAG_PAUSED_WITHDRAWALS
    // is honored, in addition to the specific flag, only by instant settlement and
    // epoch close/fund -- NOT by queued-request creation or funded claims (see
    // _notPausedQueuedRequest / _notPausedFundedClaim below for why).
    // No InstantWithdrawalPaused error: requestInstantWithdrawal() treats a
    // paused instant breaker as "instant unavailable" and silently falls back
    // to the queue (see the instantAllowed check below), never reverts for it.
    error QueuedRequestPaused();
    error EpochCloseFundPaused();
    error FundedClaimPaused();

    // =========================================================================
    // EVENTS (epoch lifecycle + claims)
    // =========================================================================
    event EpochOpened(uint256 indexed epochId, uint64 openedAt);
    /// @notice A request was accepted: shares burned, `assetsOwed` is now a
    ///         fixed liability of the vault.
    event EpochWithdrawalRequested(
        uint256 indexed epochId,
        uint256 indexed claimId,
        address indexed user,
        uint256 grossShares,
        uint256 netShares,
        uint256 feeShares,
        uint256 assetsOwed
    );
    /// @notice The epoch bucket closed to new claims. Sets no price.
    event EpochClosed(
        uint256 indexed epochId,
        uint256 totalNetShares,
        uint256 totalAssetsOwed,
        uint256 totalFeeShares
    );
    event EpochFundAttempt(
        uint256 indexed epochId, uint256 needed, uint256 hotBefore, uint256 hotAfter
    );
    event EpochFunded(uint256 indexed epochId, uint256 totalAssetsOwed);
    /// @notice A cohort's recovery ratio was crystallized (Option A): emitted exactly once,
    ///         when fundEpoch() first transitions this epoch Closed -> Funded. `recoveryIndex`
    ///         is immutable from here; every claim in the epoch pays
    ///         `assetsOwed * recoveryIndex / 1e18`. `writeOff` is what was removed from
    ///         `totalOwed` at this instant (unclaimed - recovered, 0 while solvent).
    event EpochRecoveryCrystallized(
        uint256 indexed epochId,
        uint256 recoveryIndex,
        uint256 unclaimed,
        uint256 recovered,
        uint256 writeOff
    );
    /// @notice fundEpoch() was called on an epoch that is already FUNDED, so
    ///         there was nothing to do beyond syncing the keeper cursor.
    /// @dev Not emitted on the keeper's normal path: it targets
    ///      oldestUnfundedEpochId, which points at a CLOSED epoch whenever a
    ///      backlog exists and equals currentEpochId when it does not, and
    ///      checkUpkeep only schedules EPOCH_FUND in the former case. Seeing
    ///      this event means the cursor was stale (cursorAfter > cursorBefore,
    ///      now repaired) or the caller picked the wrong epoch (cursor
    ///      unchanged).
    event EpochFundSkipped(uint256 indexed epochId, uint256 cursorBefore, uint256 cursorAfter);

    /// @notice A fundEpoch() attempt left the epoch CLOSED. Emitted on every
    ///         failed or partial attempt so a stalled epoch is visible to
    ///         monitoring without waiting for a user complaint.
    /// @param epochId       the epoch that could not be funded
    /// @param needed        the epoch's nominal unclaimed liability
    /// @param freeLiquidity hot balance net of other funded epochs' reservations
    /// @param shortfall     how much more is required before it can be funded
    event EpochFundingShortfall(
        uint256 indexed epochId, uint256 needed, uint256 freeLiquidity, uint256 shortfall
    );
    /// @param assets      what was actually paid: assetsOwed * liabilityIndex / 1e18
    /// @param assetsOwed  the claim's nominal, fixed liability
    event EpochAssetsClaimed(
        uint256 indexed epochId,
        uint256 indexed claimId,
        address indexed user,
        uint256 assets,
        uint256 assetsOwed
    );
    /// @notice The vault entered insolvency mode (grossAssets < totalOwed).
    event InsolvencyEntered(uint256 grossAssets, uint256 totalOwed, uint256 liabilityIndex);
    /// @notice The vault left insolvency mode (grossAssets >= totalOwed again).
    event InsolvencyExited(uint256 grossAssets, uint256 totalOwed);

    // =========================================================================
    // CONSTANTS
    // =========================================================================
    /// @notice Maximum age of the warm NAV cache for a request to be accepted.
    /// @dev Kept as a public constant for ABI compatibility; sourced from CoreStorage so
    ///      there is exactly one literal value across the vault.
    uint256 public constant MAX_WARM_NAV_AGE = CoreStorage.MAX_WARM_NAV_AGE;

    /// @notice Upper bound on how far one call may advance the
    ///         oldestUnfundedEpochId cursor, so the scan can never blow the
    ///         block gas limit. Hitting the bound leaves the cursor lagging,
    ///         never stuck: see syncOldestUnfundedEpoch().
    uint256 public constant MAX_CURSOR_SCAN = 50;

    /// @notice Maximum funding shortfall in underlying base units.
    uint256 public constant INSOLVENCY_FUNDING_ROUNDING = 1;
    event EpochFundingNavInvalid(uint256 indexed epochId, uint8 reason);

    /// @notice fundEpoch() asks strategies for the deficit plus this many basis points (and 1 unit) to absorb
    ///         withdrawal slippage; 50 bps equals StrategyRouter's default loss cap.
    uint256 public constant STRATEGY_REDEEM_BUFFER_BPS = 50;

    /// @dev Minimum strategy pull: 0.01 underlying units, derived from asset decimals.
    function _minStrategyRedeem() internal view returns (uint256) {
        uint8 dec = IERC20Metadata(_asset()).decimals();
        return dec >= 2 ? 10 ** (dec - 2) : 1;
    }

    // =========================================================================
    // REQUEST -- PRICE ONCE (P0-B)
    // =========================================================================

    /// @notice Request a standard (queued) withdrawal. On success the caller has
    ///         economically exited: the price is fixed, the net shares are burned
    ///         and `assetsOwed` is recorded as a fixed liability. The request can
    ///         never be cancelled or re-priced.
    ///
    /// @param shares Gross shares to withdraw (fee included)
    /// @return epochId  The epoch (settlement bucket) this claim belongs to
    /// @return claimId  Unique claim ID within the epoch
    function requestEpochWithdrawal(uint256 shares)
        external
        returns (uint256 epochId, uint256 claimId)
    {
        _notPausedQueuedRequest();
        _enterNonReentrant();
        _rollCapEpochIfNeeded(CoreStorage.layout());
        _checkStandardExitAllowed(FixedMaturityStorage.layout(), false);
        if (shares == 0) revert ZeroAmount();

        // Both ordinary exit paths enforce the deposit lock.
        _requireNotLocked(CoreStorage.layout().params.getWithdrawalParams(address(this)));

        _trySoftRefreshWarmNav();
        _openEpochIfNeeded();
        (uint256 netShares, uint256 feeShares, uint256 assetsOwed) =
            _crystallizeExit(msg.sender, shares, ExitEngineLib.ExitMode.STANDARD);
        (epochId, claimId) = _recordClaim(msg.sender, shares, netShares, feeShares, assetsOwed);
        _exitNonReentrant();
    }

    /// @dev The single pricing helper shared by the standard and instant paths.
    ///      The price is computed ONCE, here, before any branch. After it returns
    ///      the price is final: nothing downstream may call convertToAssets again
    ///      for this request, re-apply a fee, or re-convert.
    ///
    ///      Order is load-bearing (W-6): assetsOwed (step 4) MUST be computed
    ///      before the burn (step 6) -- burning first changes the price and hands
    ///      the exiting user a wrong amount.
    ///
    ///      `mode` selects the fee tier after eligibility is checked: immediate settlement
    ///      uses the instant tier; standard requests and queued fallbacks use the standard tier.
    function _crystallizeExit(address user, uint256 grossShares, ExitEngineLib.ExitMode mode)
        internal
        returns (uint256 netShares, uint256 feeShares, uint256 assetsOwed)
    {
        // 1. no insolvency mode (grossAssets < totalOwed). grossAssets == totalOwed leaves zero
        //    shareholder equity: convertToAssets is 0 there too, so an exit would burn shares
        //    for nothing -- same refusal.
        {
            (uint256 gross, uint256 owed,) = _navState();
            if (gross <= owed) revert VaultInsolvent();
        }

        // Entrypoints refresh before pricing; all NAV inputs must be valid.
        _requireFreshNav();

        CoreStorage.Layout storage core = CoreStorage.layout();

        // 3. split gross into fee and net shares (fee rounded UP for the protocol)
        (feeShares, netShares) =
            ExitEngineLib.computeFeeShares(grossShares, mode, FeeStorage.layout().fee);

        // 4. price at the CURRENT share price, rounded down -- BEFORE the burn
        assetsOwed = _convertToAssets(netShares);
        // Not a withdrawal minimum (spec §6.4 keeps none): a 1-wei-share request can
        // legitimately round to 0 owed. Reverting here is about not letting a claim that is
        // worth NOTHING enter the books at all -- it still counts against
        // outstandingClaimCount for free, which would otherwise let a spam of zero-value
        // claims block FixedMaturityModule's Matured->Closed gate (requires
        // outstandingClaimCount == 0) indefinitely.
        if (assetsOwed == 0) revert ZeroAmount();

        // 5. fee shares go to the FeeCollector
        if (feeShares > 0) {
            _transferShares(user, core.feeCollector, feeShares);
            emit Events.FeePaid(user, core.feeCollector, feeShares);
        }

        // 6. burn the net shares
        _burn(user, netShares);

        // 7. the fixed liability
        EpochQueueStorage.layout().totalOwed += assetsOwed;

        _notifyIncentivesExit(user, assetsOwed, core);
    }

    /// @dev Records an accepted request as a claim in the current settlement
    ///      bucket. `assetsOwed` is stored verbatim: never re-priced.
    function _recordClaim(
        address user,
        uint256 grossShares,
        uint256 netShares,
        uint256 feeShares,
        uint256 assetsOwed
    ) internal returns (uint256 epochId, uint256 claimId) {
        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        epochId = eq.currentEpochId;
        EpochQueueStorage.EpochData storage epoch = eq.epochs[epochId];

        claimId = ++eq.nextClaimId[epochId];
        eq.claims[epochId][claimId] = EpochQueueStorage.EpochClaim({
            user: user,
            requestedAt: uint64(block.timestamp),
            claimed: false,
            assetsOwed: assetsOwed,
            grossShares: grossShares
        });

        epoch.totalAssetsOwed += assetsOwed;
        epoch.totalGrossShares += grossShares;
        epoch.totalNetShares += netShares;
        epoch.totalFeeShares += feeShares;
        epoch.claimCount += 1;
        eq.outstandingClaimCount += 1;

        emit EpochWithdrawalRequested(
            epochId, claimId, user, grossShares, netShares, feeShares, assetsOwed
        );
    }

    /// @dev Initialise the current epoch on the very first submission and
    ///      require it to be Open.
    function _openEpochIfNeeded() internal {
        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        EpochQueueStorage.EpochData storage epoch = eq.epochs[eq.currentEpochId];
        if (epoch.openedAt == 0) {
            epoch.openedAt = uint64(block.timestamp);
            epoch.state = EpochQueueStorage.EpochState.Open;
            emit EpochOpened(eq.currentEpochId, uint64(block.timestamp));
        }
        if (epoch.state != EpochQueueStorage.EpochState.Open) revert EpochNotOpen();
    }

    // =========================================================================
    // EPOCH CLOSE -- settlement bucket only, sets no price
    // =========================================================================

    /// @notice Close the current epoch's settlement bucket. It does NOT set any
    ///         price: every claim in it was priced at request. Permissionless --
    ///         anyone can call once epochDuration has elapsed. Continues to work
    ///         in insolvency mode (settlement must keep working).
    ///         Opens a fresh epoch immediately so new submissions are not blocked.
    function closeCurrentEpoch() external {
        _notPausedEpochCloseFund();
        _enterNonReentrant();
        _rollCapEpochIfNeeded(CoreStorage.layout());
        _checkSettlementAllowed(FixedMaturityStorage.layout());

        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        uint256 epochId = eq.currentEpochId;
        EpochQueueStorage.EpochData storage epoch = eq.epochs[epochId];

        if (epoch.state != EpochQueueStorage.EpochState.Open) revert EpochNotOpen();

        // --- Maturity check: epoch must have run for at least epochDuration --
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (block.timestamp < epoch.openedAt + _minEpochDuration(core)) revert EpochTooYoung();

        epoch.closedAt = uint64(block.timestamp);
        epoch.state = EpochQueueStorage.EpochState.Closed;

        emit EpochClosed(epochId, epoch.totalNetShares, epoch.totalAssetsOwed, epoch.totalFeeShares);

        // --- Open the next epoch so new submissions are never blocked ---------
        uint256 nextId = epochId + 1;
        eq.currentEpochId = nextId;
        eq.epochs[nextId].openedAt = uint64(block.timestamp);
        eq.epochs[nextId].state = EpochQueueStorage.EpochState.Open;
        emit EpochOpened(nextId, uint64(block.timestamp));

        (uint256 gross, uint256 owed, uint256 index) = _navState();
        _syncInsolvencyLatch(eq, gross, owed, index);

        _exitNonReentrant();
    }

    // =========================================================================
    // FUNDING
    // =========================================================================

    /// @notice Prepare liquidity for a CLOSED epoch and, once it is fully reconciled,
    ///         crystallize its cohort recovery ratio. Permissionless -- anyone (keeper,
    ///         automation, user) can call. The epoch's TARGET reserve is the sum of the
    ///         NOMINAL assetsOwed of its unclaimed claims, scaled by the free-asset recovery
    ///         ratio, excluding funded reserves from both assets and liabilities. Tries hot balance first, then warm
    ///         refill, then strategy realise, and earmarks whatever it can raise. A partial
    ///         fund emits EpochFundingShortfall and leaves the epoch CLOSED for a retry once
    ///         more liquidity is available -- nothing is crystallized until the epoch is
    ///         fully covered (dust tolerance aside, see INSOLVENCY_FUNDING_ROUNDING).
    ///
    ///         Option A. The moment this call fully reconciles a CLOSED epoch it
    ///         transitions to FUNDED and crystallizes ONE recoveryIndex for the whole
    ///         cohort, derived from what was actually reserved (`reservedRemaining /
    ///         unclaimed`), and writes the haircut portion (if any) out of `totalOwed`
    ///         immediately -- the cohort's true remaining liability from this instant on is
    ///         `reservedRemaining`, not nominal. A FUNDED epoch is therefore a permanent,
    ///         immutable settlement: fundEpoch() on it is a pure no-op forever (it only
    ///         self-heals the keeper cursor), never a top-up. A later recovery in gross
    ///         assets is not owed to this cohort -- it simply raises totalAssets() for
    ///         remaining shareholders. Continues to work in insolvency mode.
    function fundEpoch(uint256 epochId) external {
        _notPausedEpochCloseFund();
        // Guarded like every other state-changing entry point on this module.
        // This one calls out to the buffer manager and the strategy router
        // mid-body and then re-reads the hot balance to decide how much to
        // earmark, so a reentrant call landing between the pull and that read
        // is exactly the shape worth excluding.
        _enterNonReentrant();
        _rollCapEpochIfNeeded(CoreStorage.layout());
        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        EpochQueueStorage.EpochData storage epoch = eq.epochs[epochId];

        if (epoch.state == EpochQueueStorage.EpochState.Open) revert EpochNotClosed();

        if (epoch.state == EpochQueueStorage.EpochState.Funded) {
            // Funded cohorts are immutable. Advance a cursor that points at a funded
            // epoch after an earlier bounded scan exhausted its budget.
            uint256 cursorBefore = eq.oldestUnfundedEpochId;
            _syncOldestUnfunded(eq);
            // Emitting the cursor either side of the sync keeps the case
            // observable and tells the two apart -- a moved cursor is the
            // self-heal doing its job, an unmoved one is a caller that had
            // nothing to do here.
            emit EpochFundSkipped(epochId, cursorBefore, eq.oldestUnfundedEpochId);
            _exitNonReentrant();
            return;
        }

        // This epoch is CLOSED and not yet crystallized: currentReserve is always 0 here
        // (an underfunded attempt below leaves reservedRemaining untouched, so a Closed
        // epoch never carries a partial earmark across retries).
        uint256 unclaimed = epoch.totalAssetsOwed - epoch.claimedAssets;
        uint256 gapNeeded = _scaledByIndex(unclaimed);
        if (gapNeeded < unclaimed) {
            _trySoftRefreshWarmNav();
            gapNeeded = _scaledByIndex(unclaimed);
            (bool valid, uint8 reason) = ICoreVault(address(this)).navStatus();
            if (!valid) {
                emit EpochFundingNavInvalid(epochId, reason);
                _exitNonReentrant();
                return;
            }
        }
        // Everyone else's earmark -- hot must cover both this epoch's target AND that,
        // otherwise filling it would just be spending cash another epoch's claimants
        // already own.
        uint256 otherReserved = eq.reservedForClaims;
        uint256 neededHot = gapNeeded + otherReserved;

        address assetAddr = _asset();
        uint256 hot = IERC20(assetAddr).balanceOf(address(this));
        uint256 hotBefore = hot;

        if (hot < neededHot) {
            uint256 deficit = neededHot - hot;
            CoreStorage.Layout storage core = CoreStorage.layout();

            // --- Step 1: try warm refill (cheaper than strategy redeem) ------
            IBufferManager bm = core.bufferManager;
            if (address(bm) != address(0)) {
                (uint256 warmNav,, bool valid) = bm.warmNavState();
                if (valid && warmNav > 0) {
                    uint256 pullWarm = deficit < warmNav ? deficit : warmNav;
                    try bm.refill(pullWarm) {}
                    catch (bytes memory reason) {
                        emit Events.QueueWarmRefillFailed(epochId, pullWarm, reason);
                    }
                    hot = IERC20(assetAddr).balanceOf(address(this));
                    deficit = hot < neededHot ? neededHot - hot : 0;
                }
            }

            // --- Step 2: strategy redeem for remaining gap -------------------
            if (deficit > 0) {
                IStrategyRouter r = core.router;
                if (address(r) != address(0)) {
                    // Ask for a little MORE than the deficit. Adapters routinely return slightly less than
                    // they are asked for (withdrawal slippage, share rounding), and a solvent epoch needs its
                    // nominal amount on hand exactly: asking for the bare deficit leaves a residue that every
                    // retry shrinks by the same factor and that finally stalls at a unit or two (a 1-unit ask
                    // returns 0). The buffer covers slippage up to the router's default loss cap in one call and
                    // the +1 removes the rounding stall. Surplus cash simply stays in hot for the keeper.
                    // The ask also has a floor: the router's loss cap is a percentage, so on a tiny ask a single
                    // unit of rounding (25 asked, 24 returned = 4%) reads as a big loss and reverts the whole
                    // redeem, which would strand the last few units exactly like the bare-deficit ask does.
                    uint256 ask = deficit + deficit * STRATEGY_REDEEM_BUFFER_BPS / 10_000 + 1;
                    if (ask < _minStrategyRedeem()) ask = _minStrategyRedeem();
                    IStrategyRouter.Pull[] memory plan = r.planRedeem(ask);
                    if (plan.length > 0) {
                        try r.executeRedeemBatch(plan) returns (uint256 got, uint256) {
                            emit Events.RealizedForQueue(deficit, got);
                        } catch {}
                    }
                    hot = IERC20(assetAddr).balanceOf(address(this));
                }
            }
        }

        // Reconcile funding requirements with NAV after liquidity operations.
        gapNeeded = _scaledByIndex(unclaimed);
        neededHot = gapNeeded + otherReserved;
        if (gapNeeded < unclaimed || hot < neededHot) {
            (bool valid, uint8 reason) = ICoreVault(address(this)).navStatus();
            if (!valid) {
                emit EpochFundingNavInvalid(epochId, reason);
                _exitNonReentrant();
                return;
            }
        }

        // One event per call, with both balances populated.
        emit EpochFundAttempt(epochId, gapNeeded, hotBefore, hot);

        // Fill the gap only up to what is actually covered (this call's gap AND
        // everything already reserved for other funded epochs).
        // Insolvency tolerance: see INSOLVENCY_FUNDING_ROUNDING. The earmark is capped at what is
        // actually on hand so it can never promise cash that is not there.
        uint256 shortfall = hot >= neededHot ? 0 : neededHot - hot;
        bool insolventNow = shortfall != 0 && shortfall <= INSOLVENCY_FUNDING_ROUNDING
            && shortfall <= gapNeeded && _isInsolvent();
        if (shortfall == 0 || insolventNow) {
            uint256 filled = gapNeeded - shortfall;
            eq.reservedForClaims += filled;
            epoch.reservedRemaining = filled; // currentReserve is always 0 here

            epoch.state = EpochQueueStorage.EpochState.Funded;
            eq.fundedOutstandingClaimCount += epoch.claimCount;
            eq.fundedEpochCount += 1;
            epoch.fundedAt = uint64(block.timestamp);

            // --- Option A: crystallize this cohort's recovery ratio, exactly once ------
            // Derived from what was ACTUALLY reserved, not the live liabilityIndex, so it
            // is exact for this epoch even where the dust tolerance left reservedRemaining
            // a hair under the live index's implied target. Immutable from here.
            epoch.recoveryIndex = unclaimed == 0
                ? FixedPoint.WAD
                : FixedPoint.divWadDown(epoch.reservedRemaining, unclaimed);

            // Write the haircut down into totalOwed NOW: the cohort's true remaining
            // liability is reservedRemaining, not nominal, from this instant on. Nothing
            // is left dangling on the books waiting for a recovery that would never be
            // owed to it anyway -- a later recovery raises totalAssets() for remaining
            // shareholders instead.
            uint256 writeOff = unclaimed - epoch.reservedRemaining; // >= 0: reservedRemaining <= unclaimed always
            if (writeOff > 0) eq.totalOwed -= writeOff;

            emit EpochRecoveryCrystallized(
                epochId, epoch.recoveryIndex, unclaimed, epoch.reservedRemaining, writeOff
            );
            emit EpochFunded(epochId, epoch.reservedRemaining);

            // Advance the oldest-unfunded cursor past any now-consecutively-
            // FUNDED epochs, but only if this WAS the cursor position — funding
            // can happen out of order, so a later epoch being funded first must
            // not move the cursor past an still-unfunded earlier one.
            if (epochId == eq.oldestUnfundedEpochId) {
                _syncOldestUnfunded(eq);
            }
        } else {
            // Underfunded: stays CLOSED, retry as liquidity arrives. Nothing is
            // crystallized until this branch is NOT taken. Free liquidity is reported net
            // of other funded epochs' reservations (saturating), which is the number that
            // actually governs whether the gap can ever be filled.
            uint256 reserved = eq.reservedForClaims;
            emit EpochFundingShortfall(
                epochId, gapNeeded, hot > reserved ? hot - reserved : 0, neededHot - hot
            );
        }

        (uint256 gross, uint256 owed, uint256 index) = _navState();
        _syncInsolvencyLatch(eq, gross, owed, index);

        _exitNonReentrant();
    }

    /// @notice Advance oldestUnfundedEpochId past any leading FUNDED epochs.
    ///         Permissionless and idempotent.
    /// @dev The scan is bounded, so a long run of out-of-order-funded epochs
    ///      may leave the cursor short of the true oldest unfunded epoch. That
    ///      is a lag, not a wedge: every further call advances it another
    ///      bounded step, and fundEpoch() on an already-funded target syncs it
    ///      too instead of reverting. A cursor pointing at a FUNDED epoch is
    ///      therefore always recoverable without governance.
    function syncOldestUnfundedEpoch() external {
        _notPausedEpochCloseFund();
        _syncOldestUnfunded(EpochQueueStorage.layout());
    }

    function _syncOldestUnfunded(EpochQueueStorage.Layout storage eq) internal {
        uint256 next = eq.oldestUnfundedEpochId;
        uint256 scanned = 0;
        while (
            next < eq.currentEpochId && eq.epochs[next].state == EpochQueueStorage.EpochState.Funded
                && scanned < MAX_CURSOR_SCAN
        ) {
            unchecked {
                ++next;
                ++scanned;
            }
        }
        if (next != eq.oldestUnfundedEpochId) eq.oldestUnfundedEpochId = next;
    }

    // =========================================================================
    // CLAIM
    // =========================================================================

    /// @notice User self-claims from a FUNDED epoch. No keeper required.
    ///         Pays assetsOwed * epoch.recoveryIndex / 1e18 -- the cohort's recovery ratio,
    ///         crystallized ONCE at fund time (Option A), == assetsOwed while the cohort was
    ///         solvent when funded. Never the live, cross-epoch liabilityIndex(): claim
    ///         timing inside (or after) the cohort cannot change what it pays. Shares were
    ///         burned at request: nothing is burned here.
    function claimEpochAssets(uint256 epochId, uint256 claimId) external returns (uint256 assets) {
        _notPausedFundedClaim();
        _enterNonReentrant();
        _rollCapEpochIfNeeded(CoreStorage.layout());

        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        EpochQueueStorage.EpochData storage epoch = eq.epochs[epochId];
        EpochQueueStorage.EpochClaim storage claim = eq.claims[epochId][claimId];

        if (epoch.state != EpochQueueStorage.EpochState.Funded) revert EpochNotFunded();
        if (claim.user != msg.sender) revert NotClaimOwner();
        if (claim.claimed) revert ClaimAlreadySettled();

        (uint256 gross, uint256 owed, uint256 index) = _navState();
        _syncInsolvencyLatch(eq, gross, owed, index);

        uint256 assetsOwed = claim.assetsOwed;
        assets = _payoutAt(assetsOwed, epoch.recoveryIndex);

        // Mark claimed BEFORE external transfers (CEI)
        claim.claimed = true;
        uint256 reservedBefore = eq.reservedForClaims;
        uint256 released = _settleClaimAccounting(eq, epoch, assetsOwed);
        assets = _coverPayout(assets, released, reservedBefore, 0);

        if (assets > 0) {
            IERC20(_asset()).safeTransfer(msg.sender, assets);
        }

        emit EpochAssetsClaimed(epochId, claimId, msg.sender, assets, assetsOwed);
        emit IERC4626.Withdraw(address(this), msg.sender, msg.sender, assets, claim.grossShares);

        _exitNonReentrant();
    }

    /// @notice Batch version of claimEpochAssets for gas efficiency.
    ///         Every claim in the batch is paid at the epoch's crystallized recoveryIndex
    ///         (Option A) -- claim order, inside or across batches, never changes it.
    function batchClaimEpochAssets(uint256 epochId, uint256[] calldata claimIds)
        external
        returns (uint256 totalAssets)
    {
        _notPausedFundedClaim();
        _enterNonReentrant();
        _rollCapEpochIfNeeded(CoreStorage.layout());

        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        EpochQueueStorage.EpochData storage epoch = eq.epochs[epochId];
        if (epoch.state != EpochQueueStorage.EpochState.Funded) revert EpochNotFunded();

        (uint256 gross, uint256 owed, uint256 index) = _navState();
        _syncInsolvencyLatch(eq, gross, owed, index);

        uint256 recoveryIndex = epoch.recoveryIndex;
        address assetAddr = _asset();

        for (uint256 i = 0; i < claimIds.length;) {
            EpochQueueStorage.EpochClaim storage claim = eq.claims[epochId][claimIds[i]];
            if (claim.user == msg.sender && !claim.claimed) {
                uint256 assetsOwed = claim.assetsOwed;
                uint256 assets = _payoutAt(assetsOwed, recoveryIndex);
                claim.claimed = true;
                uint256 reservedBefore = eq.reservedForClaims;
                uint256 released = _settleClaimAccounting(eq, epoch, assetsOwed);
                assets = _coverPayout(assets, released, reservedBefore, totalAssets);
                totalAssets += assets;

                emit EpochAssetsClaimed(epochId, claimIds[i], msg.sender, assets, assetsOwed);
                emit IERC4626.Withdraw(
                    address(this), msg.sender, msg.sender, assets, claim.grossShares
                );
            }
            unchecked {
                ++i;
            }
        }

        if (totalAssets > 0) {
            IERC20(assetAddr).safeTransfer(msg.sender, totalAssets);
        }

        _exitNonReentrant();
    }

    /// @notice Permissionlessly settle funded claims directly to their recorded owners.
    /// @dev Already-settled and nonexistent claims are skipped. Self-claim remains available
    ///      and reverts if the claim has already been settled. This batch is atomic: a failed
    ///      transfer rolls back accounting and all transfers. Automation can retry claims
    ///      individually to isolate failures without marking an unpaid claim as settled.
    /// @return totalSettled Sum of underlying assets paid across the batch.
    function keeperSettleClaims(uint256 epochId, uint256[] calldata claimIds)
        external
        returns (uint256 totalSettled)
    {
        _notPausedFundedClaim();
        _enterNonReentrant();
        _rollCapEpochIfNeeded(CoreStorage.layout());

        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        EpochQueueStorage.EpochData storage epoch = eq.epochs[epochId];
        if (epoch.state != EpochQueueStorage.EpochState.Funded) revert EpochNotFunded();

        (uint256 gross, uint256 owed, uint256 index) = _navState();
        _syncInsolvencyLatch(eq, gross, owed, index);

        uint256 recoveryIndex = epoch.recoveryIndex;
        address assetAddr = _asset();

        for (uint256 i = 0; i < claimIds.length;) {
            EpochQueueStorage.EpochClaim storage claim = eq.claims[epochId][claimIds[i]];
            address user = claim.user;
            // user == address(0): claimId was never created for this epoch -- skip, rather
            // than let a bogus ID corrupt outstandingClaimCount/reservedForClaims bookkeeping.
            if (user != address(0) && !claim.claimed) {
                uint256 assetsOwed = claim.assetsOwed;
                uint256 assets = _payoutAt(assetsOwed, recoveryIndex);
                claim.claimed = true;
                uint256 reservedBefore = eq.reservedForClaims;
                uint256 released = _settleClaimAccounting(eq, epoch, assetsOwed);
                // Each claim pays a DIFFERENT recipient, so the transfer happens immediately
                // below rather than summed into one final transfer (unlike
                // batchClaimEpochAssets) -- paidSoFar is 0 every iteration because the hot
                // balance _coverPayout reads already reflects every prior transfer in this loop.
                assets = _coverPayout(assets, released, reservedBefore, 0);

                if (assets > 0) {
                    IERC20(assetAddr).safeTransfer(user, assets);
                }
                totalSettled += assets;

                emit EpochAssetsClaimed(epochId, claimIds[i], user, assets, assetsOwed);
                emit IERC4626.Withdraw(address(this), user, user, assets, claim.grossShares);
            }
            unchecked {
                ++i;
            }
        }

        _exitNonReentrant();
    }

    /// @dev Bookkeeping for one claim leaving the books. The claim releases its proportional
    ///      share of ITS OWN epoch's earmark (`reservedRemaining`), never another epoch's: the
    ///      earmark was crystallized at fund time (Option A) as exactly what was reserved for
    ///      the cohort, and a drained epoch releases exactly what it reserved.
    ///
    ///      totalOwed already had this cohort's haircut (if any) written off in one shot when
    ///      it was crystallized (fundEpoch's `writeOff`, see EpochRecoveryCrystallized) -- so
    ///      what remains in totalOwed for this claim is `released` (its share of the RECOVERED
    ///      pool), not the full nominal `assetsOwed`. Subtracting `assetsOwed` here would
    ///      double-count the haircut. `released == assetsOwed` exactly whenever the cohort
    ///      crystallized at 1e18 (solvent when funded), so this is a no-op change there.
    /// @return released liquidity this claim gives back from the earmark
    function _settleClaimAccounting(
        EpochQueueStorage.Layout storage eq,
        EpochQueueStorage.EpochData storage epoch,
        uint256 assetsOwed
    ) internal returns (uint256 released) {
        uint256 unclaimed = epoch.totalAssetsOwed - epoch.claimedAssets;
        uint256 rr = epoch.reservedRemaining;
        released = (unclaimed == 0 || assetsOwed >= unclaimed) ? rr : rr * assetsOwed / unclaimed;
        epoch.reservedRemaining = rr - released;

        epoch.claimedAssets += assetsOwed;
        eq.outstandingClaimCount -= 1;
        eq.fundedOutstandingClaimCount -= 1;
        eq.totalOwed -= released;
        uint256 reserved = eq.reservedForClaims;
        eq.reservedForClaims = reserved - (released < reserved ? released : reserved);
    }

    /// @dev A claim's crystallized payout (assetsOwed * epoch.recoveryIndex) can round to
    ///      fractionally more than its floor-proportional share of the earmark (`released`) --
    ///      two different rounding paths over the same pool, off by dust at worst. NOT a
    ///      recovery-after-funding case any more (Option A: a FUNDED epoch's earmark and
    ///      recoveryIndex are both immutable, fundEpoch() never tops one up). The gap, if any,
    ///      comes from FREE liquidity (hot net of every other epoch's earmark and of what this
    ///      same batch has already taken); if free liquidity is short by no more than the dust
    ///      tolerance the claim is paid what is available, beyond that it reverts and can be
    ///      retried once liquidity is back.
    function _coverPayout(
        uint256 payout,
        uint256 released,
        uint256 reservedBefore,
        uint256 paidSoFar
    ) internal view returns (uint256) {
        if (payout <= released) return payout;
        uint256 hot = IERC20(_asset()).balanceOf(address(this));
        uint256 committed = reservedBefore + paidSoFar;
        uint256 free = hot > committed ? hot - committed : 0;
        uint256 available = released + free;
        if (payout <= available) return payout;
        if (payout - available <= INSOLVENCY_FUNDING_ROUNDING) return available;
        revert InsufficientFreeLiquidity();
    }

    function _isInsolvent() internal view returns (bool) {
        return ICoreVault(address(this)).isInsolvent();
    }

    /// @dev Size an unfunded cohort from assets and liabilities net of funded reserves.
    function _scaledByIndex(uint256 nominal) internal view returns (uint256) {
        (uint256 gross, uint256 owed,) = _navState();
        uint256 reserved = EpochQueueStorage.layout().reservedForClaims;
        uint256 freeAssets = gross > reserved ? gross - reserved : 0;
        uint256 freeOwed = owed > reserved ? owed - reserved : 0;
        if (freeOwed == 0 || freeAssets >= freeOwed) return nominal;
        return FixedPoint.mulDivDown(nominal, freeAssets, freeOwed);
    }

    /// @dev Apply the cohort recovery index, rounding down to keep aggregate payouts covered.
    function _payoutAt(uint256 assetsOwed, uint256 index) internal pure returns (uint256) {
        return index >= FixedPoint.WAD ? assetsOwed : FixedPoint.mulWadDown(assetsOwed, index);
    }

    // =========================================================================
    // PERFORMANCE FEE CRYSTALLIZATION
    // =========================================================================
    // Performance fee crystallization uses active shareholder NAV.

    /// @notice End epoch and crystallize performance fee. Permissionless.
    function endEpochCrystallize() external {
        _notPausedEpochCloseFund();
        _crystallize();
        _updateNavSmooth();
    }

    function _pps() internal view returns (uint256) {
        uint256 ts = _totalSupply();
        return ts == 0 ? FixedPoint.WAD : FixedPoint.divWadDown(_totalAssets(), ts);
    }

    function _crystallize() internal returns (uint256 newHwm, uint256 feeAssets) {
        FeeStorage.Layout storage f = FeeStorage.layout();
        CoreStorage.Layout storage core = CoreStorage.layout();

        uint256 ts = _totalSupply();
        if (ts == 0) {
            // Escape-hatch guard: only reset the fee baseline to WAD when the vault
            // is genuinely empty (no residual/dust assets). If assets remain while
            // supply is zero (e.g. dust left after a full redemption), keep the
            // existing HWM -- otherwise a forced empty-then-refill cycle could wipe
            // an already fee-eligible high-water mark while value still sits in the
            // vault, letting fresh "profit" be recognised on value that was never
            // actually new.
            uint256 assetsNow = _totalAssets();
            if (assetsNow == 0) {
                // Genuine fresh start: reset the baseline and record the event.
                f.highWaterMark = FixedPoint.WAD;
                f.lastCrystallize = uint64(block.timestamp);
                emit Events.Crystallized(0, FixedPoint.WAD, 0);
                return (FixedPoint.WAD, 0);
            }
            // Dust present: preserve the existing baseline. This is a no-op (no
            // fee, no HWM change) so -- same reasoning as the drawdown branch
            // below -- lastCrystallize is deliberately left untouched, and the
            // storage slot is only written if it needs initialising.
            uint256 preserved = f.highWaterMark == 0 ? FixedPoint.WAD : f.highWaterMark;
            if (f.highWaterMark == 0) f.highWaterMark = preserved;
            emit Events.Crystallized(0, preserved, 0);
            return (preserved, 0);
        }

        uint256 pps = _pps();
        uint256 old = f.highWaterMark == 0 ? FixedPoint.WAD : f.highWaterMark;

        if (pps <= old) {
            // HWM is monotonically non-decreasing. Initialise the storage slot on
            // the very first crystallise (highWaterMark == 0 means "use WAD as
            // default" but the value is never persisted until here); otherwise
            // this write would just re-store the same value, so it's skipped.
            if (f.highWaterMark == 0) f.highWaterMark = old;
            // Deliberately NOT touching lastCrystallize here: this call is a no-op
            // (no profit crystallized). Since endEpochCrystallize() is ROLE_PUBLIC,
            // bumping the timer on every no-op call would let anyone repeatedly
            // push lastCrystallize forward for free, indefinitely delaying the next
            // legitimate (profitable) crystallization. The interval clock should
            // only advance on a real crystallization event.
            emit Events.Crystallized(old, pps, 0);
            return (old, 0);
        }

        // Interval guard: block fee extraction within the minimum crystallise interval.
        // Guard is skipped on the very first crystallise (highWaterMark == 0).
        uint64 minInterval = f.minCrystallizeInterval;
        if (
            f.highWaterMark != 0 && minInterval > 0
                && block.timestamp < uint256(f.lastCrystallize) + uint256(minInterval)
        ) {
            return (old, 0);
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
        bool initialized = (core.packedFlags & CoreStorage.FLAG_NAV_SMOOTH_INIT) != 0;

        if (!initialized) {
            core.navSmooth = navReal;
            core.lastNavSmoothUpdate = uint64(block.timestamp);
            core.packedFlags |= CoreStorage.FLAG_NAV_SMOOTH_INIT;
            emit Events.NavSmoothUpdated(navReal, navReal, block.timestamp);
            return;
        }

        if (block.timestamp < uint256(core.lastNavSmoothUpdate) + nsp.interval) {
            return;
        }

        uint256 alpha = nsp.alphaBps;
        uint256 newSmooth = (alpha * navReal + (10000 - alpha) * core.navSmooth) / 10000;

        core.navSmooth = newSmooth;
        core.lastNavSmoothUpdate = uint64(block.timestamp);

        emit Events.NavSmoothUpdated(navReal, newSmooth, block.timestamp);
    }

    // =========================================================================
    // INSTANT-CAP EPOCH ROLLOVER
    // =========================================================================

    /// @notice Permissionlessly roll the cap epoch and snapshot its asset base.
    /// @dev Asset- and supply-changing entrypoints call the same helper before mutation.
    function rollCapEpochIfNeeded() external {
        _rollCapEpochIfNeeded(CoreStorage.layout());
    }

    function _rollCapEpochIfNeeded(CoreStorage.Layout storage core) internal returns (bool rolled) {
        return ExitEngineLib.rollCapEpochIfNeeded(core);
    }

    // =========================================================================
    // INSTANT WITHDRAWAL (cap-gated)
    // =========================================================================

    /// @notice Immediate settlement for cap-eligible exits.
    /// @dev The tier is decided BEFORE crystallizing using a CONSERVATIVE,
    ///      pre-fee gross estimate: convertToAssets(shares) is monotonic and fee only shrinks
    ///      what is actually owed, so a pass here on the larger gross number always covers the
    ///      smaller exact assetsOwed _crystallizeExit produces. _crystallizeExit is then called
    ///      exactly ONCE, with the tier already fixed -- an instant request that falls back
    ///      settles at the STANDARD fee, never the instant one, and nothing downstream calls
    ///      convertToAssets again (spec §6.2: never re-price, never re-apply a fee).
    function requestInstantWithdrawal(uint256 shares)
        external
        returns (bool settledImmediately, uint256 epochId, uint256 claimId)
    {
        _checkStandardExitAllowed(FixedMaturityStorage.layout(), true);
        _enterNonReentrant();
        _rollCapEpochIfNeeded(CoreStorage.layout());

        if (shares == 0) revert ZeroAmount();

        CoreStorage.Layout storage core = CoreStorage.layout();
        IParamsProvider.WithdrawalParams memory wp = core.params.getWithdrawalParams(address(this));

        // Enforce the deposit lock before pricing.
        _requireNotLocked(wp);

        uint256 capRemaining = _epochCapRemaining(core, wp, core.capBaseSnapshot);

        // Decide the tier on a CONSERVATIVE pre-fee estimate -- before any pricing/burn.
        _trySoftRefreshWarmNav();
        _requireFreshNav();
        uint256 grossEstimate = _convertToAssets(shares);
        bool instantAllowed = core.packedFlags
                & (CoreStorage.FLAG_PAUSED_WITHDRAWALS | CoreStorage.FLAG_INSTANT_WITHDRAWAL_PAUSED)
            == 0;
        (bool instantOk, address assetAddr) =
            instantAllowed ? _canInstant(grossEstimate, capRemaining, core) : (false, address(0));

        // Price once, with the tier already decided. Nothing downstream re-prices.
        ExitEngineLib.ExitMode mode =
            instantOk ? ExitEngineLib.ExitMode.INSTANT : ExitEngineLib.ExitMode.STANDARD;
        (uint256 netShares, uint256 feeShares, uint256 assetsOwed) =
            _crystallizeExit(msg.sender, shares, mode);

        if (instantOk) {
            // Pay now; the liability is discharged in the same transaction.
            EpochQueueStorage.layout().totalOwed -= assetsOwed;
            IERC20(assetAddr).safeTransfer(msg.sender, assetsOwed);
            ExitEngineLib.consumeEpochCap(core, assetsOwed);

            emit Events.InstantExit(msg.sender, shares, assetsOwed, feeShares);

            settledImmediately = true;
            epochId = 0;
            claimId = 0;
        } else {
            // Fallback: record the already-priced liability in the current
            // bucket. Gated separately by the queued-request breaker
            // (owner-only, exceptional) so pausing instant
            // settlement alone never blocks this fallback, and so this entry
            // point can't be used to route around pauseQueuedRequestOnly().
            _notPausedQueuedRequest();
            _openEpochIfNeeded();
            (epochId, claimId) = _recordClaim(msg.sender, shares, netShares, feeShares, assetsOwed);
            settledImmediately = false;
        }

        _exitNonReentrant();
    }

    // =========================================================================
    // INSOLVENCY EVENT SYNC
    // =========================================================================

    /// @notice Permissionless: emit InsolvencyEntered / InsolvencyExited if the
    ///         derived insolvency state has changed since the last event.
    /// @dev Insolvency is DERIVED (grossAssets < totalOwed), never stored; this
    ///      only refreshes the event de-duplication latch. close/fund/claim run
    ///      the same sync, so a keeper poke is rarely needed.
    function syncInsolvencyState() external {
        _enterNonReentrant();
        _rollCapEpochIfNeeded(CoreStorage.layout());
        (uint256 gross, uint256 owed, uint256 index) = _navState();
        _syncInsolvencyLatch(EpochQueueStorage.layout(), gross, owed, index);
        _exitNonReentrant();
    }

    function _syncInsolvencyLatch(
        EpochQueueStorage.Layout storage eq,
        uint256 gross,
        uint256 owed,
        uint256 index
    ) internal {
        bool insolvent = gross < owed;
        if (insolvent && !eq.insolvencyLatched) {
            eq.insolvencyLatched = true;
            emit InsolvencyEntered(gross, owed, index);
        } else if (!insolvent && eq.insolvencyLatched) {
            eq.insolvencyLatched = false;
            emit InsolvencyExited(gross, owed);
        }
    }

    // =========================================================================
    // VIEW FUNCTIONS
    // =========================================================================

    function currentEpochId() external view returns (uint256) {
        return EpochQueueStorage.layout().currentEpochId;
    }

    /// @notice Claim count of the currently open epoch — used by keepers as an
    ///         anti-churn check before closeCurrentEpoch() (skip closing an
    ///         epoch with nothing in it).
    function currentEpochClaimCount() external view returns (uint256) {
        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        return eq.epochs[eq.currentEpochId].claimCount;
    }

    function epochData(uint256 epochId) external view returns (EpochQueueStorage.EpochData memory) {
        return EpochQueueStorage.layout().epochs[epochId];
    }

    function epochClaim(uint256 epochId, uint256 claimId)
        external
        view
        returns (EpochQueueStorage.EpochClaim memory)
    {
        return EpochQueueStorage.layout().claims[epochId][claimId];
    }

    function nextClaimIdForEpoch(uint256 epochId) external view returns (uint256) {
        return EpochQueueStorage.layout().nextClaimId[epochId];
    }

    /// @notice Total unclaimed claims across ALL epochs — the dynamic-cap
    ///         "queue depth" signal. See _epochCapRemaining().
    function outstandingClaimCount() external view returns (uint256) {
        return EpochQueueStorage.layout().outstandingClaimCount;
    }

    /// @notice Unclaimed claims in Funded epochs, including claims with zero recovery.
    function fundedOutstandingClaimCount() external view returns (uint256) {
        return EpochQueueStorage.layout().fundedOutstandingClaimCount;
    }

    /// @notice Number of epochs that have transitioned to Funded. Monotonically increasing.
    function fundedEpochCount() external view returns (uint256) {
        return EpochQueueStorage.layout().fundedEpochCount;
    }

    /// @notice Oldest epoch that is CLOSED but not yet FUNDED — what a keeper
    ///         should call fundEpoch() on next. Equal to currentEpochId() when
    ///         there is no funding backlog.
    function oldestUnfundedEpochId() external view returns (uint256) {
        return EpochQueueStorage.layout().oldestUnfundedEpochId;
    }

    /// @notice Returns the shortfall in hot assets to fund a specific epoch,
    ///         net of everything already reserved for other funded epochs --
    ///         matches fundEpoch()'s actual "needed" requirement.
    ///         Returns 0 if the epoch is already funded or fully covered.
    function epochDeficit(uint256 epochId) external view returns (uint256) {
        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        EpochQueueStorage.EpochData storage e = eq.epochs[epochId];
        if (e.state != EpochQueueStorage.EpochState.Closed) return 0;
        uint256 hot = IERC20(_asset()).balanceOf(address(this));
        uint256 needed = _scaledByIndex(e.totalAssetsOwed - e.claimedAssets) + eq.reservedForClaims;
        return hot < needed ? needed - hot : 0;
    }

    /// @notice Liquidity earmarked for FUNDED-but-unclaimed claims across ALL
    ///         funded epochs. This much of the hot balance is off-limits to
    ///         instant exits, strategy deploys, and funding any other epoch.
    ///         NOT subtracted from NAV: see totalOwed().
    function reservedForClaims() external view returns (uint256) {
        return EpochQueueStorage.layout().reservedForClaims;
    }

    /// @notice Returns true when the current open epoch can be closed.
    function canCloseCurrentEpoch() external view returns (bool) {
        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        EpochQueueStorage.EpochData storage e = eq.epochs[eq.currentEpochId];
        if (e.state != EpochQueueStorage.EpochState.Open) return false;
        if (e.openedAt == 0) return false;
        CoreStorage.Layout storage core = CoreStorage.layout();
        return block.timestamp >= e.openedAt + _minEpochDuration(core);
    }

    /// @dev Shared epoch-duration lookup. Unlike ExitEngineLib.rollEpochIfNeeded
    ///      (which enforces a deploy-time-set cap-epoch duration with no zero
    ///      fallback), this queue-settlement epoch duration is an operational
    ///      batching cadence, not a security gate -- a 1 day default is
    ///      intentional here if governance hasn't configured QueueParams.
    function _minEpochDuration(CoreStorage.Layout storage core) internal view returns (uint64) {
        IParamsProvider.QueueParams memory qp = core.params.getQueueParams(address(this));
        return qp.epochDuration > 0 ? qp.epochDuration : 1 days;
    }

    // =========================================================================
    // INTERNAL: VAULT INTERFACE (delegatecall context -- address(this) = CoreVault)
    // =========================================================================

    // NOTE: direct interface calls, not low-level staticcall/call +
    // abi.encodeWithSignature. Same external-call semantics (delegatecall
    // context means address(this) is still the vault), but the compiler
    // resolves the selector at compile time.
    function _asset() internal view returns (address) {
        return IERC4626(address(this)).asset();
    }

    /// @dev Class B: active shareholder NAV = max(0, grossAssets - totalOwed).
    function _totalAssets() internal view returns (uint256) {
        return IERC4626(address(this)).totalAssets();
    }

    function _totalSupply() internal view returns (uint256) {
        return IERC20(address(this)).totalSupply();
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        return IERC4626(address(this)).convertToAssets(shares);
    }

    /// @dev grossAssets, totalOwed and liabilityIndex from the ONE place that
    ///      defines them (CoreVault) -- this module never reconstructs them.
    function _navState() internal view returns (uint256 gross, uint256 owed, uint256 index) {
        return ICoreVault(address(this)).liabilityState();
    }

    function _transferShares(address from, address to, uint256 amount) internal {
        ICoreVault(address(this)).processorTransfer(from, to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        ICoreVault(address(this)).processorBurn(from, amount);
    }

    /// @dev Raw asset-to-share conversion WITHOUT deposit fee. Used for perf fee minting.
    function _previewDeposit(uint256 assets) internal view returns (uint256) {
        return IERC4626(address(this)).convertToShares(assets);
    }

    function _mint(address to, uint256 amount) internal {
        ICoreVault(address(this)).processorMint(to, amount);
    }

    // =========================================================================
    // INTERNAL: NAV FRESHNESS + INCENTIVES + REENTRANCY
    // =========================================================================

    /// @dev Requests require a complete, fresh warm cache, healthy readable strategies,
    ///      and any configured oracle input to pass the vault's NAV validity policy.
    function _requireFreshNav() internal view {
        (bool valid, uint8 reason) = ICoreVault(address(this)).navStatus();
        if (valid) return;
        if (reason == 3) revert NavStale();
        if (reason == 1 || reason == 2) revert NavInvalid();
        revert NavInputInvalid(reason);
    }

    /// @dev Best-effort refresh, GUARANTEED non-reverting -- identical pattern to
    ///      ERC4626Module._trySoftRefreshWarmNav(), used ahead of deposit/mint. If the
    ///      keeper is behind, this pays the ~800k gas to self-heal the cache in the same
    ///      transaction; if the refresh itself reverts (dead BufferManager, broken
    ///      adapter), it's swallowed and _requireFreshNav() right after this call is what
    ///      actually decides whether the request proceeds.
    function _trySoftRefreshWarmNav() internal {
        CoreStorage.Layout storage core = CoreStorage.layout();
        IBufferManager bm = core.bufferManager;
        if (address(bm) == address(0)) return;
        (, uint40 ts,) = bm.warmNavState();
        if (block.timestamp > ts + MAX_WARM_NAV_AGE) {
            try bm.refreshWarmNav() {} catch {}
        }
    }

    function _notifyIncentivesExit(
        address user,
        uint256 assetsExited,
        CoreStorage.Layout storage core
    ) internal {
        IIncentivesEngine eng = core.incentivesEngine;
        if (address(eng) == address(0)) return;
        try eng.onExitLight(user, assetsExited * 1e12) {} catch {}
    }

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

    // =========================================================================
    // INTERNAL: GRANULAR WITHDRAWAL BREAKERS
    // =========================================================================
    // Note: there is no _notPausedInstantWithdrawal() revert-style helper —
    // requestInstantWithdrawal() checks FLAG_INSTANT_WITHDRAWAL_PAUSED inline
    // and treats "paused" as "instant unavailable" (forcing its existing
    // queue-fallback branch) rather than reverting the whole call.

    /// @dev Deposit locks apply to both ordinary exit paths; force exit bypasses them.
    function _requireNotLocked(IParamsProvider.WithdrawalParams memory wp) internal view {
        if (
            wp.lockPeriod > 0
                && block.timestamp
                    < uint256(CoreStorage.layout().lastDepositTs[msg.sender]) + wp.lockPeriod
        ) {
            revert DepositLockActive();
        }
    }

    /// @dev Gates only the creation of NEW queued-exit requests.
    ///      Deliberately NOT included under FLAG_PAUSED_WITHDRAWALS: exit
    ///      *intent* must remain recordable even while settlement is paused
    ///      — only the dedicated, exceptional
    ///      pauseQueuedRequestOnly()/pauseAll() can reach this.
    function _notPausedQueuedRequest() internal view {
        if (CoreStorage.layout().packedFlags & CoreStorage.FLAG_QUEUED_REQUEST_PAUSED != 0) {
            revert QueuedRequestPaused();
        }
    }

    function _notPausedEpochCloseFund() internal view {
        uint256 flags = CoreStorage.layout().packedFlags;
        if (
            flags & (CoreStorage.FLAG_PAUSED_WITHDRAWALS | CoreStorage.FLAG_EPOCH_CLOSE_FUND_PAUSED)
                != 0
        ) {
            revert EpochCloseFundPaused();
        }
    }

    /// @dev Funded claims are permissionless. Deliberately NOT included under
    ///      FLAG_PAUSED_WITHDRAWALS or FLAG_PAUSED — only the dedicated,
    ///      exceptional pauseFundedClaimOnly() can reach this, never
    ///      pauseAll()/guardianPause()/pauseWithdrawalsOnly().
    function _notPausedFundedClaim() internal view {
        if (CoreStorage.layout().packedFlags & CoreStorage.FLAG_FUNDED_CLAIM_PAUSED != 0) {
            revert FundedClaimPaused();
        }
    }

    // =========================================================================
    // INTERNAL: INSTANT SETTLEMENT CHECK
    // =========================================================================

    /// @dev Returns the resolved asset address alongside the result so a
    ///      successful caller can reuse it instead of a second _asset() call.
    ///      `assetsOwed` is the request's fixed, already-priced amount;
    ///      `capRemaining` was read BEFORE the request moved the NAV.
    ///      Lock period violations revert upstream in
    ///      _requireNotLocked(), before either exit path reaches this point.
    ///      Liquidity waterfall is hot -> warm refill only, NEVER a strategy redeem -- the
    ///      instant bucket is architecturally backed by hot + warm. Not `view`
    ///      any more: a warm shortfall attempts one BufferManager.refill() call.
    function _canInstant(uint256 assetsOwed, uint256 capRemaining, CoreStorage.Layout storage core)
        internal
        returns (bool ok, address assetAddr)
    {
        // Epoch cap (class B -- how fast shareholders' equity can leave)
        if (assetsOwed > capRemaining) return (false, address(0));

        // Liquidity (class A) -- hot balance net of everything already
        // reserved for FUNDED-but-unclaimed epochs, saturating; an instant
        // exit must never dip into cash another epoch's claimants already own.
        assetAddr = _asset();
        uint256 reserved = EpochQueueStorage.layout().reservedForClaims;
        uint256 hot = IERC20(assetAddr).balanceOf(address(this));
        uint256 free = hot > reserved ? hot - reserved : 0;

        if (free < assetsOwed) {
            // Try to close the gap from the warm buffer only. Best-effort: a slippage
            // revert or any other failure just means instant isn't available this time,
            // exactly like today -- the request still succeeds via the queue fallback.
            IBufferManager bm = core.bufferManager;
            if (address(bm) != address(0)) {
                uint256 deficit = assetsOwed - free;
                try bm.refill(deficit) {} catch {}
                hot = IERC20(assetAddr).balanceOf(address(this));
                free = hot > reserved ? hot - reserved : 0;
            }
        }

        ok = free >= assetsOwed;
    }

    /// @dev Static cap on the epoch snapshot; dynamic parameters are ignored.
    function _epochCapRemaining(
        CoreStorage.Layout storage core,
        IParamsProvider.WithdrawalParams memory wp,
        uint256 totalAssets_
    ) internal view returns (uint256) {
        uint16 cap = wp.capPerEpochBps == 0 ? type(uint16).max : wp.capPerEpochBps;

        if (cap == type(uint16).max) return type(uint256).max;

        return WithdrawalCapLib.calculateCapRemaining(totalAssets_, cap, core.epochWithdrawn);
    }
}
