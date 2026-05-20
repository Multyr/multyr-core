// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import { Events } from "../libraries/Events.sol";
import { ParamsFrozen } from "../libraries/Errors.sol";
import { FixedPoint } from "../../libs/FixedPoint.sol";

/**
 * @title PerfFeeMixin
 * @notice Performance fee calculation using High Water Mark (HWM) mechanism
 *
 * @dev POLICY A - Donation = Profit (Accepted)
 *
 * Performance fee applies to ANY increase in totalAssets above HWM, regardless of source:
 * - Strategy profits (yield from Aave, Morpho, etc.)
 * - External donations (direct transfers to vault)
 * - Any other mechanism that increases totalAssets
 *
 * This is by design: the vault treats all asset increases equally. External donations
 * that inflate share price will trigger performance fee on the "profit" above HWM.
 *
 * Formula:
 *   pps = totalAssets / totalSupply (price per share, WAD scaled)
 *   IF pps > hwm:
 *     profit = totalAssets - (hwm * totalSupply)
 *     feeAssets = profit * rateX
 *     mint feeShares to feeCollector
 *     hwm = new pps
 *
 * This policy is documented and intentional. Auditors should verify this behavior
 * aligns with protocol economics expectations.
 */
abstract contract PerfFeeMixin {
    function _paramsFrozen() internal view virtual returns (bool);

    struct Perf {
        uint256 hwm;
        uint256 rateX;
        uint64 minInterval;
        uint64 last;
        bool init;
    }
    Perf public perf;

    function _initPerf(uint256 r, uint64 m) internal {
        perf.rateX = r;
        perf.minInterval = m;
        emit Events.PerfParamsSet(r, m);
    }

    function _setPerf(uint256 r, uint64 m) internal {
        if (_paramsFrozen()) revert ParamsFrozen();
        perf.rateX = r;
        perf.minInterval = m;
        emit Events.PerfParamsSet(r, m);
    }

    function _totalAssets() internal view virtual returns (uint256);
    function _totalSupply() internal view virtual returns (uint256);
    function _mintPerfShares(uint256 assets) internal virtual;

    function _pps() internal view returns (uint256) {
        uint256 ts = _totalSupply();
        return ts == 0 ? FixedPoint.WAD : FixedPoint.divWadDown(_totalAssets(), ts);
    }

    function _canCrystallize() internal view returns (bool) {
        Perf memory p = perf; // Cache storage to save ~3 SLOADs
        if (!p.init) return true;
        if (block.timestamp < p.last + p.minInterval) return false;
        return _pps() > p.hwm;
    }

    function _crystallize() internal returns (uint256 newHwm, uint256 feeAssets) {
        Perf memory p = perf; // Cache storage to save ~2 SLOADs
        uint256 ts = _totalSupply();
        if (ts == 0) {
            perf.hwm = FixedPoint.WAD;
            perf.init = true;
            perf.last = uint64(block.timestamp);
            emit Events.Crystallized(0, FixedPoint.WAD, 0);
            return (FixedPoint.WAD, 0);
        }
        uint256 pps = _pps();
        uint256 old = p.init ? p.hwm : FixedPoint.WAD;
        if (pps <= old) {
            perf.hwm = pps;
            perf.init = true;
            perf.last = uint64(block.timestamp);
            emit Events.Crystallized(old, pps, 0);
            return (pps, 0);
        }
        uint256 total = _totalAssets();
        uint256 oldAssets = FixedPoint.mulWadDown(old, ts);
        uint256 profit = total > oldAssets ? total - oldAssets : 0;
        feeAssets = FixedPoint.mulWadDown(profit, p.rateX);
        if (feeAssets > 0) {
            uint256 ppsBefore = _pps();
            uint256 oldH = old;
            _mintPerfShares(feeAssets);
            emit Events.PerfFeeMinted(oldH, ppsBefore, _totalSupply() - ts, _pps());
        }
        newHwm = _pps();
        perf.hwm = newHwm;
        perf.init = true;
        perf.last = uint64(block.timestamp);
        emit Events.Crystallized(old, newHwm, feeAssets);
    }
}
