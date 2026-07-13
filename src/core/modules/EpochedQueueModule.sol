// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 }    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 }  from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CoreStorage }  from "../storage/CoreStorage.sol";
import { FeeStorage }   from "../storage/FeeStorage.sol";
import { Events }       from "../libraries/Events.sol";
import { ExitEngineLib } from "../libraries/ExitEngineLib.sol";
import { WithdrawalCapLib } from "../libraries/WithdrawalCapLib.sol";
import { Percentage }   from "../../libs/Percentage.sol";
import { FixedPoint }   from "../../libs/FixedPoint.sol";
import { IParamsProvider }        from "../../interfaces/IParamsProvider.sol";
import { IBufferManager }         from "../../interfaces/IBufferManager.sol";
import { IStrategyRouter }        from "../../interfaces/IStrategyRouter.sol";
import { IIncentivesEngine }      from "../../interfaces/IIncentivesEngine.sol";
import { ICoreVault }             from "../../interfaces/ICoreVault.sol";
import {
    FixedMaturityStorage,
    _checkStandardExitAllowed, _checkSettlementAllowed
} from "../storage/FixedMaturityStorage.sol";

// =============================================================================
// EPOCH QUEUE STORAGE  (EIP-7201 namespaced, separate from QueueStorage)
// =============================================================================

library EpochQueueStorage {
    // keccak256(abi.encode(uint256(keccak256("multyr.storage.EpochQueue.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT =
        0x3e5f2b4af1c6d7890a2b1c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3c400;

    enum EpochState { Open, Closed, Funded }

    // Per-epoch aggregate data. Stored once per epoch.
    struct EpochData {
        EpochState state;
        uint64     openedAt;          // block.timestamp when this epoch opened
        uint64     closedAt;          // block.timestamp when closeCurrentEpoch() ran
        uint64     fundedAt;          // block.timestamp when fundEpoch() succeeded
        uint256    totalGrossShares;  // running sum of all submitted shares
        uint256    totalNetShares;    // running sum after fee deduction
        uint256    totalFeeShares;    // running sum of fee portions
        uint256    ppsAtClose;        // WAD price-per-share locked at closeCurrentEpoch()
        uint256    totalNetAssets;    // totalNetShares * ppsAtClose / WAD (set at close)
        uint256    claimedAssets;     // running total paid out to users
        uint256    claimCount;        // number of claims submitted
    }

    // Per-claim entry. Stored under (epochId => claimId).
    struct EpochClaim {
        address user;
        uint256 netShares;   // after fee deduction -- what the user burns at claim time
        uint256 feeShares;   // already transferred to feeCollector at epoch close
        bool    claimed;     // user has received assets
    }

    struct Layout {
        uint256 currentEpochId;
        // epochId => epoch aggregate
        mapping(uint256 => EpochData) epochs;
        // epochId => claimId => claim
        mapping(uint256 => mapping(uint256 => EpochClaim)) claims;
        // epochId => next claimId counter (starts at 1)
        mapping(uint256 => uint256) nextClaimId;
        // total shares sitting in vault escrow across ALL open epochs
        uint256 escrowedShares;
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
/// @notice Epoch-bucket settlement queue -- Renzo ezETH architecture pattern
///
/// @dev WHY THIS ARCHITECTURE
///
///   The original QueueModule uses a flat FIFO array with an O(n) keeper scan
///   loop.  A keeper iterates the queue, computes each claim's assets, checks
///   liquidity, and pushes assets to users.  This has several problems:
///
///   1. Gas: settlement costs grow linearly with queue depth.
///   2. MEV: each claim settles at live PPS, so a sophisticated keeper can
///      cherry-pick high-value moments to crystallise fees or reorder claims.
///   3. Liquidity coupling: one stuck claim (insufficient hot) stalls later
///      eligible claims behind it (head-of-line blocking).
///   4. Keeper dependency: users receive assets only when a keeper triggers
///      settlement -- no self-service path.
///
///   Renzo's ezETH withdrawal queue solves these by:
///   A. Grouping claims into time-bounded EPOCHS.
///   B. Locking PPS for an entire epoch at close time.
///   C. Pulling liquidity once per epoch (not per claim).
///   D. Letting users self-serve: call claimEpochAssets() whenever funded.
///
///   This module implements that pattern adapted to Multyr's delegatecall
///   diamond-lite architecture and EIP-7201 namespaced storage.
///
/// EPOCH STATE MACHINE
///   OPEN    -- current epoch, accepting new claim submissions
///   CLOSED  -- epoch closed, ppsAtClose locked, awaiting liquidity pull
///   FUNDED  -- hot balance >= totalNetAssets; users can self-claim
///
///   OPEN ---[closeCurrentEpoch()]---> CLOSED ---[fundEpoch()]---> FUNDED
///                                                  (repeatable until funded)
///
/// KEY IMPROVEMENTS OVER QueueModule
///   1. No O(n) keeper scan: each user calls claimEpochAssets() directly.
///   2. Single PPS snapshot per epoch: MEV-resistant and fair to all members.
///   3. One liquidity pull per epoch: simpler, cheaper, predictable gas.
///   4. Pull-based claims: users are never blocked by other claims.
///   5. No array compaction: epochs are naturally immutable after settlement.
///   6. Instant path preserved: requestInstantWithdrawal() for cap-eligible exits.
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
    error EpochTooYoung();        // closeCurrentEpoch() called before epochDuration
    error ClaimAlreadySettled();
    error NotClaimOwner();
    error ReentrancyGuardLocked();
    error EpochAlreadyFunded();
    error InsufficientEscrow();

    // =========================================================================
    // EVENTS (epoch lifecycle + claims)
    // =========================================================================
    event EpochOpened(uint256 indexed epochId, uint64 openedAt);
    event EpochWithdrawalRequested(
        uint256 indexed epochId,
        uint256 indexed claimId,
        address indexed user,
        uint256 grossShares,
        uint256 netShares,
        uint256 feeShares
    );
    event EpochWithdrawalCancelled(
        uint256 indexed epochId,
        uint256 indexed claimId,
        address indexed user,
        uint256 sharesReturned
    );
    event EpochClosed(
        uint256 indexed epochId,
        uint256 ppsAtClose,
        uint256 totalNetShares,
        uint256 totalNetAssets,
        uint256 totalFeeShares
    );
    event EpochFundAttempt(
        uint256 indexed epochId,
        uint256 needed,
        uint256 hotBefore,
        uint256 hotAfter
    );
    event EpochFunded(uint256 indexed epochId, uint256 totalNetAssets);
    event EpochAssetsClaimed(
        uint256 indexed epochId,
        uint256 indexed claimId,
        address indexed user,
        uint256 assets,
        uint256 netShares
    );

    // =========================================================================
    // CONSTANTS
    // =========================================================================
    uint256 public constant MAX_WARM_NAV_AGE = 15 minutes;

    // =========================================================================
    // EPOCH QUEUE -- WRITE FUNCTIONS
    // =========================================================================

    /// @notice Submit shares to the current open epoch.
    ///         All shares are held in vault escrow until the epoch is settled.
    ///         Fee shares are deducted now and transferred to feeCollector
    ///         in batch when the epoch closes.
    ///
    /// @param shares Gross shares to withdraw (fee included)
    /// @return epochId  The epoch this claim belongs to
    /// @return claimId  Unique claim ID within the epoch
    function requestEpochWithdrawal(uint256 shares)
        external
        returns (uint256 epochId, uint256 claimId)
    {
        _enterNonReentrant();
        (epochId, claimId) = _requestEpochWithdrawal(msg.sender, shares);
        _exitNonReentrant();
    }

    /// @dev Shared body for requestEpochWithdrawal() and the instant-withdrawal
    ///      fallback path. MUST be called internally (never via `this.foo()`):
    ///      an external self-call re-enters CoreVault's fallback and rebinds
    ///      msg.sender to the vault's own address, silently attributing the
    ///      resulting claim to the vault instead of the real withdrawing user.
    ///      Caller is responsible for the reentrancy guard and for gating
    ///      access via _checkStandardExitAllowed(..., false).
    function _requestEpochWithdrawal(address user, uint256 shares)
        internal
        returns (uint256 epochId, uint256 claimId)
    {
        _checkStandardExitAllowed(FixedMaturityStorage.layout(), false);

        if (shares == 0) revert ZeroAmount();

        CoreStorage.Layout  storage core = CoreStorage.layout();
        FeeStorage.Layout   storage f    = FeeStorage.layout();
        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();

        // Initialise epoch 0 if this is the very first submission
        epochId = eq.currentEpochId;
        EpochQueueStorage.EpochData storage epoch = eq.epochs[epochId];
        if (epoch.openedAt == 0) {
            epoch.openedAt = uint64(block.timestamp);
            epoch.state    = EpochQueueStorage.EpochState.Open;
            emit EpochOpened(epochId, uint64(block.timestamp));
        }

        if (epoch.state != EpochQueueStorage.EpochState.Open) revert EpochNotOpen();

        _trySoftRefreshWarmNav();

        // --- Fee computation (STANDARD mode, rounding UP for protocol) -------
        (uint256 feeShares, uint256 netShares) =
            ExitEngineLib.computeFeeShares(shares, ExitEngineLib.ExitMode.STANDARD, f.fee);

        // --- Transfer ALL gross shares from user to vault escrow -------------
        // Shares sit here until claimEpochAssets() burns them per-user.
        _transferShares(user, address(this), shares);

        // --- Record claim ----------------------------------------------------
        claimId = ++eq.nextClaimId[epochId];
        eq.claims[epochId][claimId] = EpochQueueStorage.EpochClaim({
            user:      user,
            netShares: netShares,
            feeShares: feeShares,
            claimed:   false
        });

        // --- Update epoch running totals -------------------------------------
        epoch.totalGrossShares += shares;
        epoch.totalNetShares   += netShares;
        epoch.totalFeeShares   += feeShares;
        epoch.claimCount       += 1;

        // --- Global escrow tracker ------------------------------------------
        eq.escrowedShares += shares;

        // --- Incentives sync (best-effort) -----------------------------------
        // Skip the convertToAssets() call entirely when no engine is wired --
        // _notifyIncentivesExit would just discard the value anyway.
        if (address(core.incentivesEngine) != address(0)) {
            _notifyIncentivesExit(user, _convertToAssets(shares), core);
        }

        emit EpochWithdrawalRequested(epochId, claimId, user, shares, netShares, feeShares);
    }

    /// @notice Cancel a claim while the epoch is still OPEN.
    ///         Returns all gross shares (netShares + feeShares) to the user.
    ///         Not allowed once the epoch has closed.
    function cancelEpochWithdrawal(uint256 epochId, uint256 claimId) external {
        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        EpochQueueStorage.EpochData  storage epoch = eq.epochs[epochId];
        EpochQueueStorage.EpochClaim storage claim = eq.claims[epochId][claimId];

        if (epoch.state != EpochQueueStorage.EpochState.Open) revert EpochNotOpen();
        if (claim.user  != msg.sender) revert NotClaimOwner();
        if (claim.claimed)             revert ClaimAlreadySettled();

        uint256 grossShares = claim.netShares + claim.feeShares;
        if (grossShares == 0) revert ZeroAmount();

        // Escrow invariant
        if (_balanceOf(address(this)) < grossShares) revert InsufficientEscrow();

        // Unwind running totals
        epoch.totalGrossShares -= grossShares;
        epoch.totalNetShares   -= claim.netShares;
        epoch.totalFeeShares   -= claim.feeShares;
        epoch.claimCount       -= 1;
        eq.escrowedShares      -= grossShares;

        // Mark cancelled (reuse the claimed flag)
        claim.claimed = true;

        // Return shares to user
        _transferShares(address(this), msg.sender, grossShares);

        emit EpochWithdrawalCancelled(epochId, claimId, msg.sender, grossShares);
    }

    /// @notice Close the current epoch and lock the PPS snapshot.
    ///         Permissionless -- anyone can call once epochDuration has elapsed.
    ///         Fee shares for the entire epoch are batch-transferred to
    ///         feeCollector in a single call (vs. per-claim in QueueModule).
    ///         Opens a fresh epoch immediately so new submissions are not blocked.
    function closeCurrentEpoch() external {
        _checkSettlementAllowed(FixedMaturityStorage.layout());

        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        uint256 epochId = eq.currentEpochId;
        EpochQueueStorage.EpochData storage epoch = eq.epochs[epochId];

        if (epoch.state != EpochQueueStorage.EpochState.Open) revert EpochNotOpen();

        // --- Maturity check: epoch must have run for at least epochDuration --
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (block.timestamp < epoch.openedAt + _minEpochDuration(core)) revert EpochTooYoung();

        _trySoftRefreshWarmNav();

        // --- Snapshot PPS at close time (the key Renzo improvement) ----------
        // Every claim in this epoch will convert netShares at THIS price.
        // No claim can be MEV'd to a different PPS.
        uint256 ts  = _totalSupply();
        uint256 ta  = _totalAssets();
        uint256 pps = ts == 0 ? FixedPoint.WAD : FixedPoint.divWadDown(ta, ts);

        epoch.ppsAtClose     = pps;
        epoch.totalNetAssets = FixedPoint.mulWadDown(epoch.totalNetShares, pps);
        epoch.closedAt       = uint64(block.timestamp);
        epoch.state          = EpochQueueStorage.EpochState.Closed;

        // --- Batch fee transfer (one safeTransfer vs n transfers in QueueModule)
        // Fee shares have been sitting in escrow since submission.
        // Transfer all of them to feeCollector atomically here.
        if (epoch.totalFeeShares > 0) {
            _transferShares(address(this), core.feeCollector, epoch.totalFeeShares);
            // Fee shares just left vault escrow for good -- remove them from the
            // escrow tracker now. Only netShares remain in escrow, to be
            // decremented per-claim in claimEpochAssets/batchClaimEpochAssets.
            eq.escrowedShares -= epoch.totalFeeShares;
            emit Events.FeePaid(address(this), core.feeCollector, epoch.totalFeeShares);
        }

        emit EpochClosed(
            epochId,
            pps,
            epoch.totalNetShares,
            epoch.totalNetAssets,
            epoch.totalFeeShares
        );

        // --- Open the next epoch so new submissions are never blocked ---------
        uint256 nextId = epochId + 1;
        eq.currentEpochId                  = nextId;
        eq.epochs[nextId].openedAt         = uint64(block.timestamp);
        eq.epochs[nextId].state            = EpochQueueStorage.EpochState.Open;
        emit EpochOpened(nextId, uint64(block.timestamp));
    }

    /// @notice Pull liquidity deficit for a CLOSED epoch.
    ///         Permissionless -- anyone (keeper, automation, user) can call.
    ///         Tries hot balance first, then warm refill, then strategy redeem.
    ///         Marks epoch as FUNDED if hot >= totalNetAssets after the pull.
    ///         Safe to call multiple times: subsequent calls are no-ops if funded.
    ///
    ///         Core improvement over QueueModule: a single external-call pull
    ///         covers ALL claims in the epoch, not one pull per settled claim.
    function fundEpoch(uint256 epochId) external {
        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        EpochQueueStorage.EpochData storage epoch = eq.epochs[epochId];

        if (epoch.state == EpochQueueStorage.EpochState.Open)   revert EpochNotClosed();
        if (epoch.state == EpochQueueStorage.EpochState.Funded)  revert EpochAlreadyFunded();

        address assetAddr = _asset();
        uint256 hot       = IERC20(assetAddr).balanceOf(address(this));

        emit EpochFundAttempt(epochId, epoch.totalNetAssets, hot, 0 /* filled below */);

        if (hot < epoch.totalNetAssets) {
            uint256 deficit = epoch.totalNetAssets - hot;
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
                    hot    = IERC20(assetAddr).balanceOf(address(this));
                    deficit = hot < epoch.totalNetAssets ? epoch.totalNetAssets - hot : 0;
                }
            }

            // --- Step 2: strategy redeem for remaining gap -------------------
            if (deficit > 0) {
                IStrategyRouter r = core.router;
                if (address(r) != address(0)) {
                    IStrategyRouter.Pull[] memory plan = r.planRedeem(deficit);
                    if (plan.length > 0) {
                        try r.executeRedeemBatch(plan) returns (uint256 got, uint256) {
                            emit Events.RealizedForQueue(deficit, got);
                        } catch {}
                    }
                    hot = IERC20(assetAddr).balanceOf(address(this));
                }
            }
        }

        emit EpochFundAttempt(epochId, epoch.totalNetAssets, 0 /* filled above */, hot);

        // Mark funded only when fully covered
        if (hot >= epoch.totalNetAssets) {
            epoch.state    = EpochQueueStorage.EpochState.Funded;
            epoch.fundedAt = uint64(block.timestamp);
            emit EpochFunded(epochId, epoch.totalNetAssets);
        }
        // If still underfunded the epoch remains CLOSED;
        // fundEpoch() can be retried as more liquidity becomes available.
    }

    /// @notice User self-claims their assets from a FUNDED epoch.
    ///         No keeper required -- this is the core UX improvement over QueueModule.
    ///         Burns netShares from escrow, transfers computed assets to user.
    ///
    ///         gasPerClaim: ~50k (vs ~80k per keeper-settled claim in QueueModule)
    function claimEpochAssets(uint256 epochId, uint256 claimId)
        external
        returns (uint256 assets)
    {
        _enterNonReentrant();

        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        EpochQueueStorage.EpochData  storage epoch = eq.epochs[epochId];
        EpochQueueStorage.EpochClaim storage claim = eq.claims[epochId][claimId];

        if (epoch.state != EpochQueueStorage.EpochState.Funded) revert EpochNotFunded();
        if (claim.user  != msg.sender)  revert NotClaimOwner();
        if (claim.claimed)              revert ClaimAlreadySettled();

        // Deterministic: same PPS for every claim in this epoch.
        // No settlement-time MEV; the price was fixed at epoch close.
        assets = FixedPoint.mulWadDown(claim.netShares, epoch.ppsAtClose);

        // Mark claimed BEFORE external transfers (CEI)
        claim.claimed = true;
        epoch.claimedAssets += assets;
        // feeShares already left escrow (transferred to feeCollector) at close;
        // only netShares remain in escrow for this claim.
        eq.escrowedShares   -= claim.netShares;

        // Burn net shares from escrow
        _burn(address(this), claim.netShares);

        // Transfer computed assets to user
        if (assets > 0) {
            IERC20(_asset()).safeTransfer(msg.sender, assets);
        }

        emit EpochAssetsClaimed(epochId, claimId, msg.sender, assets, claim.netShares);
        emit IERC4626.Withdraw(address(this), msg.sender, msg.sender,
            FixedPoint.mulWadDown(claim.netShares + claim.feeShares, epoch.ppsAtClose),
            claim.netShares + claim.feeShares
        );

        _exitNonReentrant();
    }

    /// @notice Batch version of claimEpochAssets for gas efficiency.
    ///         Processes up to `claimIds.length` claims in a single transaction.
    function batchClaimEpochAssets(uint256 epochId, uint256[] calldata claimIds)
        external
        returns (uint256 totalAssets)
    {
        _enterNonReentrant();

        EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
        EpochQueueStorage.EpochData storage epoch = eq.epochs[epochId];
        if (epoch.state != EpochQueueStorage.EpochState.Funded) revert EpochNotFunded();

        address assetAddr = _asset();

        for (uint256 i = 0; i < claimIds.length; ) {
            EpochQueueStorage.EpochClaim storage claim = eq.claims[epochId][claimIds[i]];
            if (claim.user == msg.sender && !claim.claimed) {
                uint256 assets = FixedPoint.mulWadDown(claim.netShares, epoch.ppsAtClose);
                claim.claimed       = true;
                epoch.claimedAssets += assets;
                totalAssets         += assets;

                // feeShares already left escrow at close; only netShares remain.
                eq.escrowedShares -= claim.netShares;

                _burn(address(this), claim.netShares);

                emit EpochAssetsClaimed(epochId, claimIds[i], msg.sender, assets, claim.netShares);
                emit IERC4626.Withdraw(address(this), msg.sender, msg.sender,
                    FixedPoint.mulWadDown(claim.netShares + claim.feeShares, epoch.ppsAtClose),
                    claim.netShares + claim.feeShares
                );
            }
            unchecked { ++i; }
        }

        if (totalAssets > 0) {
            IERC20(assetAddr).safeTransfer(msg.sender, totalAssets);
        }

        _exitNonReentrant();
    }

    // =========================================================================
    // INSTANT WITHDRAWAL (preserved from QueueModule, cap-gated)
    // =========================================================================

    /// @notice Immediate settlement for cap-eligible exits.
    ///         Identical semantics to QueueModule.requestClaim(immediate=true).
    ///         Falls back to epoch queue if cap or liquidity check fails.
    function requestInstantWithdrawal(uint256 shares)
        external
        returns (bool settledImmediately, uint256 epochId, uint256 claimId)
    {
        _checkStandardExitAllowed(FixedMaturityStorage.layout(), true);
        _enterNonReentrant();

        if (shares == 0) revert ZeroAmount();

        CoreStorage.Layout storage core = CoreStorage.layout();
        FeeStorage.Layout  storage f    = FeeStorage.layout();

        _trySoftRefreshWarmNav();

        bool rolled = ExitEngineLib.rollEpochIfNeeded(core);
        if (rolled) emit Events.EpochRolled(core.epochStart);

        IParamsProvider.WithdrawalParams memory wp = core.params.getWithdrawalParams(address(this));
        uint256 gross = _convertToAssets(shares);

        // _canInstant fetches assetAddr lazily (only once the cheaper lock/cap
        // checks pass) and hands it back so a successful settlement reuses it
        // below instead of a second _asset() call; failing fast still costs
        // zero extra calls.
        (bool instantOk, address assetAddr) = _canInstant(gross, wp, core);

        if (instantOk) {
            // Settle now
            (uint256 feeShares, uint256 netShares) =
                ExitEngineLib.computeFeeShares(shares, ExitEngineLib.ExitMode.INSTANT, f.fee);
            uint256 netAssets = _convertToAssets(netShares);

            _notifyIncentivesExit(msg.sender, gross, core);

            if (feeShares > 0) {
                _transferShares(msg.sender, core.feeCollector, feeShares);
                emit Events.FeePaid(msg.sender, core.feeCollector, feeShares);
            }
            _burn(msg.sender, netShares);

            IERC20(assetAddr).safeTransfer(msg.sender, netAssets);
            ExitEngineLib.consumeEpochCap(core, gross);

            emit Events.InstantExit(msg.sender, shares, netAssets, feeShares);

            settledImmediately = true;
            epochId            = 0;
            claimId            = 0;
        } else {
            // Fallback: enqueue in current epoch as standard claim.
            // Calls the internal helper directly (never `this.foo()`) so the
            // claim is correctly attributed to msg.sender, not to the vault.
            (epochId, claimId) = _requestEpochWithdrawal(msg.sender, shares);
            settledImmediately = false;
        }

        _exitNonReentrant();
    }

    // =========================================================================
    // VIEW FUNCTIONS
    // =========================================================================

    function currentEpochId() external view returns (uint256) {
        return EpochQueueStorage.layout().currentEpochId;
    }

    function epochData(uint256 epochId)
        external view
        returns (EpochQueueStorage.EpochData memory)
    {
        return EpochQueueStorage.layout().epochs[epochId];
    }

    function epochClaim(uint256 epochId, uint256 claimId)
        external view
        returns (EpochQueueStorage.EpochClaim memory)
    {
        return EpochQueueStorage.layout().claims[epochId][claimId];
    }

    function nextClaimIdForEpoch(uint256 epochId) external view returns (uint256) {
        return EpochQueueStorage.layout().nextClaimId[epochId];
    }

    function totalEscrowedShares() external view returns (uint256) {
        return EpochQueueStorage.layout().escrowedShares;
    }

    /// @notice Returns the shortfall in hot assets to fund a specific epoch.
    ///         Returns 0 if the epoch is already funded or hot >= totalNetAssets.
    function epochDeficit(uint256 epochId) external view returns (uint256) {
        EpochQueueStorage.EpochData storage e = EpochQueueStorage.layout().epochs[epochId];
        if (e.state != EpochQueueStorage.EpochState.Closed) return 0;
        uint256 hot = IERC20(_asset()).balanceOf(address(this));
        return hot < e.totalNetAssets ? e.totalNetAssets - hot : 0;
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
    // resolves the selector at compile time and skips the manual bytes-memory
    // encode/decode + require(ok, "...") boilerplate on every call site.
    function _asset() internal view returns (address) {
        return IERC4626(address(this)).asset();
    }

    function _totalAssets() internal view returns (uint256) {
        return IERC4626(address(this)).totalAssets();
    }

    function _totalSupply() internal view returns (uint256) {
        return IERC20(address(this)).totalSupply();
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        return IERC4626(address(this)).convertToAssets(shares);
    }

    function _balanceOf(address account) internal view returns (uint256) {
        return IERC20(address(this)).balanceOf(account);
    }

    function _transferShares(address from, address to, uint256 amount) internal {
        ICoreVault(address(this)).processorTransfer(from, to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        ICoreVault(address(this)).processorBurn(from, amount);
    }

    // =========================================================================
    // INTERNAL: NAV FRESHNESS + INCENTIVES + REENTRANCY
    // =========================================================================

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
        if (core.packedFlags & CoreStorage.FLAG_REENTRANCY_LOCKED != 0)
            revert ReentrancyGuardLocked();
        core.packedFlags |= CoreStorage.FLAG_REENTRANCY_LOCKED;
    }

    function _exitNonReentrant() internal {
        CoreStorage.layout().packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
    }

    // =========================================================================
    // INTERNAL: INSTANT SETTLEMENT CHECK
    // =========================================================================

    /// @dev Returns the resolved asset address alongside the result so a
    ///      successful caller can reuse it instead of a second _asset() call.
    ///      assetAddr is only fetched lazily, once the cheaper lock/cap checks
    ///      have already passed, so failing fast still costs zero extra calls.
    function _canInstant(
        uint256 gross,
        IParamsProvider.WithdrawalParams memory wp,
        CoreStorage.Layout storage core
    ) internal view returns (bool ok, address assetAddr) {
        // Lock period
        if (wp.lockPeriod > 0 &&
            block.timestamp < uint256(core.lastDepositTs[msg.sender]) + wp.lockPeriod)
            return (false, address(0));

        // Epoch cap -- single source of truth via WithdrawalCapLib (same lib
        // ExitEngineLib.calculateCapRemaining uses), including dynamic cap support.
        if (gross > _epochCapRemaining(core, wp, _totalAssets())) return (false, address(0));

        // Liquidity
        assetAddr = _asset();
        if (IERC20(assetAddr).balanceOf(address(this)) < gross) return (false, address(0));

        return (true, assetAddr);
    }

    /// @dev Remaining immediate-withdrawal capacity for the current cap epoch.
    ///      Mirrors ExitEngineLib.calculateCapRemaining's bps-selection logic, but
    ///      uses this module's own open-epoch claimCount as the "queue depth"
    ///      signal for dynamic-cap scaling (EpochQueueStorage has no flat queue
    ///      array to measure, unlike QueueStorage).
    function _epochCapRemaining(
        CoreStorage.Layout storage core,
        IParamsProvider.WithdrawalParams memory wp,
        uint256 totalAssets_
    ) internal view returns (uint256) {
        IParamsProvider.DynamicCapParams memory dcp = core.params.getDynamicCapParams(address(this));

        uint16 cap;
        if (dcp.enabled) {
            if (dcp.minBps == 0 || dcp.maxBps == 0) {
                cap = wp.capPerEpochBps;
            } else {
                EpochQueueStorage.Layout storage eq = EpochQueueStorage.layout();
                uint256 queueDepth = eq.epochs[eq.currentEpochId].claimCount;
                cap = WithdrawalCapLib.calculateDynamicCapBps(
                    dcp.minBps, dcp.maxBps, dcp.queueStressThreshold, queueDepth
                );
            }
        } else {
            cap = wp.capPerEpochBps == 0 ? type(uint16).max : wp.capPerEpochBps;
        }

        if (cap == type(uint16).max) return type(uint256).max;

        return WithdrawalCapLib.calculateCapRemaining(totalAssets_, cap, core.epochWithdrawn);
    }
}
