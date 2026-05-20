// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import { Events } from "../libraries/Events.sol";
import { ParamsFrozen, RecipientFrozen } from "../libraries/Errors.sol";
import { Percentage } from "../../libs/Percentage.sol";

abstract contract FeeMixin {
    error FeeCapExceeded();
    function _paramsFrozen() internal view virtual returns (bool);

    struct InternalFeeParams {
        uint16 depBps;
        uint16 witBps;
        address treasury;
        bool recipientFrozen;
    }
    InternalFeeParams public fee;

    function _setFeeParams(uint16 d, uint16 w, address t) internal {
        if (_paramsFrozen()) revert ParamsFrozen();
        InternalFeeParams memory f = fee; // Cache storage to save ~2 SLOADs
        if (f.recipientFrozen && t != f.treasury) revert RecipientFrozen();
        if (d > 1000 || w > 1000) revert FeeCapExceeded();
        fee = InternalFeeParams(d, w, t, f.recipientFrozen);
        emit Events.DepositFeeParamsSet(d, w, t);
    }

    function _applyDepositFee(uint256 assets) internal view returns (uint256 net, uint256 feeA) {
        feeA = Percentage.mulBpsDown(assets, fee.depBps);
        net = assets - feeA;
    }

    function _applyWithdrawFee(uint256 gross) internal view returns (uint256 net, uint256 feeA) {
        feeA = Percentage.mulBpsDown(gross, fee.witBps);
        net = gross - feeA;
    }
}
