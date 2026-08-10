// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPriceOracleMiddleware } from "../../src/interfaces/IPriceOracleMiddleware.sol";

/// @title MockPriceOracleMiddleware — settable per-asset WAD price + fresh/stale toggle
/// @notice Shared test double for anything consuming IPriceOracleMiddleware. Promoted
///         from the inline MockOracle in test/integration/CoreVault_KeeperRouting.t.sol
///         so decimals/oracle-normalization test suites can reuse one implementation.
contract MockPriceOracleMiddleware is IPriceOracleMiddleware {
    struct AssetState {
        uint256 priceWad;
        uint48 lastUpdate;
        bool fresh;
        bool set;
    }

    mapping(address => AssetState) public states;

    /// @notice Set a fresh WAD price for `asset`, timestamped now.
    function setPrice(address asset, uint256 priceWad) external {
        states[asset] = AssetState({ priceWad: priceWad, lastUpdate: uint48(block.timestamp), fresh: true, set: true });
    }

    /// @notice Mark `asset`'s price as stale without changing its value.
    function setStale(address asset) external {
        states[asset].fresh = false;
    }

    function getQuote(address asset) external view override returns (Quote memory) {
        AssetState memory s = states[asset];
        if (!s.set) revert OracleFeedNotSet();
        return Quote({ price: s.priceWad, decimals: 18, lastUpdate: s.lastUpdate, fresh: s.fresh });
    }

    function getQuoteFresh(address asset) external view override returns (Quote memory) {
        AssetState memory s = states[asset];
        if (!s.set) revert OracleFeedNotSet();
        if (!s.fresh) revert StalePrice();
        return Quote({ price: s.priceWad, decimals: 18, lastUpdate: s.lastUpdate, fresh: true });
    }

    function isFresh(address asset) external view override returns (bool) {
        return states[asset].fresh;
    }

    function getFeed(address) external pure override returns (address) {
        return address(0x1);
    }

    function getMaxStaleness(address) external pure override returns (uint256) {
        return 3600;
    }

    function owner() external pure override returns (address) {
        return address(0);
    }

    function setOracleFeed(address, address, uint256) external override { }
    function setMaxStaleness(address, uint256) external override { }
}
