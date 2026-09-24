// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";

/// @title MockBufferManagerForTests
/// @notice Configurable mock BufferManager for test harness.
/// @dev DEFAULT: warmNavState returns (0, block.timestamp, true) — fresh + valid.
///      Use setters to inject fault conditions for NAV refresh testing.
///
///      This is a TEST HARNESS DEFAULT, not a production simulation.
///      For NAV-specific behavior tests, use the dedicated suites:
///      - CoreVault_AutoRefreshWarmNav.t.sol
///      - CoreVault_WithdrawWarmNavInvariant.t.sol
///      - BufferManager_RefreshWarmNav.t.sol
contract MockBufferManagerForTests is IBufferManager {
    // Configurable state
    uint256 private _nav;
    uint40 private _ts;
    bool private _valid = true;
    /// @dev Simulates a keeper that keeps the warm NAV cache perpetually fresh:
    ///      warmNavState() reports `block.timestamp` while true. Requests now
    ///      revert on a stale cache (spec §8), so tests that warp time would
    ///      otherwise all need a manual refresh. Any explicit setter below
    ///      switches it off, so tests that inject a specific timestamp/validity
    ///      get exactly what they set.
    bool private _autoFresh = true;
    bool private _refreshShouldRevert;
    uint256 private _refreshNav;
    uint40 private _refreshTs;
    bool private _refreshValid = true;
    bool private _hasRefreshOverride;
    BufferConfig private _config;

    address public immutable core;

    constructor(address core_) {
        core = core_;
        _ts = uint40(block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONFIGURABLE SETTERS (for tests that need non-default behavior)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set warm NAV state directly
    function setAutoFresh(bool on) external {
        _autoFresh = on;
    }

    function setWarmNav(uint256 nav_, uint40 ts_, bool valid_) external {
        _autoFresh = false;
        _nav = nav_;
        _ts = ts_;
        _valid = valid_;
    }

    /// @notice Make refreshWarmNav() revert
    function setRefreshShouldRevert(bool shouldRevert_) external {
        _autoFresh = false;
        _refreshShouldRevert = shouldRevert_;
    }

    /// @notice Set what refreshWarmNav() will produce after being called
    function setRefreshResult(uint256 nav_, uint40 ts_, bool valid_) external {
        _autoFresh = false;
        _hasRefreshOverride = true;
        _refreshNav = nav_;
        _refreshTs = ts_;
        _refreshValid = valid_;
    }

    /// @notice Set the buffer config returned by getConfig()
    function setBufferConfig(BufferConfig calldata cfg_) external {
        _config = cfg_;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IBufferManager IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════

    function warmNavState() external view override returns (uint256 nav, uint40 ts, bool valid) {
        return (_nav, _autoFresh ? uint40(block.timestamp) : _ts, _valid);
    }

    function refreshWarmNav() external override {
        if (_refreshShouldRevert) revert("MockBM: refresh reverted");
        if (_hasRefreshOverride) {
            _nav = _refreshNav;
            _ts = _refreshTs;
            _valid = _refreshValid;
        } else {
            // Default: just update timestamp to now (simulates successful refresh)
            _ts = uint40(block.timestamp);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MINIMAL STUBS (required by IBufferManager but not used in most tests)
    // ═══════════════════════════════════════════════════════════════════════

    function getConfig() external view override returns (BufferConfig memory cfg) {
        return _config;
    }

    function hotBalance() external pure override returns (uint256) { return 0; }
    function warmBalance() external pure override returns (uint256) { return 0; }
    function totalBuffer() external pure override returns (uint256) { return 0; }
    function plan() external pure override returns (uint256, uint256) { return (0, 0); }
    function rebalance() external override {}
    function canRebalance() external pure override returns (bool) { return false; }
    function refill(uint256) external override {}
    function prepareDeploy() external pure override returns (uint256) { return 0; }
    function executeDeploy(uint256) external override {}
    function updateConfig(BufferConfig calldata) external override {}
    function setWarmAdapters(address[] calldata) external override {}
    function getWarmAdapters() external pure override returns (address[] memory) {
        return new address[](0);
    }
    function addWarmAdapter(address) external override {}
    function removeWarmAdapter(uint256) external override {}
    function setPaused(bool) external override {}
    function forceRefill(uint256) external override returns (bool, uint256) { return (false, 0); }
    function realizeForReserveAndOps(uint256) external override returns (uint256) { return 0; }
}
