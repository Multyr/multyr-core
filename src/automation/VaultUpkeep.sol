// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AutomationCompatibleInterface } from "./AutomationCompatibleInterface.sol";
import { IBufferManager } from "../interfaces/IBufferManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IFixedMaturityModule } from "../interfaces/IFixedMaturityModule.sol";
import { VaultMode, VaultState } from "../core/storage/FixedMaturityStorage.sol";
import { FixedMaturityAutomationDisabledForMode } from "../core/libraries/Errors.sol";

/// @notice Minimal interface for CoreVault v8
interface ICoreVault {
    function canSettle() external view returns (bool);
    function canCrystallize() external view returns (bool);
    function canRealizeWithGap() external view returns (bool canR, uint256 gap);
    function canDeploy() external view returns (bool);

    function settleFeesAndProcessQueue(uint256 maxClaims) external;
    function endEpochCrystallize() external;
    function realizeForReserveAndOps(uint256 maxAmount) external;
    function realizeForQueue(uint256 target) external;
    function deficitForQueue(uint256 maxClaims) external view returns (uint256);
    function settlePreview(uint256 maxClaims) external view returns (
        uint256 eligibleCount, uint256 requiredHot, uint256 inspectedCount, bool hitEarlyExit
    );
    function deployToStrategies(uint256 maxAmount) external;
    function compactQueue() external;
    function queueLength() external view returns (uint256);
    function pendingShares() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function reconcilePendingExits(uint256 maxUsers) external returns (uint256);
    function pendingExitCount() external view returns (uint256);
    function canRebalanceStrategies() external view returns (bool);
    function rebalanceStrategies() external;
}

/// @notice Minimal interface for StrategyRouter cooldown state
interface IStrategyRouterReader {
    function lastBatchTimestamp() external view returns (uint64);
}

/// @notice Minimal view interface to read current regime from the Guard (V10 engine)
interface IRebalanceGuardRead {
    function currentRegime() external view returns (uint8);
}

/// @notice Minimal interface for GlobalConfig cooldown config
interface IGlobalConfigReader {
    function minRebalanceCooldown() external view returns (uint256);
}

enum Op {
    NONE,
    SETTLE,
    CRYSTALLIZE,
    REBALANCE,
    DEPLOY,
    REALIZE,
    REALIZE_FOR_QUEUE,
    COMPACT,
    RECONCILE,
    STRATEGY_REBALANCE  // Inter-strategy allocation rebalance (distinct from buffer REBALANCE)
}

error UnknownOp();

/// @title VaultUpkeep v4 — Gas-optimized Chainlink Automation orchestrator
/// @notice v8 changes:
///   - SETTLE path: only settleFeesAndProcessQueue (no pre-settle rebalance/realize)
///   - REALIZE: uses canRealizeWithGap() (single call, no redundant totalAssets)
///   - Failure backoff with configurable threshold
///   - Target gas: checkUpkeep < 15k (no work), SETTLE from hot < 300k, SETTLE+redeem < 1.2M
contract VaultUpkeep is AutomationCompatibleInterface, Ownable {
    ICoreVault public immutable core;
    IBufferManager public immutable bufferManager;
    IStrategyRouterReader public immutable router;
    IGlobalConfigReader public immutable globalConfig;

    uint256 public immutable DEFAULT_MAX_CLAIMS;
    uint256 public immutable HARD_MAX_CLAIMS;
    uint256 public immutable DEFAULT_MAX_REALIZE;
    uint256 public immutable DEFAULT_MAX_DEPLOY;
    uint16 public immutable minRealizeGapBps;
    uint256 public immutable minRealizeFloor;

    event UpkeepPerformed(Op op, uint256 arg, bool success);
    event UpkeepBackoffEntered(uint8 failures);
    event UpkeepBackoffExited();
    event FailureBackoffConfigured(uint8 threshold, uint32 backoffSeconds);
    event RealizeForQueueFailed(uint256 target, bytes reason);
    event StrategyRebalanceCooldownSet(uint64 cooldown);

    // Failure backoff state
    uint8 public consecutiveFailures;
    uint64 public lastFailureTs;
    uint8 public failureThreshold = 3;
    uint32 public failureBackoffSeconds = 1800; // 30min

    // RECONCILE threshold
    uint256 public reconcileHighThreshold = 20;

    // DEPLOY/REALIZE fairness state
    uint64 public lastDeployTs;
    uint64 public lastRealizeTs;
    uint8 public lastAction; // 0=none, 1=DEPLOY, 2=REALIZE
    uint64 public deployRealizeCooldown = 300; // 5 min default

    // STRATEGY_REBALANCE state
    uint64 public lastStrategyRebalanceTs;
    uint64 public strategyRebalanceCooldown = 86400; // 24h default (STABLE regime)

    // V10 — Regime-aware cooldown
    // Guard address set via governance. Cooldown overrides per-regime.
    // STABLE = strategyRebalanceCooldown (default 24h)
    // VOLATILE = volatileCooldown (default 12h)
    // STRESS = stressCooldown (default 4h, safety-only via guard)
    address public rebalanceGuard;
    uint64 public volatileCooldown = 12 hours;
    uint64 public stressCooldown   = 4 hours;

    // Per-op failure tracking (M3)
    mapping(Op => uint256) public failureCountByOp;

    constructor(
        address core_,
        address bufferManager_,
        address router_,
        address globalConfig_,
        uint256 defaultMaxClaims,
        uint256 hardMaxClaims,
        uint256 defaultMaxRealize,
        uint256 defaultMaxDeploy,
        uint16 minRealizeGapBps_,
        uint256 minRealizeFloor_
    ) {
        require(core_ != address(0), "core=0");
        require(router_ != address(0), "router=0");
        require(globalConfig_ != address(0), "config=0");
        core = ICoreVault(core_);
        bufferManager = IBufferManager(bufferManager_);
        router = IStrategyRouterReader(router_);
        globalConfig = IGlobalConfigReader(globalConfig_);
        DEFAULT_MAX_CLAIMS = (defaultMaxClaims == 0) ? 15 : defaultMaxClaims; // max 15 — settle uses cached valuation, safe under Chainlink 5M
        HARD_MAX_CLAIMS = (hardMaxClaims == 0) ? 100 : hardMaxClaims;
        DEFAULT_MAX_REALIZE = (defaultMaxRealize == 0) ? type(uint256).max : defaultMaxRealize;
        DEFAULT_MAX_DEPLOY = (defaultMaxDeploy == 0) ? type(uint256).max : defaultMaxDeploy;
        minRealizeGapBps = minRealizeGapBps_;
        minRealizeFloor = minRealizeFloor_;
        require(DEFAULT_MAX_CLAIMS <= HARD_MAX_CLAIMS, "bad-claims-bounds");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // checkUpkeep — deterministic priority: SETTLE > CRYSTALLIZE > REBALANCE > DEPLOY > REALIZE
    // ═══════════════════════════════════════════════════════════════════════════════

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // FM gate — FixedMaturity vaults use FixedMaturityVaultUpkeep, not this contract
        // try/catch: if FM module not registered (OpenEnded vault without FM), treat as OpenEnded
        try IFixedMaturityModule(address(core)).currentVaultModeAndState() returns (VaultMode _mode, VaultState) {
            if (_mode == VaultMode.FixedMaturity) return (false, bytes(""));
        } catch {}

        // Failure backoff
        if (consecutiveFailures >= failureThreshold
            && block.timestamp < uint256(lastFailureTs) + uint256(failureBackoffSeconds)) {
            return (false, bytes(""));
        }

        // PRIORITY MODE: if pending reconciliation backlog > threshold, force RECONCILE
        {
            uint256 pendingCount;
            try core.pendingExitCount() returns (uint256 c) { pendingCount = c; } catch {}
            if (pendingCount > reconcileHighThreshold) {
                return (true, abi.encode(Op.RECONCILE, uint256(5)));
            }
        }

        // Priority 1: SETTLE or REALIZE_FOR_QUEUE (queue-driven, anti-churn)
        {
            bool canSettle;
            try core.canSettle() returns (bool ok) { canSettle = ok; } catch {}
            if (canSettle) {
                // Anti-churn: check if settle would actually process anything
                uint256 eligibleCount;
                try core.settlePreview(DEFAULT_MAX_CLAIMS) returns (
                    uint256 ec, uint256, uint256, bool
                ) {
                    eligibleCount = ec;
                } catch {}

                if (eligibleCount == 0) {
                    // No eligible claims (all in lockPeriod or empty).
                    // Do NOT settle — avoid LINK burn on no-op.
                    // Claims will mature naturally; retry at next cycle.
                    // Fall through to CRYSTALLIZE/REBALANCE/DEPLOY/REALIZE.
                } else {
                    // Eligible claims exist — check liquidity
                    uint256 deficit;
                    try core.deficitForQueue(DEFAULT_MAX_CLAIMS) returns (uint256 d) {
                        deficit = d;
                    } catch {}

                    if (deficit == 0) {
                        return (true, abi.encode(Op.SETTLE, DEFAULT_MAX_CLAIMS));
                    } else {
                        return (true, abi.encode(Op.REALIZE_FOR_QUEUE, deficit));
                    }
                }
            }
        }

        // Priority 1b: COMPACT (threshold-based — if queue dirty ratio > 30%)
        {
            uint256 qLen;
            uint256 pendingS;
            try core.queueLength() returns (uint256 l) { qLen = l; } catch {}
            try core.pendingShares() returns (uint256 p) { pendingS = p; } catch {}
            // queueLength = entries from head to end (includes settled in middle)
            // If queueLength is much larger than expected from pendingShares,
            // the queue has many settled entries that waste gas on iteration.
            // Heuristic: if queueLength > 2 * batch size AND pendingShares < queueLength * 50%
            if (qLen > DEFAULT_MAX_CLAIMS * 2) {
                // Dirty queue — compact needed
                return (true, abi.encode(Op.COMPACT, uint256(0)));
            }
        }

        // RECONCILE pending exits if any
        {
            uint256 pendingCount;
            try core.pendingExitCount() returns (uint256 c) { pendingCount = c; } catch {}
            if (pendingCount > 0) {
                return (true, abi.encode(Op.RECONCILE, uint256(5)));
            }
        }

        // Priority 2: CRYSTALLIZE
        {
            bool canCrystallize;
            try core.canCrystallize() returns (bool ok) { canCrystallize = ok; } catch {}
            if (canCrystallize) {
                return (true, abi.encode(Op.CRYSTALLIZE, uint256(0)));
            }
        }

        // Priority 3: REBALANCE (warm buffer)
        if (address(bufferManager) != address(0)) {
            bool canRb;
            try bufferManager.canRebalance() returns (bool ok) { canRb = ok; } catch {}
            if (canRb) {
                return (true, abi.encode(Op.REBALANCE, uint256(0)));
            }
        }

        // Priority 3.5: STRATEGY_REBALANCE (inter-strategy allocation, regime-aware cooldown)
        // Distinct from REBALANCE (buffer hot/warm). Only if 2+ eligible strategies.
        // V10: effective cooldown depends on regime (STABLE=24h, VOLATILE=12h, STRESS=4h safety-only).
        uint256 effectiveCd = _effectiveRebalanceCooldown();
        if (block.timestamp >= uint256(lastStrategyRebalanceTs) + effectiveCd) {
            bool canSR;
            try core.canRebalanceStrategies() returns (bool ok) { canSR = ok; } catch {}
            if (canSR) {
                return (true, abi.encode(Op.STRATEGY_REBALANCE, uint256(0)));
            }
        }

        // Priority 4/5: DEPLOY vs REALIZE with fairness
        // Each has its own cooldown tracking (separate from StrategyRouter batch cooldown).
        // Starvation guard: if REALIZE hasn't run for 2x cooldown, it gets priority.
        // Alternation: if both ready, last-action loser goes first.
        {
            bool batchOk = _isBatchCooldownElapsed();

            bool deployReady = batchOk && block.timestamp >= uint256(lastDeployTs) + uint256(deployRealizeCooldown);
            bool realizeReady = batchOk && block.timestamp >= uint256(lastRealizeTs) + uint256(deployRealizeCooldown);
            bool realizeStarved = block.timestamp >= uint256(lastRealizeTs) + uint256(deployRealizeCooldown) * 2;
            bool lastWasDeploy = lastAction == 1;

            // Probe readiness
            bool canDep;
            if (deployReady) {
                try core.canDeploy() returns (bool ok) { canDep = ok; } catch {}
            }

            bool canR;
            uint256 gap;
            uint256 realizeAmount;
            if (realizeReady || realizeStarved) {
                try core.canRealizeWithGap() returns (bool ok, uint256 g) {
                    if (ok && _gapPassesThreshold(g)) {
                        canR = true;
                        gap = g;
                        realizeAmount = g < DEFAULT_MAX_REALIZE ? g : DEFAULT_MAX_REALIZE;
                    }
                } catch {}
            }

            // Fairness decision
            if ((realizeReady || realizeStarved) && canR) {
                if (realizeStarved || (deployReady && canDep && lastWasDeploy)) {
                    return (true, abi.encode(Op.REALIZE, realizeAmount));
                }
            }
            if (deployReady && canDep) {
                return (true, abi.encode(Op.DEPLOY, uint256(0)));
            }
            if ((realizeReady || realizeStarved) && canR) {
                return (true, abi.encode(Op.REALIZE, realizeAmount));
            }
        }

        return (false, bytes(""));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // performUpkeep — all branches use try/catch for Chainlink liveness
    // ═══════════════════════════════════════════════════════════════════════════════

    function performUpkeep(bytes calldata performData) external override {
        // FM gate — if FM module registered and mode is FixedMaturity, revert
        try IFixedMaturityModule(address(core)).currentVaultModeAndState() returns (VaultMode _mode, VaultState) {
            if (_mode == VaultMode.FixedMaturity) revert FixedMaturityAutomationDisabledForMode();
        } catch {}

        (Op op, uint256 arg) = _decode(performData);

        if (op == Op.SETTLE) {
            // v8: ONLY settleFeesAndProcessQueue — no pre-settle rebalance/realize
            // The settle path has full waterfall: hot → warm refill → strategy redeem
            uint256 maxClaims = arg;
            if (maxClaims == 0 || maxClaims > HARD_MAX_CLAIMS) {
                maxClaims = DEFAULT_MAX_CLAIMS;
            }
            bool success;
            try core.settleFeesAndProcessQueue(maxClaims) {
                success = true;
            } catch {}
            emit UpkeepPerformed(Op.SETTLE, maxClaims, success);
            if (success) { failureCountByOp[Op.SETTLE] = 0; _recordSuccess(); }
            else { failureCountByOp[Op.SETTLE]++; _recordRealFailure(); }
            return;
        }

        if (op == Op.CRYSTALLIZE) {
            bool success;
            try core.endEpochCrystallize() {
                success = true;
            } catch {}
            emit UpkeepPerformed(Op.CRYSTALLIZE, 0, success);
            if (success) { failureCountByOp[Op.CRYSTALLIZE] = 0; _recordSuccess(); }
            else { failureCountByOp[Op.CRYSTALLIZE]++; _recordRealFailure(); }
            return;
        }

        if (op == Op.REBALANCE) {
            bool success;
            if (address(bufferManager) != address(0)) {
                try bufferManager.rebalance() {
                    success = true;
                } catch {}
            }
            emit UpkeepPerformed(Op.REBALANCE, 0, success);
            if (success) { failureCountByOp[Op.REBALANCE] = 0; _recordSuccess(); }
            else { failureCountByOp[Op.REBALANCE]++; _recordRealFailure(); }
            return;
        }

        if (op == Op.DEPLOY) {
            uint256 maxAmount = (arg == 0) ? DEFAULT_MAX_DEPLOY : arg;
            bool success;
            try core.deployToStrategies(maxAmount) {
                success = true;
            } catch {}
            emit UpkeepPerformed(Op.DEPLOY, maxAmount, success);
            if (success) {
                lastDeployTs = uint64(block.timestamp);
                lastAction = 1;
                failureCountByOp[Op.DEPLOY] = 0;
                _recordSuccess();
            } else {
                failureCountByOp[Op.DEPLOY]++;
                _recordRealFailure();
            }
            return;
        }

        if (op == Op.REALIZE) {
            uint256 maxAmount = (arg == 0) ? DEFAULT_MAX_REALIZE : arg;
            bool success;
            try core.realizeForReserveAndOps(maxAmount) {
                success = true;
            } catch {}
            emit UpkeepPerformed(Op.REALIZE, maxAmount, success);
            if (success) {
                lastRealizeTs = uint64(block.timestamp);
                lastAction = 2;
                failureCountByOp[Op.REALIZE] = 0;
                _recordSuccess();
            } else {
                failureCountByOp[Op.REALIZE]++;
                _recordRealFailure();
            }
            return;
        }

        if (op == Op.COMPACT) {
            bool success;
            try core.compactQueue() {
                success = true;
            } catch {}
            emit UpkeepPerformed(Op.COMPACT, 0, success);
            if (success) {
                _recordSuccess();
            } else {
                _recordRealFailure();
            }
            return;
        }

        if (op == Op.REALIZE_FOR_QUEUE) {
            bool success;
            try core.realizeForQueue(arg) {
                success = true;
            } catch (bytes memory reason) {
                emit RealizeForQueueFailed(arg, reason);
            }
            emit UpkeepPerformed(Op.REALIZE_FOR_QUEUE, arg, success);
            if (success) {
                lastRealizeTs = uint64(block.timestamp);
                failureCountByOp[Op.REALIZE_FOR_QUEUE] = 0;
                _recordSuccess();
            } else {
                failureCountByOp[Op.REALIZE_FOR_QUEUE]++;
                _recordRealFailure();
            }
            return;
        }

        if (op == Op.RECONCILE) {
            bool success;
            try core.reconcilePendingExits(arg) returns (uint256 processed) {
                success = processed > 0;
            } catch {}
            emit UpkeepPerformed(Op.RECONCILE, arg, success);
            if (success) {
                _recordSuccess();
            } else {
                _recordRealFailure();
            }
            return;
        }

        if (op == Op.STRATEGY_REBALANCE) {
            bool success;
            try core.rebalanceStrategies() {
                success = true;
            } catch {}
            emit UpkeepPerformed(Op.STRATEGY_REBALANCE, 0, success);
            if (success) {
                lastStrategyRebalanceTs = uint64(block.timestamp);
                failureCountByOp[Op.STRATEGY_REBALANCE] = 0;
                _recordSuccess();
            } else {
                failureCountByOp[Op.STRATEGY_REBALANCE]++;
                _recordRealFailure();
            }
            return;
        }

        revert UnknownOp();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Failure backoff
    // ═══════════════════════════════════════════════════════════════════════════════

    function _recordRealFailure() internal {
        consecutiveFailures++;
        lastFailureTs = uint64(block.timestamp);
        if (consecutiveFailures >= failureThreshold) {
            emit UpkeepBackoffEntered(consecutiveFailures);
        }
    }

    function _recordSuccess() internal {
        if (consecutiveFailures > 0) {
            consecutiveFailures = 0;
            emit UpkeepBackoffExited();
        }
    }

    function setFailureBackoff(uint8 threshold, uint32 backoffSeconds) external onlyOwner {
        require(threshold >= 1 && threshold <= 10, "bad threshold");
        require(backoffSeconds >= 60 && backoffSeconds <= 86400, "bad backoff");
        failureThreshold = threshold;
        failureBackoffSeconds = backoffSeconds;
        emit FailureBackoffConfigured(threshold, backoffSeconds);
    }

    event DeployRealizeCooldownSet(uint64 cooldown);
    function setDeployRealizeCooldown(uint64 cd) external onlyOwner {
        require(cd >= 60 && cd <= 86400, "range");
        deployRealizeCooldown = cd;
        emit DeployRealizeCooldownSet(cd);
    }

    event ReconcileHighThresholdSet(uint256 threshold);
    function setReconcileHighThreshold(uint256 threshold) external onlyOwner {
        reconcileHighThreshold = threshold;
        emit ReconcileHighThresholdSet(threshold);
    }

    function setStrategyRebalanceCooldown(uint64 cd) external onlyOwner {
        require(cd >= 86400 && cd <= 604800, "range"); // 24h to 7d
        strategyRebalanceCooldown = cd;
        emit StrategyRebalanceCooldownSet(cd);
    }

    // V10 — Regime-aware cooldown governance
    event RebalanceGuardSet(address indexed guard);
    event RegimeCooldownsSet(uint64 volatileCd, uint64 stressCd);

    function setRebalanceGuard(address g) external onlyOwner {
        rebalanceGuard = g;
        emit RebalanceGuardSet(g);
    }

    function setRegimeCooldowns(uint64 volatileCd, uint64 stressCd) external onlyOwner {
        require(volatileCd >= 1 hours && volatileCd <= 86400, "vol range");
        require(stressCd >= 1 hours && stressCd <= 86400, "stress range");
        volatileCooldown = volatileCd;
        stressCooldown = stressCd;
        emit RegimeCooldownsSet(volatileCd, stressCd);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev Compute effective rebalance cooldown based on current regime from the Guard.
    ///      Falls back to strategyRebalanceCooldown if Guard unset/unreachable.
    function _effectiveRebalanceCooldown() internal view returns (uint256) {
        if (rebalanceGuard == address(0)) return uint256(strategyRebalanceCooldown);
        try IRebalanceGuardRead(rebalanceGuard).currentRegime() returns (uint8 r) {
            if (r == 1) return uint256(volatileCooldown);
            if (r == 2) return uint256(stressCooldown);
            return uint256(strategyRebalanceCooldown); // STABLE
        } catch {
            return uint256(strategyRebalanceCooldown);
        }
    }

    /// @dev Check StrategyRouter batch cooldown
    function _isBatchCooldownElapsed() internal view returns (bool) {
        try router.lastBatchTimestamp() returns (uint64 lastTs) {
            if (lastTs == 0) return true;
            try globalConfig.minRebalanceCooldown() returns (uint256 minCooldown) {
                return block.timestamp >= uint256(lastTs) + minCooldown;
            } catch { return true; }
        } catch { return true; }
    }

    /// @dev Check if realize gap passes threshold (minRealizeFloor OR proportional with hysteresis)
    /// @param gap The realize gap in asset units (from canRealizeWithGap)
    function _gapPassesThreshold(uint256 gap) internal view returns (bool) {
        if (gap == 0) return false;
        if (gap >= minRealizeFloor) return true;
        if (minRealizeGapBps > 0) {
            try core.totalAssets() returns (uint256 ta) {
                if (ta > 0) {
                    uint256 threshold = (ta * uint256(minRealizeGapBps)) / 10000;
                    uint256 upper = threshold * 120 / 100; // 20% hysteresis band
                    return gap >= upper;
                }
            } catch {}
        }
        return false;
    }

    function _decode(bytes calldata data) internal pure returns (Op op, uint256 arg) {
        if (data.length == 0) return (Op.NONE, 0);
        if (data.length == 32) {
            op = Op(uint8(abi.decode(data, (uint256))));
            return (op, 0);
        }
        (op, arg) = abi.decode(data, (Op, uint256));
    }

    function getCore() external view returns (address) {
        return address(core);
    }
}
