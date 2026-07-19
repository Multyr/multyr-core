// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title IncentivesTimelock
/// @notice Thin wrapper around OpenZeppelin TimelockController to govern Incentives params via timelock + multisig.
/// - Deploy this timelock with a multisig (or set of proposers) and desired executors.
/// - Transfer ownership of Incentives to this timelock (call module.transferOwnership(timelock)).
/// - From the multisig, schedule and execute setParams/setActive/setTreasury/setCore on the module via the timelock.
contract IncentivesTimelock is TimelockController {
    /// @param minDelay Minimum delay (in seconds) before an operation can be executed.
    /// @param proposers Addresses allowed to propose operations (e.g., multisig address).
    /// @param executors Addresses allowed to execute operations (can be a specific ops address or address(0) for open execution).
    /// @param admin Optional admin for timelock setup (can be address(0)); after construction, the admin role is recommended to be renounced.
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) { }

    // --- Debug helpers (do not alter core logic) ---
    function opId(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external pure returns (bytes32) {
        // Mirrors OZ hashOperation: keccak(target, value, keccak256(data), predecessor, salt)
        return keccak256(abi.encode(target, value, keccak256(data), predecessor, salt));
    }

    function opState(bytes32 id)
        external
        view
        returns (bool scheduled, bool ready, uint256 when, uint256 nowTs)
    {
        uint256 t = getTimestamp(id);
        scheduled = t != 0;
        ready = scheduled && t <= block.timestamp;
        when = t;
        nowTs = block.timestamp;
    }
}
