// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IExecutionMemory } from "../../interfaces/IExecutionMemory.sol";

/// @title ExecutionMemory — bootstrap-safe cost model with observation thresholds + inactivity decay
/// @notice Records per-strategy execution outcomes. Returns fallback cost/penalty if observation
///         count is below threshold (Correction #3). Applies view-time inactivity decay (Improvement #4).
contract ExecutionMemory is IExecutionMemory {

    uint256 private constant BPS = 10_000;

    // ─────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────

    struct ExecRec {
        uint64 emaGasCost;
        uint32 emaSlippageBps;
        uint32 failedCount;
        uint32 successCount;
        int32  emaRealizedVsExpectedBps;
        uint64 lastUpdateTs;
        uint16 observationCount;
    }

    mapping(address => ExecRec) internal _records;

    // Access
    address public owner;
    address public keeper;

    // Bootstrap thresholds (Correction #3)
    uint16 public minObservationsForLiveCost = 10;
    uint16 public minObservationsForPenalty = 20;

    // Fallback values (Correction #3)
    uint32 public fallbackGasCostUsd     = uint32(50 * 1e6);
    uint16 public fallbackSlippageBps    = 5;
    uint16 public fallbackPenaltyBps     = 50;

    // Outlier filter (Correction #3)
    uint32 public maxAcceptableGasCost      = uint32(500 * 1e6);
    uint16 public maxAcceptableSlippageBps  = 1_000;

    // EMA smoothing
    uint16 public emaBetaBps = 2_000; // 20% new observation weight

    // Inactivity decay (Improvement #4)
    uint32 public inactivityDecayThresholdSeconds = 30 days;
    uint16 public inactivityDecayBetaBps          = 5_000; // 50% blend toward fallback after threshold

    // ─────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────

    error NotOwner();
    error NotKeeper();
    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event KeeperSet(address indexed keeper);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event ThresholdsSet(uint16 minLive, uint16 minPenalty);
    event FallbackCostSet(uint32 gasCostUsd, uint16 slippageBps, uint16 penaltyBps);
    event OutlierFilterSet(uint32 maxGasCost, uint16 maxSlippageBps);
    event InactivityDecaySet(uint32 thresholdSeconds, uint16 betaBps);
    event EmaBetaSet(uint16 betaBps);

    // ─────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyKeeper() { if (msg.sender != keeper && msg.sender != owner) revert NotKeeper(); _; }

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(address owner_, address keeper_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (keeper_ == address(0)) revert ZeroAddress();
        owner = owner_;
        keeper = keeper_;
    }

    // ─────────────────────────────────────────────────────────────────────
    // recordExecution
    // ─────────────────────────────────────────────────────────────────────

    /// @inheritdoc IExecutionMemory
    function recordExecution(
        address strategy,
        uint256 gasUsed,
        uint16 slippageBps,
        int256 realizedVsExpectedBps,
        bool success
    ) external override onlyKeeper {
        // Outlier filter: reject and emit, but do not update EMA.
        if (gasUsed > maxAcceptableGasCost || slippageBps > maxAcceptableSlippageBps) {
            emit ExecutionOutlierRejected(strategy, gasUsed, slippageBps);
            return;
        }

        ExecRec storage r = _records[strategy];

        if (r.lastUpdateTs == 0) {
            // First observation
            r.emaGasCost = uint64(gasUsed > type(uint64).max ? type(uint64).max : gasUsed);
            r.emaSlippageBps = uint32(slippageBps);
            r.emaRealizedVsExpectedBps = _clampI32(realizedVsExpectedBps);
        } else {
            // EMA update
            uint256 newG = (uint256(emaBetaBps) * gasUsed
                           + (BPS - uint256(emaBetaBps)) * uint256(r.emaGasCost)) / BPS;
            r.emaGasCost = uint64(newG > type(uint64).max ? type(uint64).max : newG);

            uint256 newS = (uint256(emaBetaBps) * uint256(slippageBps)
                           + (BPS - uint256(emaBetaBps)) * uint256(r.emaSlippageBps)) / BPS;
            r.emaSlippageBps = uint32(newS);

            int256 newRvE = (int256(uint256(emaBetaBps)) * realizedVsExpectedBps
                            + int256(BPS - uint256(emaBetaBps)) * int256(r.emaRealizedVsExpectedBps)) / int256(BPS);
            r.emaRealizedVsExpectedBps = _clampI32(newRvE);
        }

        if (success) {
            r.successCount += 1;
        } else {
            r.failedCount += 1;
        }

        r.lastUpdateTs = uint64(block.timestamp);
        if (r.observationCount < type(uint16).max) r.observationCount += 1;

        emit ExecutionMemoryRecorded(strategy, gasUsed, slippageBps, realizedVsExpectedBps, r.observationCount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Views with bootstrap fallback + inactivity decay
    // ─────────────────────────────────────────────────────────────────────

    /// @inheritdoc IExecutionMemory
    function getExpectedCost(address strategy)
        external view override returns (uint256 gasCostUsd, uint16 slippageBps)
    {
        ExecRec memory r = _records[strategy];
        if (r.observationCount < minObservationsForLiveCost) {
            return (uint256(fallbackGasCostUsd), fallbackSlippageBps);
        }

        uint256 liveGas = uint256(r.emaGasCost);
        uint256 liveSlip = uint256(r.emaSlippageBps);

        // Inactivity decay (Improvement #4): blend toward fallback if stale
        if (r.lastUpdateTs > 0 && block.timestamp - r.lastUpdateTs > inactivityDecayThresholdSeconds) {
            uint16 beta = inactivityDecayBetaBps; // weight toward fallback
            liveGas = (uint256(beta) * uint256(fallbackGasCostUsd)
                     + (BPS - uint256(beta)) * liveGas) / BPS;
            liveSlip = (uint256(beta) * uint256(fallbackSlippageBps)
                     + (BPS - uint256(beta)) * liveSlip) / BPS;
        }

        gasCostUsd = liveGas;
        slippageBps = liveSlip > type(uint16).max ? type(uint16).max : uint16(liveSlip);
    }

    /// @inheritdoc IExecutionMemory
    function getPenalty(address strategy) external view override returns (uint16) {
        ExecRec memory r = _records[strategy];
        if (r.observationCount < minObservationsForPenalty) {
            return fallbackPenaltyBps;
        }
        // Penalty derived from failed/success ratio + realized-vs-expected EMA
        uint256 totalOps = uint256(r.successCount) + uint256(r.failedCount);
        if (totalOps == 0) return fallbackPenaltyBps;
        uint256 failRatioBps = (uint256(r.failedCount) * BPS) / totalOps;

        // Negative realized-vs-expected adds penalty
        int256 rvE = int256(r.emaRealizedVsExpectedBps);
        uint256 negPenalty = rvE < 0 ? uint256(-rvE) : 0;

        uint256 penalty = failRatioBps / 10 + negPenalty; // crude but conservative
        if (penalty > BPS) penalty = BPS;
        return uint16(penalty);
    }

    /// @inheritdoc IExecutionMemory
    function getAggregatePenalty(address[] calldata strategies)
        external view override returns (uint16 avgPenaltyBps)
    {
        uint256 n = strategies.length;
        if (n == 0) return 0;
        uint256 sum = 0;
        for (uint256 i = 0; i < n; i++) {
            sum += this.getPenalty(strategies[i]);
        }
        uint256 avg = sum / n;
        return avg > type(uint16).max ? type(uint16).max : uint16(avg);
    }

    /// @inheritdoc IExecutionMemory
    function records(address strategy) external view override returns (
        uint64 emaGasCost,
        uint32 emaSlippageBps,
        uint32 failedCount,
        uint32 successCount,
        int32 emaRealizedVsExpectedBps,
        uint64 lastUpdateTs,
        uint16 observationCount
    ) {
        ExecRec memory r = _records[strategy];
        return (
            r.emaGasCost,
            r.emaSlippageBps,
            r.failedCount,
            r.successCount,
            r.emaRealizedVsExpectedBps,
            r.lastUpdateTs,
            r.observationCount
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────

    function _clampI32(int256 v) internal pure returns (int32) {
        if (v > int256(int32(type(int32).max))) return type(int32).max;
        if (v < int256(int32(type(int32).min))) return type(int32).min;
        return int32(v);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Governance
    // ─────────────────────────────────────────────────────────────────────

    function setKeeper(address k) external onlyOwner {
        require(k != address(0), "zero");
        keeper = k;
        emit KeeperSet(k);
    }

    function setThresholds(uint16 minLive, uint16 minPenalty) external onlyOwner {
        minObservationsForLiveCost = minLive;
        minObservationsForPenalty = minPenalty;
        emit ThresholdsSet(minLive, minPenalty);
    }

    function setFallbackCost(
        uint32 gasCostUsd,
        uint16 slippageBps,
        uint16 penaltyBps
    ) external onlyOwner {
        fallbackGasCostUsd = gasCostUsd;
        fallbackSlippageBps = slippageBps;
        fallbackPenaltyBps = penaltyBps;
        emit FallbackCostSet(gasCostUsd, slippageBps, penaltyBps);
    }

    function setOutlierFilter(uint32 maxGas, uint16 maxSlip) external onlyOwner {
        maxAcceptableGasCost = maxGas;
        maxAcceptableSlippageBps = maxSlip;
        emit OutlierFilterSet(maxGas, maxSlip);
    }

    function setInactivityDecay(uint32 thresholdSeconds, uint16 betaBps) external onlyOwner {
        require(betaBps <= BPS, "beta>10000");
        inactivityDecayThresholdSeconds = thresholdSeconds;
        inactivityDecayBetaBps = betaBps;
        emit InactivityDecaySet(thresholdSeconds, betaBps);
    }

    function setEmaBeta(uint16 beta) external onlyOwner {
        require(beta <= BPS, "beta>10000");
        emaBetaBps = beta;
        emit EmaBetaSet(beta);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }
}
