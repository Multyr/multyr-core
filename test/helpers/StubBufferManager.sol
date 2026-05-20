// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";

/// @notice Minimal test-only BufferManager stub with fresh/valid warm NAV.
contract StubBufferManager is IBufferManager {
    function refreshWarmNav() external {}

    function warmNavState() external view returns (uint256, uint40, bool) {
        return (0, uint40(block.timestamp), true);
    }

    function prepareDeploy() external pure returns (uint256) { return 0; }
    function executeDeploy(uint256) external {}
    function refill(uint256) external {}
    function rebalance() external {}
    function updateConfig(BufferConfig calldata) external {}
    function setWarmAdapters(address[] calldata) external {}
    function setPaused(bool) external {}
    function getConfig() external view returns (BufferConfig memory c) { return c; }
    function hotBalance() external pure returns (uint256) { return 0; }
    function warmBalance() external pure returns (uint256) { return 0; }
    function totalBuffer() external pure returns (uint256) { return 0; }
    function plan() external pure returns (uint256, uint256) { return (0, 0); }
    function canRebalance() external pure returns (bool) { return false; }
    function getWarmAdapters() external pure returns (address[] memory) {
        return new address[](0);
    }
    function addWarmAdapter(address) external {}
    function removeWarmAdapter(uint256) external {}
    function forceRefill(uint256) external returns (bool, uint256) { return (false, 0); }
    function realizeForReserveAndOps(uint256) external returns (uint256) { return 0; }
}
