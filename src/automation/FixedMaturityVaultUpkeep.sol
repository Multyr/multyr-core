// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AutomationCompatibleInterface } from "./AutomationCompatibleInterface.sol";
import { IFixedMaturityModule } from "../interfaces/IFixedMaturityModule.sol";
import { IFixedTermStrategy } from "../interfaces/IFixedTermStrategy.sol";
import { VaultMode, VaultState } from "../core/storage/FixedMaturityStorage.sol";
import { EpochedQueueModule } from "../core/modules/EpochedQueueModule.sol";

// ── Upkeep opcodes ────────────────────────────────────────────────────────────
uint8 constant OP_NONE            = 0;
uint8 constant OP_FM_START        = 1; // Funding -> Starting
uint8 constant OP_FM_FAIL         = 2; // Funding -> FundingFailed
uint8 constant OP_FM_ACTIVATE     = 3; // Starting -> Active (+ deploy via StrategyRouter)
uint8 constant OP_FM_MARK_MATURED = 4; // Active -> Matured
uint8 constant OP_FM_RECALL       = 5; // Matured: recall capital via Core -> Router -> Strategy
uint8 constant OP_FM_EPOCH_CLOSE  = 6; // Matured: closeCurrentEpoch() (epoch-model queue)
uint8 constant OP_FM_EPOCH_FUND   = 7; // Matured: fundEpoch(oldestUnfundedEpochId)
uint8 constant OP_FM_CLOSE        = 8; // Matured -> Closed (outstandingClaimCount == 0)
uint8 constant OP_FM_MONITOR_ONLY = 9; // explicit no-op for monitoring

// ── Errors ────────────────────────────────────────────────────────────────────
error InvalidFixedMaturityVault();
error FixedMaturityAutomationDisabledForMode();
error UnknownOperation();

/// @title FixedMaturityVaultUpkeep — FM-only Chainlink Automation orchestrator
/// @notice Manages the full FixedMaturity lifecycle: Funding → Starting → Active → Matured → Closed.
///         Never calls open-ended ops (deploy, rebalance, harvest).
///         Never calls strategy addresses directly — always via IFixedMaturityModule.recallFixedTermCapital().
contract FixedMaturityVaultUpkeep is AutomationCompatibleInterface {

    address public immutable vault;
    bool    public immutable strictMode;

    // EPOCH_FUND stall backoff -- mirrors VaultUpkeep.sol's mechanism. In the
    // Matured state, EPOCH_FUND and EPOCH_CLOSE are the ONLY two ops, and
    // fundEpoch() can legitimately no-op forever under a persistent liquidity
    // shortfall. Without this, checkUpkeep's unconditional EPOCH_FUND
    // priority would starve EPOCH_CLOSE indefinitely for any claims
    // accumulating in the still-open epoch. No Ownable here, so the
    // threshold/backoff are fixed rather than governance-configurable.
    uint256 internal lastEpochFundTargetId = type(uint256).max;
    uint16  internal epochFundStallCount;
    uint64  internal lastEpochFundStallTs;
    uint16  internal constant EPOCH_FUND_STALL_THRESHOLD = 1;
    uint32  internal constant EPOCH_FUND_STALL_BACKOFF_SECONDS = 900; // 15min

    event FixedMaturityUpkeepChecked(uint8 indexed op, bool upkeepNeeded, uint8 indexed state);
    event FixedMaturityUpkeepPerformed(uint8 indexed op, uint8 indexed stateBefore, uint8 indexed stateAfter);
    event FixedMaturityUpkeepNoOp(uint8 indexed op, uint8 indexed state);

    constructor(address vault_, bool strict_) {
        if (vault_ == address(0)) revert InvalidFixedMaturityVault();
        vault = vault_;
        strictMode = strict_;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // checkUpkeep
    // ═══════════════════════════════════════════════════════════════════════════

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        (VaultMode mode, VaultState state) = IFixedMaturityModule(vault).currentVaultModeAndState();
        if (mode != VaultMode.FixedMaturity) return (false, "");

        if (state == VaultState.Funding) {
            uint64 deadline  = IFixedMaturityModule(vault).fundingDeadlineTs();
            uint256 net      = IFixedMaturityModule(vault).netFundedAssets();
            uint256 minFunds = IFixedMaturityModule(vault).minFundingAssets();
            bool deadlinePassed = block.timestamp >= deadline;
            if (deadlinePassed && net < minFunds)  return (true, abi.encode(OP_FM_FAIL, uint256(0)));
            return (false, "");
        }

        if (state == VaultState.Starting) {
            return (false, "");
        }

        if (state == VaultState.Active) {
            if (block.timestamp >= IFixedMaturityModule(vault).maturityTs()) {
                address strat = IFixedMaturityModule(vault).fixedTermStrategy();
                if (_stratIsMaturityReady(strat)) {
                    return (true, abi.encode(OP_FM_MARK_MATURED, uint256(0)));
                }
                return (false, "");
            }
            return (false, "");
        }

        if (state == VaultState.Matured) {
            address strat = IFixedMaturityModule(vault).fixedTermStrategy();
            // Once the matured strategy is fully drained, queue settlement must
            // resume even if the strategy continues to report "maturity ready".
            if (_stratWithdrawable(strat) > 0) return (false, "");

            // Priority: unlock a backlogged closed-but-unfunded epoch first —
            // fundEpoch() runs its own liquidity waterfall internally. Unless
            // this exact epoch already stalled past the threshold, in which
            // case yield to EPOCH_CLOSE for a cooldown window so claims
            // accumulating in the still-open epoch aren't blocked forever by
            // one persistently-underfunded epoch.
            uint256 oldestUnfunded = _oldestUnfundedEpochId();
            uint256 curEpoch = _currentEpochId();
            if (oldestUnfunded < curEpoch) {
                bool stalled = oldestUnfunded == lastEpochFundTargetId
                    && epochFundStallCount >= EPOCH_FUND_STALL_THRESHOLD
                    && block.timestamp < uint256(lastEpochFundStallTs) + uint256(EPOCH_FUND_STALL_BACKOFF_SECONDS);
                if (!stalled) {
                    return (true, abi.encode(OP_FM_EPOCH_FUND, oldestUnfunded));
                }
            }

            // Otherwise close the current epoch once its min duration has
            // elapsed, but only if it actually has claims (anti-churn).
            if (_canCloseCurrentEpoch() && _currentEpochClaimCount() > 0) {
                return (true, abi.encode(OP_FM_EPOCH_CLOSE, uint256(0)));
            }
            return (false, "");
        }

        // FundingFailed, Closed → no upkeep
        return (false, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // performUpkeep
    // ═══════════════════════════════════════════════════════════════════════════

    function performUpkeep(bytes calldata performData) external override {
        (uint8 op, uint256 arg) = _decode(performData);
        (, VaultState stateBefore) = IFixedMaturityModule(vault).currentVaultModeAndState();

        // Stale performData protection: mode must still be FixedMaturity
        (VaultMode mode,) = IFixedMaturityModule(vault).currentVaultModeAndState();
        if (mode != VaultMode.FixedMaturity) {
            if (strictMode) revert FixedMaturityAutomationDisabledForMode();
            emit FixedMaturityUpkeepNoOp(op, uint8(stateBefore));
            return;
        }

        if (op == OP_FM_START) {
            IFixedMaturityModule(vault).startFixedMaturityCycle();
        } else if (op == OP_FM_FAIL) {
            IFixedMaturityModule(vault).markFundingFailed();
        } else if (op == OP_FM_ACTIVATE) {
            IFixedMaturityModule(vault).activateFixedMaturityCycle();
        } else if (op == OP_FM_MARK_MATURED) {
            IFixedMaturityModule(vault).markMatured();
        } else if (op == OP_FM_RECALL) {
            // Always via Core → StrategyRouter → Strategy, never direct strategy call
            IFixedMaturityModule(vault).recallFixedTermCapital();
        } else if (op == OP_FM_EPOCH_CLOSE) {
            EpochedQueueModule(vault).closeCurrentEpoch();
        } else if (op == OP_FM_EPOCH_FUND) {
            // fundEpoch() runs its own warm-refill -> strategy-redeem waterfall
            // internally; a partial fund is retried next cycle, not a failure.
            EpochedQueueModule(vault).fundEpoch(arg);

            // Track whether this attempt made progress on the SAME target
            // epoch, so checkUpkeep can yield priority once it stalls.
            uint256 stillOldest = _oldestUnfundedEpochId();
            if (stillOldest == arg) {
                if (lastEpochFundTargetId == arg) {
                    epochFundStallCount++;
                } else {
                    lastEpochFundTargetId = arg;
                    epochFundStallCount = 1;
                }
                lastEpochFundStallTs = uint64(block.timestamp);
            } else {
                lastEpochFundTargetId = type(uint256).max;
                epochFundStallCount = 0;
            }
        } else if (op == OP_FM_CLOSE) {
            IFixedMaturityModule(vault).closeFixedMaturityCycle();
        } else if (op == OP_FM_MONITOR_ONLY) {
            // Explicit no-op — used when maturity time reached but strategy not ready
            emit FixedMaturityUpkeepNoOp(op, uint8(stateBefore));
            return;
        } else {
            revert UnknownOperation();
        }

        (, VaultState stateAfter) = IFixedMaturityModule(vault).currentVaultModeAndState();
        emit FixedMaturityUpkeepPerformed(op, uint8(stateBefore), uint8(stateAfter));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Internal view helpers (staticcall — no reverts allowed in checkUpkeep)
    // ═══════════════════════════════════════════════════════════════════════════

    function _stratWithdrawable(address strat) internal view returns (uint256 amount) {
        if (strat == address(0)) return 0;
        (bool ok, bytes memory data) = strat.staticcall(
            abi.encodeWithSignature("withdrawableAtMaturity()")
        );
        if (ok && data.length == 32) amount = abi.decode(data, (uint256));
    }

    function _stratIsMaturityReady(address strat) internal view returns (bool ready) {
        if (strat == address(0)) return false;
        (bool ok, bytes memory data) = strat.staticcall(
            abi.encodeWithSignature("isMaturityReady()")
        );
        if (ok && data.length == 32) ready = abi.decode(data, (bool));
    }

    function _oldestUnfundedEpochId() internal view returns (uint256 id) {
        (bool ok, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("oldestUnfundedEpochId()")
        );
        if (ok && data.length == 32) id = abi.decode(data, (uint256));
    }

    function _currentEpochId() internal view returns (uint256 id) {
        (bool ok, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("currentEpochId()")
        );
        if (ok && data.length == 32) id = abi.decode(data, (uint256));
    }

    function _canCloseCurrentEpoch() internal view returns (bool ready) {
        (bool ok, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("canCloseCurrentEpoch()")
        );
        if (ok && data.length == 32) ready = abi.decode(data, (bool));
    }

    function _currentEpochClaimCount() internal view returns (uint256 count) {
        (bool ok, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("currentEpochClaimCount()")
        );
        if (ok && data.length == 32) count = abi.decode(data, (uint256));
    }

    function _decode(bytes calldata data) internal pure returns (uint8 op, uint256 arg) {
        if (data.length == 32) {
            op = abi.decode(data, (uint8));
            return (op, 0);
        }
        (op, arg) = abi.decode(data, (uint8, uint256));
    }
}
