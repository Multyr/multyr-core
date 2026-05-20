// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AutomationCompatibleInterface } from "./AutomationCompatibleInterface.sol";
import { IFixedMaturityModule } from "../interfaces/IFixedMaturityModule.sol";
import { IFixedTermStrategy } from "../interfaces/IFixedTermStrategy.sol";
import { VaultMode, VaultState } from "../core/storage/FixedMaturityStorage.sol";
import { IQueueModule } from "../interfaces/IQueueModule.sol";

// ── Upkeep opcodes ────────────────────────────────────────────────────────────
uint8 constant OP_NONE            = 0;
uint8 constant OP_FM_START        = 1; // Funding -> Starting
uint8 constant OP_FM_FAIL         = 2; // Funding -> FundingFailed
uint8 constant OP_FM_ACTIVATE     = 3; // Starting -> Active (+ deploy via StrategyRouter)
uint8 constant OP_FM_MARK_MATURED = 4; // Active -> Matured
uint8 constant OP_FM_RECALL       = 5; // Matured: recall capital via Core -> Router -> Strategy
uint8 constant OP_FM_SETTLE       = 6; // Matured: settleFeesAndProcessQueue batch
uint8 constant OP_FM_CLOSE        = 7; // Matured -> Closed (pendingShares == 0)
uint8 constant OP_FM_MONITOR_ONLY = 8; // explicit no-op for monitoring

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
    uint32  public immutable maxSettleClaimsPerUpkeep;
    bool    public immutable strictMode;

    event FixedMaturityUpkeepChecked(uint8 indexed op, bool upkeepNeeded, uint8 indexed state);
    event FixedMaturityUpkeepPerformed(uint8 indexed op, uint8 indexed stateBefore, uint8 indexed stateAfter);
    event FixedMaturityUpkeepNoOp(uint8 indexed op, uint8 indexed state);

    constructor(address vault_, uint32 maxClaims_, bool strict_) {
        if (vault_ == address(0)) revert InvalidFixedMaturityVault();
        vault = vault_;
        maxSettleClaimsPerUpkeep = maxClaims_ == 0 ? 15 : maxClaims_;
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
            if (deadlinePassed && net < minFunds)  return (true, abi.encode(OP_FM_FAIL));
            return (false, "");
        }

        if (state == VaultState.Starting) {
            return (false, "");
        }

        if (state == VaultState.Active) {
            if (block.timestamp >= IFixedMaturityModule(vault).maturityTs()) {
                address strat = IFixedMaturityModule(vault).fixedTermStrategy();
                if (_stratIsMaturityReady(strat)) {
                    return (true, abi.encode(OP_FM_MARK_MATURED));
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
            uint256 pending = _pendingShares();
            if (pending > 0) return (true, abi.encode(OP_FM_SETTLE));
            return (false, "");
        }

        // FundingFailed, Closed → no upkeep
        return (false, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // performUpkeep
    // ═══════════════════════════════════════════════════════════════════════════

    function performUpkeep(bytes calldata performData) external override {
        uint8 op = abi.decode(performData, (uint8));
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
        } else if (op == OP_FM_SETTLE) {
            IQueueModule(vault).settleFeesAndProcessQueue(maxSettleClaimsPerUpkeep);
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

    function _pendingShares() internal view returns (uint256 pending) {
        (bool ok, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("pendingShares()")
        );
        if (ok && data.length == 32) pending = abi.decode(data, (uint256));
    }
}
