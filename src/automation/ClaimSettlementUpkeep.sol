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

    struct ScanPass {
        bool active;
        bool wrapped;
        uint256 fundedCount;
        uint256 startEpoch;
        uint256 startClaim;
        uint256 lastEpoch;
        uint256 retryAt;
    }

    struct ScanResult {
        uint256 epochId;
        uint256[] ids;
        uint256 nextEpoch;
        uint256 nextClaim;
        bool complete;
        ScanPass pass;
    }

    ScanPass public scanPass;
    bool public scanIdle;

    function _canScan(uint256 fundedCount) internal view returns (bool) {
        if (
            target.outstandingClaimCount() == 0 || fundedCount == 0 || target.pausedFundedClaim()
                || block.timestamp < nextAttemptAt
        ) return false;
        return !scanIdle || scanPass.fundedCount != fundedCount
            || (scanPass.retryAt != 0 && block.timestamp >= scanPass.retryAt);
    }

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 fundedCount = target.fundedOutstandingClaimCount();
        if (!_canScan(fundedCount)) return (false, bytes(""));
        ScanResult memory r = _scan(fundedCount);
        // A partial pass needs one final execution to persist its completed idle state.
        bool maintenance = !r.complete || r.pass.active;
        return
            (
                r.ids.length != 0 || maintenance,
                abi.encode(r.epochId, r.ids, r.nextEpoch, r.nextClaim)
            );
    }

    function performUpkeep(bytes calldata) external override nonReentrant {
        uint256 fundedCount = target.fundedOutstandingClaimCount();
        if (!_canScan(fundedCount)) return;
        ScanResult memory r = _scan(fundedCount);
        if (r.ids.length == 0 && r.complete && !r.pass.active) return;
        uint256 totalSettled;
        bool success;
        if (r.ids.length != 0) {
            try target.keeperSettleClaims(r.epochId, r.ids) returns (uint256 amount) {
                totalSettled = amount;
                success = true;
            } catch {
                uint256[] memory single = new uint256[](1);
                for (uint256 i; i < r.ids.length; ++i) {
                    single[0] = r.ids[i];
                    try target.keeperSettleClaims(r.epochId, single) returns (uint256 amount) {
                        totalSettled += amount;
                        success = true;
                    } catch {
                        retryAfter[r.epochId][r.ids[i]] = block.timestamp + RETRY_DELAY;
                        emit ClaimSettlementFailed(
                            r.epochId, r.ids[i], block.timestamp + RETRY_DELAY
                        );
                    }
                }
            }
            // Work (including failed attempts) starts a new no-work pass at the next cursor.
            delete scanPass;
            scanIdle = false;
        } else {
            r.pass.active = !r.complete;
            scanPass = r.pass;
            scanIdle = r.complete;
        }
        cursorEpochId = r.nextEpoch;
        cursorClaimId = r.nextClaim;
        if (!success) nextAttemptAt = block.timestamp + 1 minutes;
        emit UpkeepPerformed(r.epochId, r.ids.length, totalSettled, success);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Scan
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev A no-work pass spans bounded calls, retaining its original boundary and
    ///      earliest non-excluded retry. New funding or a due retry invalidates the pass.
    function _scan(uint256 fundedCount) internal view returns (ScanResult memory r) {
        uint256 openEpoch = target.currentEpochId();
        uint256 e = cursorEpochId <= openEpoch ? cursorEpochId : 0;
        uint256 c = cursorEpochId <= openEpoch ? cursorClaimId : 1;
        r.pass = scanPass;
        if (
            !r.pass.active || r.pass.fundedCount != fundedCount
                || (r.pass.retryAt != 0 && block.timestamp >= r.pass.retryAt)
        ) {
            r.pass = ScanPass(false, false, fundedCount, e, c, openEpoch, 0);
        }
        uint256 scanned;
        uint256 found;
        uint256[] memory buf = new uint256[](maxClaimsPerUpkeep);
        while (scanned < maxScanPerUpkeep && found < maxClaimsPerUpkeep) {
            if (e > r.pass.lastEpoch) {
                if (found != 0) break;
                e = 0;
                c = 1;
                r.pass.wrapped = true;
            }
            if (
                r.pass.wrapped
                    && (e > r.pass.startEpoch || (e == r.pass.startEpoch && c >= r.pass.startClaim))
            ) {
                r.complete = true;
                break;
            }
            ++scanned;
            EpochQueueStorage.EpochData memory epoch = target.epochData(e);
            uint256 last = target.nextClaimIdForEpoch(e);
            if (
                epoch.state != EpochQueueStorage.EpochState.Funded
                    || epoch.claimedAssets == epoch.totalAssetsOwed || c > last
            ) {
                if (found != 0) break;
                if (r.pass.wrapped && e == r.pass.startEpoch) {
                    r.complete = true;
                    break;
                }
                ++e;
                c = 1;
                continue;
            }
            EpochQueueStorage.EpochClaim memory claim = target.epochClaim(e, c);
            if (!claim.claimed && claim.user != address(0) && !excluded[e][c]) {
                uint256 retryAt = retryAfter[e][c];
                if (block.timestamp >= retryAt) {
                    r.epochId = e;
                    buf[found++] = c;
                } else if (r.pass.retryAt == 0 || retryAt < r.pass.retryAt) {
                    r.pass.retryAt = retryAt;
                }
            }
            ++c;
        }
        // Retain the wrap even when the scan budget ends exactly at the last epoch.
        if (e > r.pass.lastEpoch) {
            e = 0;
            c = 1;
            r.pass.wrapped = true;
        }
        if (
            found == 0 && r.pass.wrapped
                && (e > r.pass.startEpoch || (e == r.pass.startEpoch && c >= r.pass.startClaim))
        ) r.complete = true;
        r.nextEpoch = e;
        r.nextClaim = c;
        r.ids = new uint256[](found);
        for (uint256 i; i < found; ++i) {
            r.ids[i] = buf[i];
        }
    }

    function _resetScan() internal {
        delete scanPass;
        scanIdle = false;
        nextAttemptAt = 0;
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
        _resetScan();
        emit BatchSizeConfigured(maxClaimsPerUpkeep_, maxScanPerUpkeep_);
    }

    function excludeClaim(uint256 epochId, uint256 claimId, bool excludedNow) external onlyOwner {
        excluded[epochId][claimId] = excludedNow;
        _resetScan();
        emit ClaimExcluded(epochId, claimId, excludedNow);
    }

    /// @notice Manual cursor recovery (e.g. to re-scan after excluding a claim that was
    ///         blocking progress, or to skip ahead). Never required in normal operation.
    function setCursor(uint256 epochId, uint256 claimId) external onlyOwner {
        require(claimId > 0, "claimId=0");
        cursorEpochId = epochId;
        cursorClaimId = claimId;
        _resetScan();
        emit CursorSet(epochId, claimId);
    }
}
