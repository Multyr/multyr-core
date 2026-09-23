// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AutomationCompatibleInterface } from "./AutomationCompatibleInterface.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EpochQueueStorage } from "../core/modules/EpochedQueueModule.sol";

/// @notice Minimal interface for CoreVault + EpochedQueueModule (epoch-model queue) settlement.
interface IClaimSettlementTarget {
    function currentEpochId() external view returns (uint256);
    function nextClaimIdForEpoch(uint256 epochId) external view returns (uint256);
    function epochData(uint256 epochId) external view returns (EpochQueueStorage.EpochData memory);
    function epochClaim(uint256 epochId, uint256 claimId)
        external
        view
        returns (EpochQueueStorage.EpochClaim memory);
    function keeperSettleClaims(uint256 epochId, uint256[] calldata claimIds)
        external
        returns (uint256 totalSettled);
}

/// @title ClaimSettlementUpkeep
/// @notice Dedicated Chainlink Automation keeper that sweeps FUNDED epochs' unclaimed claims,
///         paying each one directly to its owner via EpochedQueueModule.keeperSettleClaims().
/// @dev Deliberately a SEPARATE contract from VaultUpkeep, not an added Op on it.
///
///      VaultUpkeep's checkUpkeep is a strict single-op-per-tick priority chain (EPOCH_FUND >
///      EPOCH_CLOSE > RECONCILE > CRYSTALLIZE > REBALANCE > STRATEGY_REBALANCE > DEPLOY >
///      REALIZE), each already carefully cooldown-/starvation-tuned against the others. Claim
///      settlement is a different SHAPE of work -- not "flip one vault-wide state machine
///      transition" but "drain a per-user, per-claim backlog that can span many claims across
///      many epochs, needing many consecutive ticks and its own pagination cursor." Slotting it
///      into that priority chain would either starve it (placed low, behind ops that fire most
///      cycles on an active vault) or destabilize the existing order (placed high). A separate
///      contract gets its own independent Chainlink Automation registration, tick cadence and
///      gas budget, and does not compete with vault-lifecycle upkeep for priority.
///
///      Self-claim (EpochedQueueModule.claimEpochAssets/batchClaimEpochAssets) remains the
///      permissionless fallback if this keeper is never run, lags, or is deliberately paused --
///      nothing here changes those paths, and a claim settled by either one is a no-op for the
///      other (idempotent on EpochClaim.claimed).
contract ClaimSettlementUpkeep is AutomationCompatibleInterface, Ownable {
    IClaimSettlementTarget public immutable target;

    /// @notice Max UNCLAIMED claims collected into one keeperSettleClaims() batch.
    uint256 public maxClaimsPerUpkeep = 20;
    /// @notice Max claim IDs examined per checkUpkeep() call, regardless of how many qualify --
    ///         bounds scan cost through a long run of already-claimed/excluded IDs.
    uint256 public maxScanPerUpkeep = 200;

    /// @notice Pagination cursor: the next claim ID to examine within cursorEpochId. Only ever
    ///         advances forward -- a settlement epoch's claim set is final once it is Funded
    ///         (EpochedQueueModule never adds claims to a closed epoch), so nothing here is
    ///         ever re-scanned once passed.
    uint256 public cursorEpochId;
    uint256 public cursorClaimId = 1;

    /// @notice Governance escape hatch: a claim whose owner cannot receive the asset (e.g. a
    ///         contract that reverts on transfer) would otherwise block every batch it's
    ///         bundled into forever, atomically, at every retry (keeperSettleClaims is
    ///         all-or-nothing by design -- see its own docs for why). Excluding it here lets
    ///         the cursor advance past it; the excluded user can still self-claim if their
    ///         address is later able to receive the asset -- exclusion only affects this
    ///         keeper's scan, not the module's claim functions.
    mapping(uint256 => mapping(uint256 => bool)) public excluded;

    event UpkeepPerformed(uint256 indexed epochId, uint256 claimCount, uint256 totalSettled, bool success);
    event ClaimExcluded(uint256 indexed epochId, uint256 indexed claimId, bool excludedNow);
    event CursorSet(uint256 epochId, uint256 claimId);
    event BatchSizeConfigured(uint256 maxClaimsPerUpkeep, uint256 maxScanPerUpkeep);

    error BadBatchSize();

    constructor(address target_) {
        require(target_ != address(0), "target=0");
        target = IClaimSettlementTarget(target_);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // checkUpkeep / performUpkeep
    // ═══════════════════════════════════════════════════════════════════════════════

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        (uint256 epochId, uint256[] memory claimIds, uint256 nextEpochId, uint256 nextClaimId) = _scan();
        if (claimIds.length == 0) return (false, bytes(""));
        return (true, abi.encode(epochId, claimIds, nextEpochId, nextClaimId));
    }

    function performUpkeep(bytes calldata performData) external override {
        (uint256 epochId, uint256[] memory claimIds, uint256 nextEpochId, uint256 nextClaimId) =
            abi.decode(performData, (uint256, uint256[], uint256, uint256));

        bool success;
        uint256 totalSettled;
        // Atomic: keeperSettleClaims() itself never swallows a failed transfer (fund-loss risk
        // if it did -- see its own docs). This try/catch is the automation-layer liveness
        // pattern VaultUpkeep already uses for every op: a revert here just means "nothing to
        // do this tick," not a contract-level panic.
        try target.keeperSettleClaims(epochId, claimIds) returns (uint256 settled) {
            success = true;
            totalSettled = settled;
        } catch {}

        emit UpkeepPerformed(epochId, claimIds.length, totalSettled, success);

        if (success) {
            // Advance past exactly what checkUpkeep() actually scanned -- not merely past the
            // last claim ID collected, so a scan that stopped on maxScanPerUpkeep (not
            // maxClaimsPerUpkeep) doesn't force re-examining already-checked, non-qualifying
            // IDs next tick.
            cursorEpochId = nextEpochId;
            cursorClaimId = nextClaimId;
        }
        // On failure the cursor is left exactly where it was: the same batch is retried next
        // tick. A transient liquidity shortfall self-heals; a permanently poisoned claim needs
        // excludeClaim() from the owner to unblock the cursor.
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Scan
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Walks forward from (cursorEpochId, cursorClaimId), collecting unclaimed claim IDs
    ///      from the FIRST epoch that has any, up to maxClaimsPerUpkeep, stopping at the
    ///      currently OPEN settlement epoch (never Funded, so never itself a source of claims)
    ///      or once maxScanPerUpkeep IDs have been examined. keeperSettleClaims() only accepts
    ///      one epochId per call, so a batch never spans two epochs even if both have room.
    function _scan()
        internal
        view
        returns (uint256 epochId, uint256[] memory claimIds, uint256 nextEpochId, uint256 nextClaimId)
    {
        uint256 openEpoch = target.currentEpochId();
        uint256 eId = cursorEpochId;
        uint256 cId = cursorClaimId;
        uint256 scanned;
        uint256 found;
        uint256 targetEpoch = type(uint256).max;
        uint256[] memory buf = new uint256[](maxClaimsPerUpkeep);

        while (eId <= openEpoch && scanned < maxScanPerUpkeep && found < maxClaimsPerUpkeep) {
            EpochQueueStorage.EpochData memory epoch = target.epochData(eId);
            if (epoch.state != EpochQueueStorage.EpochState.Funded) {
                // Open or Closed-but-unfunded: nothing payable here yet. Move on -- if this
                // epoch funds later, the cursor having passed it is fine, since its claims are
                // still there waiting; but a keeper only advances past a FUNDED epoch below
                // (targetEpoch != type(uint256).max branch), so a not-yet-Funded epoch is
                // re-examined every scan until it funds, at negligible cost (one epochData read).
                if (targetEpoch != type(uint256).max) break; // don't cross into another epoch mid-batch
                eId += 1;
                cId = 1;
                continue;
            }

            uint256 lastClaimId = target.nextClaimIdForEpoch(eId);
            if (cId > lastClaimId) {
                if (targetEpoch != type(uint256).max) break; // batch's epoch is exhausted -- stop, don't cross over
                eId += 1;
                cId = 1;
                continue;
            }

            EpochQueueStorage.EpochClaim memory claim = target.epochClaim(eId, cId);
            scanned += 1;
            if (!claim.claimed && claim.user != address(0) && !excluded[eId][cId]) {
                targetEpoch = eId;
                buf[found] = cId;
                found += 1;
            }
            cId += 1;
        }

        nextEpochId = eId;
        nextClaimId = cId;
        if (found == 0) return (0, new uint256[](0), nextEpochId, nextClaimId);

        epochId = targetEpoch;
        claimIds = new uint256[](found);
        for (uint256 i; i < found; ++i) claimIds[i] = buf[i];
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Owner controls
    // ═══════════════════════════════════════════════════════════════════════════════

    function setBatchSizes(uint256 maxClaimsPerUpkeep_, uint256 maxScanPerUpkeep_) external onlyOwner {
        if (maxClaimsPerUpkeep_ == 0 || maxScanPerUpkeep_ == 0 || maxScanPerUpkeep_ < maxClaimsPerUpkeep_) {
            revert BadBatchSize();
        }
        maxClaimsPerUpkeep = maxClaimsPerUpkeep_;
        maxScanPerUpkeep = maxScanPerUpkeep_;
        emit BatchSizeConfigured(maxClaimsPerUpkeep_, maxScanPerUpkeep_);
    }

    function excludeClaim(uint256 epochId, uint256 claimId, bool excludedNow) external onlyOwner {
        excluded[epochId][claimId] = excludedNow;
        emit ClaimExcluded(epochId, claimId, excludedNow);
    }

    /// @notice Manual cursor recovery (e.g. to re-scan after excluding a claim that was
    ///         blocking progress, or to skip ahead). Never required in normal operation.
    function setCursor(uint256 epochId, uint256 claimId) external onlyOwner {
        require(claimId > 0, "claimId=0");
        cursorEpochId = epochId;
        cursorClaimId = claimId;
        emit CursorSet(epochId, claimId);
    }
}
