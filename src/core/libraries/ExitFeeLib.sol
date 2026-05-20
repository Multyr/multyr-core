// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FeeStorage } from "../storage/FeeStorage.sol";
import { Percentage } from "../../libs/Percentage.sol";
import { FixedMaturityStorage, VaultMode, VaultState } from "../storage/FixedMaturityStorage.sol";

/// @title ExitFeeLib — Single source of truth for exit fee calculation
/// @notice Used by ERC4626Module, QueueModule, and AdminModule (forceWithdraw).
/// @dev CRITICAL: This library is the ONLY place where exit fees are computed.
///      ANY CHANGE to fee semantics MUST be made here and nowhere else.
///
///      Fee rules:
///        immediate exit (withdraw/redeem/requestClaim(true)):
///          feeBps = witBps + immediateExitPenaltyBps
///        queued exit (requestClaim(false)):
///          feeBps = witBps only
///        force exit (forceWithdraw):
///          feeBps = witBps + forceExitPenaltyBps
library ExitFeeLib {
    /// @notice Compute exit fee for a given gross asset amount
    /// @param grossAssets The gross assets being withdrawn (before fee)
    /// @param isImmediate True for instant withdraw/redeem/requestClaim(true)
    /// @param isForce True for forceWithdraw (admin only)
    /// @param fee The current fee parameters from FeeStorage
    /// @return totalFee Total fee in asset units
    /// @return withdrawFee Base withdrawal fee (witBps portion)
    /// @return penaltyFee Penalty fee (immediateExit or forceExit portion)
    function computeExitFee(
        uint256 grossAssets,
        bool isImmediate,
        bool isForce,
        FeeStorage.InternalFeeParams memory fee
    )
        internal
        view
        returns (uint256 totalFee, uint256 withdrawFee, uint256 penaltyFee)
    {
        withdrawFee = Percentage.mulBpsDown(grossAssets, fee.witBps);

        if (isImmediate) {
            penaltyFee = Percentage.mulBpsDown(grossAssets, fee.immediateExitPenaltyBps);
        } else if (isForce) {
            penaltyFee = Percentage.mulBpsDown(grossAssets, fee.forceExitPenaltyBps);
            // Additive pre-maturity penalty: only in FixedMaturity/Active, only on force path.
            FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
            if (fm.vaultMode == VaultMode.FixedMaturity && fm.vaultState == VaultState.Active) {
                penaltyFee += Percentage.mulBpsDown(grossAssets, uint16(fm.preMaturityForceExitPenaltyBps));
            }
        }
        // else: queued (non-immediate, non-force) → penaltyFee = 0

        totalFee = withdrawFee + penaltyFee;
    }

    /// @notice Compute total fee bps for a given exit type (useful for gross-from-net calculations)
    /// @param isImmediate True for instant exit
    /// @param isForce True for force exit
    /// @param fee The current fee parameters
    /// @return totalBps Total fee in basis points
    function exitFeeBps(
        bool isImmediate,
        bool isForce,
        FeeStorage.InternalFeeParams memory fee
    ) internal view returns (uint16 totalBps) {
        totalBps = fee.witBps;
        if (isImmediate) {
            totalBps += fee.immediateExitPenaltyBps;
        } else if (isForce) {
            totalBps += fee.forceExitPenaltyBps;
            FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
            if (fm.vaultMode == VaultMode.FixedMaturity && fm.vaultState == VaultState.Active) {
                totalBps += uint16(fm.preMaturityForceExitPenaltyBps);
            }
        }
    }
}
