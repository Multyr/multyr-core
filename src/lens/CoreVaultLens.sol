// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IStrategyRouter, IStrategy } from "../interfaces/IStrategyRouter.sol";
import { IStrategyHealthRegistry } from "../interfaces/IStrategyHealthRegistry.sol";
import { IBufferManager } from "../interfaces/IBufferManager.sol";
import { IIncentives } from "../interfaces/IIncentives.sol";
import { IParamsProvider } from "../interfaces/IParamsProvider.sol";
import { Percentage } from "../libs/Percentage.sol";
import { FixedPoint } from "../libs/FixedPoint.sol";
import { WithdrawalCapLib } from "../core/libraries/WithdrawalCapLib.sol";
import { EpochQueueStorage } from "../core/modules/EpochedQueueModule.sol";

interface ICoreVaultLensTarget {
    function asset() external view returns (address);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function router() external view returns (IStrategyRouter);
    function bufferManager() external view returns (IBufferManager);
    function healthRegistry() external view returns (IStrategyHealthRegistry);
    function incentives() external view returns (IIncentives);
    function params() external view returns (IParamsProvider);
    function navSmooth() external view returns (uint256);
    function navSmoothInitialized() external view returns (bool);
    function epochWithdrawn() external view returns (uint256);
    function perf()
        external
        view
        returns (uint256 hwm, uint256 rateX, uint64 minInterval, uint64 last, bool init);
    function fee()
        external
        view
        returns (uint16 depBps, uint16 witBps, address treasury, bool recipientFrozen);

    // Epoch-model queue (EpochedQueueModule, delegatecall-dispatched)
    function currentEpochId() external view returns (uint256);
    function currentEpochClaimCount() external view returns (uint256);
    function canCloseCurrentEpoch() external view returns (bool);
    function oldestUnfundedEpochId() external view returns (uint256);
    function outstandingClaimCount() external view returns (uint256);
    function nextClaimIdForEpoch(uint256 epochId) external view returns (uint256);
    function totalEscrowedShares() external view returns (uint256);
    function reservedForClaims() external view returns (uint256);
    function closedPendingAssets() external view returns (uint256);
    function epochData(uint256 epochId) external view returns (EpochQueueStorage.EpochData memory);
    function epochClaim(uint256 epochId, uint256 claimId)
        external
        view
        returns (EpochQueueStorage.EpochClaim memory);
}

contract CoreVaultLens {
    function pps(address vault) public view returns (uint256) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        uint256 ts = v.totalSupply();
        return ts == 0 ? FixedPoint.WAD : FixedPoint.divWadDown(v.totalAssets(), ts);
    }

    function previewPPSPostDepositFee(address vault, uint256 a) external view returns (uint256) {
        if (a == 0) return pps(vault);
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        (uint16 depBps,,,) = v.fee();
        uint256 feeA = Percentage.mulBpsDown(a, depBps);
        uint256 net = a - feeA;
        uint256 ns = v.totalSupply() + v.previewDeposit(a);
        return ns == 0 ? 1e18 : ((v.totalAssets() + net) * 1e18) / ns;
    }

    function previewPPSPostWithdrawFee(address vault, uint256 a) external view returns (uint256) {
        if (a == 0) return pps(vault);
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        uint256 ns = v.totalSupply() - v.previewWithdraw(a);
        uint256 ta = v.totalAssets();
        return ns == 0 ? 1e18 : ((ta > a ? ta - a : 0) * 1e18) / ns;
    }

    function totalAssetsStrict(address vault) external view returns (uint256) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        uint256 hot = IERC20(v.asset()).balanceOf(vault);
        uint256 strat = 0;
        IStrategyRouter r = v.router();
        if (address(r) != address(0)) {
            IStrategyRouter.StrategyInfo[] memory L = r.list();
            for (uint256 i = 0; i < L.length; ++i) {
                if (!L[i].enabled) continue;
                strat += IStrategy(L[i].strat).totalAssets();
            }
        }
        uint256 warm = 0;
        IBufferManager bm = v.bufferManager();
        if (address(bm) != address(0)) warm = bm.warmBalance();
        return hot + strat + warm;
    }

    function totalAssetsSafe(address vault) external view returns (uint256) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        uint256 hot = IERC20(v.asset()).balanceOf(vault);
        uint256 strat = 0;
        IStrategyRouter r = v.router();
        IStrategyHealthRegistry hr = v.healthRegistry();
        if (address(r) != address(0)) {
            IStrategyRouter.StrategyInfo[] memory L = r.list();
            for (uint256 i = 0; i < L.length; ++i) {
                if (!L[i].enabled) continue;
                try IStrategy(L[i].strat).totalAssets{ gas: 2000000 }() returns (uint256 ta) {
                    strat += ta;
                } catch {
                    if (address(hr) != address(0)) {
                        strat += hr.getStrategyHealth(L[i].strat).lastKnownNAV;
                    }
                }
            }
        }
        uint256 warm = 0;
        IBufferManager bm = v.bufferManager();
        if (address(bm) != address(0)) {
            try bm.warmBalance{ gas: 100000 }() returns (uint256 wb) {
                warm = wb;
            } catch { }
        }
        return hot + strat + warm;
    }

    function totalAssetsExcludingBroken(address vault) external view returns (uint256) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        uint256 hot = IERC20(v.asset()).balanceOf(vault);
        uint256 strat = 0;
        IStrategyRouter r = v.router();
        IStrategyHealthRegistry hr = v.healthRegistry();
        if (address(r) != address(0)) {
            IStrategyRouter.StrategyInfo[] memory L = r.list();
            for (uint256 i = 0; i < L.length; ++i) {
                if (!L[i].enabled) continue;
                if (
                    address(hr) != address(0)
                        && hr.getStrategyState(L[i].strat)
                            == IStrategyHealthRegistry.StrategyState.BROKEN
                ) continue;
                try IStrategy(L[i].strat).totalAssets{ gas: 2000000 }() returns (uint256 ta) {
                    strat += ta;
                } catch {
                    if (address(hr) != address(0)) {
                        strat += hr.getStrategyHealth(L[i].strat).lastKnownNAV;
                    }
                }
            }
        }
        uint256 warm = 0;
        IBufferManager bm = v.bufferManager();
        if (address(bm) != address(0)) {
            try bm.warmBalance{ gas: 100000 }() returns (uint256 wb) {
                warm = wb;
            } catch { }
        }
        return hot + strat + warm;
    }

    function totalAssetsSmooth(address vault) external view returns (uint256) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        IParamsProvider.NavSmoothingParams memory p = v.params().getNavSmoothingParams(vault);
        return (!p.enabled || !v.navSmoothInitialized()) ? v.totalAssets() : v.navSmooth();
    }

    function getEffectiveCapBps(address vault) external view returns (uint16) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        IParamsProvider pp = v.params();
        IParamsProvider.DynamicCapParams memory d = pp.getDynamicCapParams(vault);
        if (!d.enabled) return pp.getWithdrawalParams(vault).capPerEpochBps;
        return _calculateDynamicCapBps(vault);
    }

    function _calculateDynamicCapBps(address vault) internal view returns (uint16) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        IParamsProvider pp = v.params();
        IParamsProvider.DynamicCapParams memory d = pp.getDynamicCapParams(vault);
        if (d.minBps == 0 || d.maxBps == 0) return pp.getWithdrawalParams(vault).capPerEpochBps;
        // Must match EpochedQueueModule._epochCapRemaining()'s signal exactly —
        // outstandingClaimCount (cross-epoch total), not a per-epoch count —
        // otherwise this preview would show a different cap than the vault enforces.
        uint256 queueDepth = v.outstandingClaimCount();
        return
            WithdrawalCapLib.calculateDynamicCapBps(
                d.minBps, d.maxBps, d.queueStressThreshold, queueDepth
            );
    }

    function calculateCapImmediateRemaining(address vault) external view returns (uint256) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        IParamsProvider pp = v.params();
        IParamsProvider.WithdrawalParams memory wp = pp.getWithdrawalParams(vault);
        IParamsProvider.DynamicCapParams memory dcp = pp.getDynamicCapParams(vault);
        uint16 cap = dcp.enabled
            ? _calculateDynamicCapBps(vault)
            : (wp.capPerEpochBps == 0 ? type(uint16).max : wp.capPerEpochBps);
        if (cap == type(uint16).max) return type(uint256).max;
        uint256 m = Percentage.mulBpsDown(v.totalAssets(), cap);
        uint256 ew = v.epochWithdrawn();
        return m > ew ? m - ew : 0;
    }

    /// @notice True if there's epoch-queue work: a closeable non-empty open
    ///         epoch, or a closed-but-unfunded backlog. Mirrors CoreVault.canSettle().
    function canSettle(address vault) external view returns (bool) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        if (v.canCloseCurrentEpoch() && v.currentEpochClaimCount() > 0) return true;
        return v.oldestUnfundedEpochId() < v.currentEpochId();
    }

    function canCrystallize(address vault) external view returns (bool) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        (uint256 hwm, uint256 rateX, uint64 minInterval, uint64 last, bool init) = v.perf();
        if (!init) return true;
        if (block.timestamp < uint256(last) + uint256(minInterval)) return false;
        return pps(vault) > hwm;
    }

    function canRealize(address vault) external view returns (bool) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        IBufferManager bm = v.bufferManager();
        IStrategyRouter r = v.router();
        if (address(bm) == address(0)) return false;
        uint16 t = bm.getConfig().opsReserveTargetBps;
        if (t == 0 || address(r) == address(0)) return false;
        return IERC20(v.asset()).balanceOf(vault) < Percentage.mulBpsDown(v.totalAssets(), t);
    }

    /// @notice Fetch a single claim within a specific epoch (claim IDs restart
    ///         at 1 per epoch in the epoch model — there is no single global ID).
    function getEpochClaim(address vault, uint256 epochId, uint256 claimId)
        external
        view
        returns (address user, uint256 netShares, bool claimed)
    {
        EpochQueueStorage.EpochClaim memory c = ICoreVaultLensTarget(vault).epochClaim(epochId, claimId);
        return (c.user, c.netShares, c.claimed);
    }

    /// @notice Scan a caller-supplied epoch range for a user's claims. Bounded
    ///         by the caller (not the whole vault history) — an indexer/frontend
    ///         already knows which epochs a user interacted with from
    ///         EpochWithdrawalRequested events, so this avoids an unbounded
    ///         full-history scan that only grows over the vault's lifetime.
    function getUserEpochClaims(address vault, address user, uint256 fromEpoch, uint256 toEpoch)
        external
        view
        returns (uint256[] memory epochIds, uint256[] memory claimIds)
    {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        uint256 count;
        for (uint256 e = fromEpoch; e <= toEpoch; ++e) {
            uint256 nextId = v.nextClaimIdForEpoch(e);
            for (uint256 c = 1; c <= nextId; ++c) {
                if (v.epochClaim(e, c).user == user) count++;
            }
        }
        epochIds = new uint256[](count);
        claimIds = new uint256[](count);
        uint256 j;
        for (uint256 e = fromEpoch; e <= toEpoch; ++e) {
            uint256 nextId = v.nextClaimIdForEpoch(e);
            for (uint256 c = 1; c <= nextId; ++c) {
                if (v.epochClaim(e, c).user == user) {
                    epochIds[j] = e;
                    claimIds[j] = c;
                    j++;
                }
            }
        }
    }

    function pendingLoyaltyBonus(address vault, address user) external view returns (uint256) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        IIncentives inc = v.incentives();
        if (address(inc) == address(0)) return 0;
        try inc.pendingBonus(user) returns (uint256 b) {
            return b;
        } catch {
            return 0;
        }
    }

    function loyaltyVestingsCount(address vault, address user) external view returns (uint256) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        IIncentives inc = v.incentives();
        if (address(inc) == address(0)) return 0;
        try inc.vestingsCount(user) returns (uint256 c) {
            return c;
        } catch {
            return 0;
        }
    }

    function vestedLoyaltyAvailable(address vault, address user, uint256 idx)
        external
        view
        returns (uint256)
    {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        IIncentives inc = v.incentives();
        if (address(inc) == address(0)) return 0;
        try inc.vestedAvailable(user, idx) returns (uint256 a) {
            return a;
        } catch {
            return 0;
        }
    }

    struct VaultReport {
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 pricePerShare;
        uint256 availableLiquidity;
        uint256 pendingWithdrawals;
        uint256 capRemaining;
        uint256 outstandingClaims;
        bool canSettleNow;
        bool canCrystallizeNow;
    }

    function getVaultReport(address vault) external view returns (VaultReport memory r) {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        r.totalAssets = v.totalAssets();
        r.totalSupply = v.totalSupply();
        r.pricePerShare = pps(vault);
        r.availableLiquidity = IERC20(v.asset()).balanceOf(vault);
        // Exact, O(1): the still-open epoch's shares haven't locked a pps yet
        // (valued live), while closed/funded epochs' liabilities are already
        // locked-pps-correct by construction (see EpochQueueStorage.Layout).
        // Replaces the old convertToAssets(totalEscrowedShares()) approximation,
        // which priced ALL escrowed shares (including already-locked ones) at
        // the CURRENT live pps -- wrong whenever pps moved since a closed
        // epoch's ppsAtClose.
        EpochQueueStorage.EpochData memory openEpoch = v.epochData(v.currentEpochId());
        r.pendingWithdrawals = v.convertToAssets(openEpoch.totalNetShares)
            + v.closedPendingAssets()
            + v.reservedForClaims();
        r.capRemaining = this.calculateCapImmediateRemaining(vault);
        r.outstandingClaims = v.outstandingClaimCount();
        r.canSettleNow = this.canSettle(vault);
        r.canCrystallizeNow = this.canCrystallize(vault);
    }

    struct UserReport {
        uint256 shares;
        uint256 assetsValue;
        uint256 pendingClaims;
        uint256 pendingBonus;
    }

    /// @param fromEpoch/toEpoch bounds the epoch scan for pendingClaims — see
    ///        getUserEpochClaims() for why this isn't a full-history scan.
    function getUserReport(address vault, address user, uint256 fromEpoch, uint256 toEpoch)
        external
        view
        returns (UserReport memory r)
    {
        ICoreVaultLensTarget v = ICoreVaultLensTarget(vault);
        r.shares = v.balanceOf(user);
        r.assetsValue = v.convertToAssets(r.shares);
        (uint256[] memory epochIds, uint256[] memory claimIds) =
            this.getUserEpochClaims(vault, user, fromEpoch, toEpoch);
        // A closed/funded epoch pays at its own locked ppsAtClose, not live
        // pps -- cache the last epoch fetched since claims are usually
        // grouped by epoch, to avoid refetching per claim.
        uint256 cachedEpochId;
        EpochQueueStorage.EpochData memory cachedEpoch;
        bool haveCached;
        for (uint256 i = 0; i < claimIds.length; ++i) {
            EpochQueueStorage.EpochClaim memory c = v.epochClaim(epochIds[i], claimIds[i]);
            if (c.claimed) continue;
            if (!haveCached || cachedEpochId != epochIds[i]) {
                cachedEpoch = v.epochData(epochIds[i]);
                cachedEpochId = epochIds[i];
                haveCached = true;
            }
            r.pendingClaims += cachedEpoch.state == EpochQueueStorage.EpochState.Open
                ? v.convertToAssets(c.netShares)
                : FixedPoint.mulWadDown(c.netShares, cachedEpoch.ppsAtClose);
        }
        r.pendingBonus = this.pendingLoyaltyBonus(vault, user);
    }
}
