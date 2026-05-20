// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IIncentivesEngine } from "../../interfaces/IIncentivesEngine.sol";
import { FixedPoint } from "../../libs/FixedPoint.sol";

/// @title IncentivesEngine — Tranche-Based Incentives Accounting
/// @notice ACCOUNTING ONLY. Does not move assets, mint shares, or transfer tokens.
///         All amounts in WAD (1e18). Payout handled by RewardsPayoutManager.
///
/// Architecture:
///   - Per-deposit tranches (not aggregate per-user)
///   - FIFO exit consumption
///   - Non-retroactive versioned parameters
///   - Auto-claim pending reward before exit slash
///   - Auto-consolidation when tranche count exceeds threshold
///   - Pull-based payout via external RewardsPayoutManager
contract IncentivesEngine is IIncentivesEngine {
    uint256 internal constant WAD = FixedPoint.WAD;
    uint32 public constant MAX_TRANCHES = 50;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS (pending exit reconciliation)
    // ═══════════════════════════════════════════════════════════════════════════

    event ExitPendingRecorded(address indexed user, uint256 assetsExitedWad, uint256 pendingId);
    event ExitReconciled(address indexed user, uint256 pendingId, uint256 vestedUnits, uint256 slashedUnits);
    event ExitReconcileFailed(address indexed user, uint256 pendingId, bytes reason);
    event ExitReconcileSkipped(address indexed user, uint256 pendingId);
    event ReconcileBatchCompleted(uint256 processed, uint256 remaining);

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    address public override core;
    address public override treasury;
    address public override governance;

    uint32 public override currentParamsId;
    mapping(uint32 => IncentiveParams) internal _paramSets;

    mapping(address => DepositTranche[]) internal _userTranches;
    mapping(address => RewardVestingTranche[]) internal _userVestings;

    // Pending exit reconciliation (circular queue)
    struct PendingExitRecord {
        address user;
        uint128 assetsExitedWad;
        uint64 exitTs;
    }
    mapping(uint256 => PendingExitRecord) public pendingExits;
    uint256 public pendingHead;
    uint256 public pendingTail;
    mapping(address => uint256) public frozenExitAssets;
    mapping(address => uint64) internal _exitAccrualCheckpoint;

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    modifier onlyCore() {
        require(msg.sender == core, "not-core");
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "not-governance");
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(
        address core_,
        address treasury_,
        address governance_,
        IncentiveParams memory initialParams
    ) {
        require(core_ != address(0), "core=0");
        require(treasury_ != address(0), "treasury=0");
        require(governance_ != address(0), "governance=0");

        core = core_;
        treasury = treasury_;
        governance = governance_;

        _validateParams(initialParams);
        _paramSets[0] = initialParams;
        currentParamsId = 0;

        emit GovernanceTransferred(address(0), governance_);
        emit ParamsUpdated(0, initialParams);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE HOOKS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IIncentivesEngine
    function onDeposit(address user, uint256 addedAssetsWad) external override onlyCore {
        if (addedAssetsWad == 0) return;

        IncentiveParams storage p = _paramSets[currentParamsId];
        if (!p.active) return; // inactive: skip tranche creation

        // Auto-consolidate if too many tranches
        uint256 trancheLen = _userTranches[user].length;
        if (trancheLen >= MAX_TRANCHES) {
            _autoConsolidate(user);
        } else if (trancheLen >= MAX_TRANCHES * 3 / 4) {
            // Alert at 75% threshold (37 tranches)
            emit TrancheCountWarning(user, trancheLen, MAX_TRANCHES);
        }

        // Create new deposit tranche
        uint256 idx = _userTranches[user].length;
        _userTranches[user].push(DepositTranche({
            principalWad: uint128(addedAssetsWad),
            depositTs: uint64(block.timestamp),
            lastAccrualTs: uint64(block.timestamp),
            paramsId: currentParamsId,
            active: true
        }));

        emit TrancheCreated(user, idx, uint128(addedAssetsWad), currentParamsId);
    }

    /// @inheritdoc IIncentivesEngine
    function onExit(address user, uint256 assetsExitedWad)
        external
        override
        onlyCore
        returns (uint256 vestedUnits, uint256 slashedUnits)
    {
        if (assetsExitedWad == 0) return (0, 0);

        // STEP 1: Compute exit fraction
        uint256 totalUserAssets = _totalUserPrincipal(user);
        if (totalUserAssets == 0) return (0, 0);
        uint256 exitFraction = assetsExitedWad * WAD / totalUserAssets;
        if (exitFraction > WAD) exitFraction = WAD; // cap at 100%

        // STEP 2: Auto-capture pending reward ONCE (before consumption)
        uint256 totalPending = _totalPendingReward(user);
        if (totalPending > 0) {
            _createRewardVesting(user, uint128(totalPending));
            // Reset all accrual checkpoints
            DepositTranche[] storage tranches = _userTranches[user];
            for (uint256 i = 0; i < tranches.length; i++) {
                if (tranches[i].active) {
                    tranches[i].lastAccrualTs = uint64(block.timestamp);
                }
            }
        }

        // STEP 3: FIFO consumption of deposit tranches
        _consumeFIFO(user, assetsExitedWad);

        // STEP 4: Slash ALL reward vesting tranches pro-rata to EXIT FRACTION
        slashedUnits = _slashVestingProRata(user, exitFraction);

        // STEP 5: Auto-consolidate if needed
        if (_userTranches[user].length > MAX_TRANCHES) {
            _autoConsolidate(user);
        }

        // vestedUnits: remaining vested across all tranches (informational)
        vestedUnits = _totalVestedAvailable(user);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LIGHT EXIT (O(1) — called during settle)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IIncentivesEngine
    function onExitLight(address user, uint256 assetsExitedWad) external override onlyCore {
        if (assetsExitedWad == 0) return;
        pendingExits[pendingTail] = PendingExitRecord({
            user: user,
            assetsExitedWad: uint128(assetsExitedWad),
            exitTs: uint64(block.timestamp)
        });
        unchecked { ++pendingTail; }
        uint64 current = _exitAccrualCheckpoint[user];
        if (uint64(block.timestamp) > current) {
            _exitAccrualCheckpoint[user] = uint64(block.timestamp);
        }
        frozenExitAssets[user] += assetsExitedWad;
        emit ExitPendingRecorded(user, assetsExitedWad, pendingTail - 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RECONCILIATION (heavy — called by keeper)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IIncentivesEngine
    function reconcilePendingExits(uint256 maxUsers) external override returns (uint256 processed) {
        require(msg.sender == core || msg.sender == governance, "not-authorized");
        uint256 h = pendingHead;
        uint256 t = pendingTail;
        while (h < t && processed < maxUsers) {
            PendingExitRecord storage rec = pendingExits[h];
            bool success;
            try this.reconcileOneExit(rec.user, rec.assetsExitedWad)
                returns (uint256 vested, uint256 slashed)
            {
                success = true;
                emit ExitReconciled(rec.user, h, vested, slashed);
            } catch (bytes memory reason) {
                emit ExitReconcileFailed(rec.user, h, reason);
                break; // DO NOT advance head on failure
            }
            if (frozenExitAssets[rec.user] >= rec.assetsExitedWad) {
                frozenExitAssets[rec.user] -= rec.assetsExitedWad;
            } else {
                frozenExitAssets[rec.user] = 0;
            }
            if (frozenExitAssets[rec.user] == 0) {
                _exitAccrualCheckpoint[rec.user] = 0;
            }
            delete pendingExits[h];
            unchecked { ++h; ++processed; }
        }
        pendingHead = h;
        emit ReconcileBatchCompleted(processed, t - h);
    }

    /// @dev External for try/catch — contains same logic as onExit steps 1-5
    function reconcileOneExit(address user, uint256 assetsExitedWad)
        external
        returns (uint256 vestedUnits, uint256 slashedUnits)
    {
        require(msg.sender == address(this), "self-only");

        if (assetsExitedWad == 0) return (0, 0);

        // STEP 1: Compute exit fraction
        uint256 totalUserAssets = _totalUserPrincipal(user);
        if (totalUserAssets == 0) return (0, 0);
        uint256 exitFraction = assetsExitedWad * WAD / totalUserAssets;
        if (exitFraction > WAD) exitFraction = WAD; // cap at 100%

        // STEP 2: Auto-capture pending reward ONCE (before consumption)
        uint256 totalPending = _totalPendingReward(user);
        if (totalPending > 0) {
            _createRewardVesting(user, uint128(totalPending));
            // Reset all accrual checkpoints
            DepositTranche[] storage tranches = _userTranches[user];
            for (uint256 i = 0; i < tranches.length; i++) {
                if (tranches[i].active) {
                    tranches[i].lastAccrualTs = uint64(block.timestamp);
                }
            }
        }

        // STEP 3: FIFO consumption of deposit tranches
        _consumeFIFO(user, assetsExitedWad);

        // STEP 4: Slash ALL reward vesting tranches pro-rata to EXIT FRACTION
        slashedUnits = _slashVestingProRata(user, exitFraction);

        // STEP 5: Auto-consolidate if needed
        if (_userTranches[user].length > MAX_TRANCHES) {
            _autoConsolidate(user);
        }

        // vestedUnits: remaining vested across all tranches (informational)
        vestedUnits = _totalVestedAvailable(user);
    }

    /// @inheritdoc IIncentivesEngine
    function skipFailedReconcile(uint256 pendingId) external override {
        require(msg.sender == governance, "not-governance");
        require(pendingId == pendingHead, "not-head");
        PendingExitRecord storage rec = pendingExits[pendingHead];
        if (frozenExitAssets[rec.user] >= rec.assetsExitedWad) {
            frozenExitAssets[rec.user] -= rec.assetsExitedWad;
        } else {
            frozenExitAssets[rec.user] = 0;
        }
        if (frozenExitAssets[rec.user] == 0) {
            _exitAccrualCheckpoint[rec.user] = 0;
        }
        emit ExitReconcileSkipped(rec.user, pendingId);
        delete pendingExits[pendingHead];
        unchecked { ++pendingHead; }
    }

    /// @inheritdoc IIncentivesEngine
    function pendingExitCount() external view override returns (uint256) {
        return pendingTail - pendingHead;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // USER ACTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IIncentivesEngine
    function claimAndCreateVesting(address user) external override returns (uint256 claimed) {
        // Callable by core or by user directly (for manual claim)
        require(msg.sender == core || msg.sender == user, "not-authorized");

        uint256 totalPending = _totalPendingReward(user);
        require(totalPending > 0, "no-reward");

        _createRewardVesting(user, uint128(totalPending));

        // Reset accrual checkpoints on all active tranches
        DepositTranche[] storage tranches = _userTranches[user];
        for (uint256 i = 0; i < tranches.length; i++) {
            if (tranches[i].active) {
                tranches[i].lastAccrualTs = uint64(block.timestamp);
            }
        }

        claimed = totalPending;
        emit RewardAccrued(user, uint128(totalPending));
    }

    /// @inheritdoc IIncentivesEngine
    function withdrawVested(address user, uint256 vestingIdx, uint256 amount)
        external
        override
        returns (uint256 paid, RewardMode mode, uint128 conversionRatio)
    {
        // Callable by RewardsPayoutManager or user
        require(msg.sender == core || msg.sender == user || msg.sender == governance, "not-authorized");

        RewardVestingTranche storage v = _userVestings[user][vestingIdx];
        require(v.active, "vesting-inactive");

        uint256 available = _vestedAvailable(v);
        require(amount <= available, "exceeds-vested");

        v.withdrawnUnits += uint128(amount);
        paid = amount;
        mode = v.mode;
        conversionRatio = v.conversionRatio;

        emit RewardWithdrawn(user, vestingIdx, uint128(amount));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAINTENANCE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IIncentivesEngine
    function consolidateTranches(address user) external override {
        _autoConsolidate(user);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GOVERNANCE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IIncentivesEngine
    function setParams(IncentiveParams calldata newParams) external override onlyGovernance {
        _validateParams(newParams);
        uint32 newId = currentParamsId + 1;
        _paramSets[newId] = newParams;
        currentParamsId = newId;
        emit ParamsUpdated(newId, newParams);
    }

    event CoreSet(address indexed core);
    event TreasurySet(address indexed treasury);

    function setCore(address core_) external override onlyGovernance {
        require(core_ != address(0), "core=0");
        core = core_;
        emit CoreSet(core_);
    }

    function setTreasury(address treasury_) external override onlyGovernance {
        require(treasury_ != address(0), "treasury=0");
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function transferGovernance(address newGov) external override onlyGovernance {
        require(newGov != address(0), "gov=0");
        emit GovernanceTransferred(governance, newGov);
        governance = newGov;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    function getParams(uint32 paramsId) external view override returns (IncentiveParams memory) {
        return _paramSets[paramsId];
    }

    function getCurrentParams() external view override returns (IncentiveParams memory) {
        return _paramSets[currentParamsId];
    }

    function getUserTranches(address user) external view override returns (DepositTranche[] memory) {
        return _userTranches[user];
    }

    function getUserVestings(address user) external view override returns (RewardVestingTranche[] memory) {
        return _userVestings[user];
    }

    function trancheCount(address user) external view override returns (uint256) {
        return _userTranches[user].length;
    }

    function vestingCount(address user) external view override returns (uint256) {
        return _userVestings[user].length;
    }

    function pendingReward(address user) external view override returns (uint256 totalPendingWad) {
        return _totalPendingReward(user);
    }

    function vestedAvailable(address user, uint256 vestingIdx) external view override returns (uint256) {
        return _vestedAvailable(_userVestings[user][vestingIdx]);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: ACCRUAL MATH (per-tranche)
    // ═══════════════════════════════════════════════════════════════════════════

    function _totalPendingReward(address user) internal view returns (uint256 total) {
        DepositTranche[] storage tranches = _userTranches[user];
        for (uint256 i = 0; i < tranches.length; i++) {
            if (!tranches[i].active) continue;
            total += _tranchePendingReward(tranches[i], user);
        }
    }

    function _tranchePendingReward(DepositTranche storage t, address user) internal view returns (uint256) {
        IncentiveParams storage p = _paramSets[t.paramsId];
        if (!p.active) return 0;

        // Use max(lastAccrualTs, exitAccrualCheckpoint) to freeze accrual after light exit
        uint64 effectiveAccrualTs = t.lastAccrualTs;
        uint64 checkpoint = _exitAccrualCheckpoint[user];
        if (checkpoint > effectiveAccrualTs) {
            effectiveAccrualTs = checkpoint;
        }

        uint256 t1Days = _daysFrom(t.depositTs, effectiveAccrualTs);
        uint256 t2Days = _daysFrom(t.depositTs, uint64(block.timestamp));

        return _bonusAmount(t.principalWad, t1Days, t2Days, p);
    }

    /// @dev Closed-form bonus: principal * (F(t2) - F(t1)) / 365
    function _bonusAmount(
        uint256 principalWad,
        uint256 t1Days,
        uint256 t2Days,
        IncentiveParams storage p
    ) internal view returns (uint256) {
        if (t2Days <= t1Days) return 0;
        uint256 F1 = _antiderivative(t1Days, p);
        uint256 F2 = _antiderivative(t2Days, p);
        if (F2 <= F1) return 0;
        return FixedPoint.mulWadDown(principalWad, F2 - F1) / 365;
    }

    /// @dev Antiderivative F(t) of bonus APY curve
    function _antiderivative(uint256 tDays, IncentiveParams storage p) internal view returns (uint256) {
        uint256 Tc = p.cliffDays;
        uint256 Tf = p.fullDays;
        if (tDays <= Tc) return 0;
        if (Tf <= Tc) return 0; // safety

        uint256 m = FixedPoint.divWadDown(p.bmaxWad, (Tf - Tc) * WAD);

        if (tDays <= Tf) {
            uint256 dt = (tDays - Tc) * WAD;
            return (m * dt * dt) / (2 * WAD * WAD);
        } else {
            uint256 dtFull = (Tf - Tc) * WAD;
            uint256 rampArea = (m * dtFull * dtFull) / (2 * WAD * WAD);
            uint256 tailDays = (tDays - Tf) * WAD;
            uint256 tailArea = FixedPoint.mulWadDown(p.bmaxWad, tailDays);
            return rampArea + tailArea;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: FIFO CONSUMPTION
    // ═══════════════════════════════════════════════════════════════════════════

    function _consumeFIFO(address user, uint256 assetsToConsume) internal {
        DepositTranche[] storage tranches = _userTranches[user];
        uint256 remaining = assetsToConsume;

        for (uint256 i = 0; i < tranches.length && remaining > 0; i++) {
            if (!tranches[i].active) continue;

            uint256 consume = tranches[i].principalWad;
            if (consume > remaining) consume = remaining;

            tranches[i].lastAccrualTs = uint64(block.timestamp);
            tranches[i].principalWad -= uint128(consume);
            if (tranches[i].principalWad == 0) {
                tranches[i].active = false;
            }

            remaining -= consume;
            emit TrancheConsumed(user, i, uint128(consume));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: SLASH
    // ═══════════════════════════════════════════════════════════════════════════

    function _slashVestingProRata(address user, uint256 exitFractionWad)
        internal
        returns (uint256 totalSlashed)
    {
        RewardVestingTranche[] storage vestings = _userVestings[user];

        for (uint256 i = 0; i < vestings.length; i++) {
            if (!vestings[i].active) continue;

            uint256 unvested = _unvestedAmount(vestings[i]);
            if (unvested == 0) continue;

            uint256 slashAmount = FixedPoint.mulWadDown(unvested, exitFractionWad);
            if (slashAmount == 0) continue;

            // Reduce total reward units (the unvested portion shrinks)
            vestings[i].rewardUnits -= uint128(slashAmount);
            totalSlashed += slashAmount;

            emit RewardSlashed(user, i, uint128(slashAmount));

            // Full exit: close tranches with no remaining value
            if (exitFractionWad == WAD) {
                uint256 vestedRemainder = _vestedAvailable(vestings[i]);
                if (vestedRemainder == 0) {
                    vestings[i].active = false;
                }
            }
        }
    }

    function _unvestedAmount(RewardVestingTranche storage v) internal view returns (uint256) {
        uint256 totalVested = _totalVestedForTranche(v);
        uint256 remaining = v.rewardUnits > v.withdrawnUnits
            ? v.rewardUnits - v.withdrawnUnits : 0;
        uint256 availableVested = totalVested > v.withdrawnUnits
            ? totalVested - v.withdrawnUnits : 0;
        return remaining > availableVested ? remaining - availableVested : 0;
    }

    function _totalVestedForTranche(RewardVestingTranche storage v) internal view returns (uint256) {
        if (block.timestamp <= v.vestStart) return 0;
        uint256 elapsed = block.timestamp - v.vestStart;
        uint256 duration = uint256(v.vestDurationDays) * 1 days;
        if (elapsed >= duration) return v.rewardUnits;
        return (uint256(v.rewardUnits) * elapsed) / duration;
    }

    function _vestedAvailable(RewardVestingTranche storage v) internal view returns (uint256) {
        if (!v.active) return 0;
        uint256 totalVested = _totalVestedForTranche(v);
        return totalVested > v.withdrawnUnits ? totalVested - v.withdrawnUnits : 0;
    }

    function _totalVestedAvailable(address user) internal view returns (uint256 total) {
        RewardVestingTranche[] storage vestings = _userVestings[user];
        for (uint256 i = 0; i < vestings.length; i++) {
            total += _vestedAvailable(vestings[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: VESTING CREATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _createRewardVesting(address user, uint128 rewardUnits) internal {
        IncentiveParams storage p = _paramSets[currentParamsId];

        uint256 idx = _userVestings[user].length;
        _userVestings[user].push(RewardVestingTranche({
            rewardUnits: rewardUnits,
            vestStart: uint64(block.timestamp),
            vestDurationDays: p.vestingDays,
            withdrawnUnits: 0,
            paramsId: currentParamsId,
            mode: p.rewardMode,
            conversionRatio: uint128(WAD), // default 1:1, governable for MultyrToken
            active: true
        }));

        emit RewardVestingCreated(user, idx, rewardUnits, p.rewardMode);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: CONSOLIDATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _autoConsolidate(address user) internal {
        DepositTranche[] storage tranches = _userTranches[user];
        uint256 len = tranches.length;

        // Phase 1: Remove tombstones (inactive tranches) — compact array
        uint256 writeIdx = 0;
        for (uint256 readIdx = 0; readIdx < len; readIdx++) {
            if (tranches[readIdx].active) {
                if (writeIdx != readIdx) {
                    tranches[writeIdx] = tranches[readIdx];
                }
                writeIdx++;
            }
        }
        // Pop excess
        uint256 removed = len - writeIdx;
        for (uint256 i = 0; i < removed; i++) {
            tranches.pop();
        }

        if (removed > 0) {
            emit AutoConsolidationTriggered(user, len, tranches.length);
            emit TranchesConsolidated(user, removed, tranches.length);
        }

        // Phase 2: Merge active tranches with same paramsId
        // This bounds tranche count even when all tranches are active.
        // Strategy: merge adjacent same-paramsId tranches into one.
        // Use oldest depositTs (FIFO) and latest lastAccrualTs (no accrual loss).
        len = tranches.length;
        if (len > MAX_TRANCHES / 2) {
            writeIdx = 0;
            for (uint256 readIdx = 0; readIdx < len; readIdx++) {
                if (writeIdx > 0
                    && tranches[writeIdx - 1].paramsId == tranches[readIdx].paramsId
                    && tranches[readIdx].active)
                {
                    // Merge into previous: sum principal, keep oldest depositTs, latest accrualTs
                    tranches[writeIdx - 1].principalWad += tranches[readIdx].principalWad;
                    if (tranches[readIdx].lastAccrualTs > tranches[writeIdx - 1].lastAccrualTs) {
                        tranches[writeIdx - 1].lastAccrualTs = tranches[readIdx].lastAccrualTs;
                    }
                } else {
                    if (writeIdx != readIdx) {
                        tranches[writeIdx] = tranches[readIdx];
                    }
                    writeIdx++;
                }
            }
            removed = len - writeIdx;
            for (uint256 i = 0; i < removed; i++) {
                tranches.pop();
            }
            if (removed > 0) {
                emit TranchesConsolidated(user, removed, tranches.length);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _totalUserPrincipal(address user) internal view returns (uint256 total) {
        DepositTranche[] storage tranches = _userTranches[user];
        for (uint256 i = 0; i < tranches.length; i++) {
            if (tranches[i].active) total += tranches[i].principalWad;
        }
    }

    function _daysFrom(uint64 fromTs, uint64 toTs) internal pure returns (uint256) {
        if (toTs <= fromTs) return 0;
        return (toTs - fromTs) / 1 days;
    }

    function _validateParams(IncentiveParams memory p) internal pure {
        require(p.cliffDays > 0, "badCliff");
        require(p.fullDays > p.cliffDays, "fullDays<=cliffDays");
        require(p.bmaxWad <= 5e16, "bmaxWad>5%");
        require(p.vestingDays > 0 && p.vestingDays <= 365, "badVestingDays");
    }
}
