// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AutomationCompatibleInterface} from "./AutomationCompatibleInterface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EpochQueueStorage} from "../core/modules/EpochedQueueModule.sol";

/// @notice Minimal interface for CoreVault + EpochedQueueModule (epoch-model queue) settlement.
interface IClaimSettlementTarget {
    function outstandingClaimCount() external view returns (uint256);
    function fundedOutstandingClaimCount() external view returns (uint256);
    function pausedFundedClaim() external view returns (bool);
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
/// @dev Uses a bounded circular scan. Cursor state is computed from the target, never caller data.
contract ClaimSettlementUpkeep is AutomationCompatibleInterface, Ownable, ReentrancyGuard {
    IClaimSettlementTarget public immutable target;

    /// @notice Max UNCLAIMED claims collected into one keeperSettleClaims() batch.
    uint256 public maxClaimsPerUpkeep = 20;
    /// @notice Maximum epoch/claim probes in one bounded scan.
    uint256 public maxScanPerUpkeep = 200;

    /// @notice Circular scan position. Wrapping revisits unfunded and retryable claims.
    uint256 public cursorEpochId;
    uint256 public cursorClaimId = 1;

    /// @notice Optional owner exclusion from automated settlement. Self-claim remains available.
    mapping(uint256 => mapping(uint256 => bool)) public excluded;

    event UpkeepPerformed(
        uint256 indexed epochId, uint256 claimCount, uint256 totalSettled, bool success
    );
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

    uint256 public constant RETRY_DELAY = 1 hours;
    uint256 public nextAttemptAt;
    mapping(uint256 => mapping(uint256 => uint256)) public retryAfter;
    event ClaimSettlementFailed(uint256 indexed epochId, uint256 indexed claimId, uint256 retryAt);

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (
            target.outstandingClaimCount() == 0 || target.fundedOutstandingClaimCount() == 0
                || target.pausedFundedClaim() || block.timestamp < nextAttemptAt
        ) {
            return (false, bytes(""));
        }
        (
            uint256 epochId,
            uint256[] memory ids,
            uint256 nextEpoch,
            uint256 nextClaim,
            bool maintenance
        ) = _scan();
        return (ids.length != 0 || maintenance, abi.encode(epochId, ids, nextEpoch, nextClaim));
    }

    function performUpkeep(bytes calldata) external override nonReentrant {
        if (
            target.outstandingClaimCount() == 0 || target.fundedOutstandingClaimCount() == 0
                || target.pausedFundedClaim() || block.timestamp < nextAttemptAt
        ) return;
        (
            uint256 epochId,
            uint256[] memory ids,
            uint256 nextEpoch,
            uint256 nextClaim,
            bool maintenance
        ) = _scan();
        if (ids.length == 0 && !maintenance) return;
        uint256 totalSettled;
        bool success;
        if (ids.length != 0) {
            try target.keeperSettleClaims(epochId, ids) returns (uint256 amount) {
                totalSettled = amount;
                success = true;
            } catch {
                uint256[] memory single = new uint256[](1);
                for (uint256 i; i < ids.length; ++i) {
                    single[0] = ids[i];
                    try target.keeperSettleClaims(epochId, single) returns (uint256 amount) {
                        totalSettled += amount;
                        success = true;
                    } catch {
                        retryAfter[epochId][ids[i]] = block.timestamp + RETRY_DELAY;
                        emit ClaimSettlementFailed(epochId, ids[i], block.timestamp + RETRY_DELAY);
                    }
                }
            }
        }
        cursorEpochId = nextEpoch;
        cursorClaimId = nextClaim;
        if (!success) nextAttemptAt = block.timestamp + 1 minutes;
        emit UpkeepPerformed(epochId, ids.length, totalSettled, success);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Scan
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Counts both epoch and claim probes against the scan budget. Wraps to revisit
    ///      unfunded epochs and failed claims without rescanning an unbounded history.
    function _scan()
        internal
        view
        returns (
            uint256 epochId,
            uint256[] memory claimIds,
            uint256 nextEpochId,
            uint256 nextClaimId,
            bool maintenance
        )
    {
        uint256 openEpoch = target.currentEpochId();
        uint256 startEpoch = cursorEpochId <= openEpoch ? cursorEpochId : 0;
        uint256 startClaim = cursorEpochId <= openEpoch ? cursorClaimId : 1;
        uint256 e = startEpoch;
        uint256 c = startClaim;
        uint256 scanned;
        uint256 found;
        bool wrapped;
        uint256[] memory buf = new uint256[](maxClaimsPerUpkeep);
        while (scanned < maxScanPerUpkeep && found < maxClaimsPerUpkeep) {
            if (e > openEpoch) {
                if (found != 0) break;
                e = 0;
                c = 1;
                wrapped = true;
            }
            if (wrapped && (e > startEpoch || (e == startEpoch && c >= startClaim))) break;
            ++scanned;
            EpochQueueStorage.EpochData memory epoch = target.epochData(e);
            uint256 last = target.nextClaimIdForEpoch(e);
            if (
                epoch.state != EpochQueueStorage.EpochState.Funded
                    || epoch.claimedAssets == epoch.totalAssetsOwed || c > last
            ) {
                if (found != 0) break;
                if (wrapped && e == startEpoch) break;
                ++e;
                c = 1;
                continue;
            }
            EpochQueueStorage.EpochClaim memory claim = target.epochClaim(e, c);
            if (
                !claim.claimed && claim.user != address(0) && !excluded[e][c]
                    && block.timestamp >= retryAfter[e][c]
            ) {
                epochId = e;
                buf[found++] = c;
            }
            ++c;
        }
        nextEpochId = e > openEpoch ? 0 : e;
        nextClaimId = e > openEpoch ? 1 : c;
        maintenance = found == 0 && scanned == maxScanPerUpkeep
            && (nextEpochId != cursorEpochId || nextClaimId != cursorClaimId);
        claimIds = new uint256[](found);
        for (uint256 i; i < found; ++i) {
            claimIds[i] = buf[i];
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Owner controls
    // ═══════════════════════════════════════════════════════════════════════════════

    function setBatchSizes(uint256 maxClaimsPerUpkeep_, uint256 maxScanPerUpkeep_)
        external
        onlyOwner
    {
        if (
            maxClaimsPerUpkeep_ == 0 || maxScanPerUpkeep_ == 0
                || maxScanPerUpkeep_ < maxClaimsPerUpkeep_
        ) {
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
