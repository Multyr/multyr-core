// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IParamsProvider } from "../../interfaces/IParamsProvider.sol";
import { IPriceOracleMiddleware } from "../../interfaces/IPriceOracleMiddleware.sol";
import { FixedPoint } from "../../libs/FixedPoint.sol";

/// @title OracleValuationLib — fresh-price fetch + USD<->asset-unit conversion
/// @notice Shared by any module that needs to compare a fixed-dollar constant (e.g. a
///         minimum move size or cost floor) against a raw asset-unit quantity. Mirrors
///         the freshness-check portion of StrategyRouter.checkOracleFreshness
///         (oracle-configured check, safe quote fetch, fresh flag, timestamp/staleness,
///         non-zero price) so all consumers fail closed the same way.
/// @dev Deliberately does NOT perform StrategyRouter's secondary-oracle deviation
///      cross-check — that relies on StrategyRouter-specific governance state
///      (secondaryOracle / maxOracleDeviationBps) not present in other modules.
library OracleValuationLib {
    error OracleNotConfigured(address asset);
    error OracleDataStale(address oracle, uint256 age, uint256 maxAge);
    error OracleCallFailed(address oracle, bytes revertData);

    /// @notice Fetch a fresh WAD (18-decimal) USD price for `asset`, reverting on any
    ///         staleness/misconfiguration — fail-closed by design.
    function getFreshPriceWad(IParamsProvider params, address asset, address vault)
        internal
        view
        returns (uint256 priceWad)
    {
        (address oracleAddr, uint256 maxStale) = params.oracleConfigFor(asset, vault);
        if (oracleAddr == address(0)) revert OracleNotConfigured(asset);

        IPriceOracleMiddleware.Quote memory quote = _safeGetQuote(oracleAddr, asset);

        if (!quote.fresh) {
            revert OracleDataStale(oracleAddr, block.timestamp - quote.lastUpdate, maxStale);
        }
        if (quote.lastUpdate > block.timestamp) {
            revert OracleDataStale(oracleAddr, type(uint256).max, maxStale);
        }
        uint256 age = block.timestamp - quote.lastUpdate;
        if (age > maxStale) revert OracleDataStale(oracleAddr, age, maxStale);
        if (quote.price == 0) revert OracleDataStale(oracleAddr, age, maxStale);

        priceWad = quote.price;
    }

    /// @notice Convert a WAD-scaled USD amount into the equivalent amount of the vault
    ///         asset's native units, given a fresh WAD USD price for one whole asset unit.
    function usdToAssetUnits(uint256 usdWad, uint256 priceWad, uint8 assetDecimals)
        internal
        pure
        returns (uint256)
    {
        return FixedPoint.mulDivDown(usdWad, 10 ** assetDecimals, priceWad);
    }

    /// @dev Safe wrapper for oracle.getQuote(asset). Never produces a bare 0x revert.
    function _safeGetQuote(address oracleAddr, address asset)
        private
        view
        returns (IPriceOracleMiddleware.Quote memory)
    {
        (bool ok, bytes memory data) =
            oracleAddr.staticcall(abi.encodeWithSignature("getQuote(address)", asset));
        if (!ok) revert OracleCallFailed(oracleAddr, data);
        if (data.length != 128) revert OracleCallFailed(oracleAddr, data);
        return abi.decode(data, (IPriceOracleMiddleware.Quote));
    }
}
