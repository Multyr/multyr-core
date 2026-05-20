// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Events } from "./Events.sol";

/// @title AdminLib
/// @notice Library for admin timelock functions - reduces CoreVault bytecode
/// @dev Uses internal functions that get inlined
library AdminLib {
    error EtaNotReached();
    error EtaExpired();
    error NotPending();
    error PerfRateTooHigh();

    uint64 internal constant MAX_WINDOW = 7 days;

    struct PendingFeeParams {
        uint16 dep;
        uint16 wit;
        address treasury;
        uint64 eta;
        bool exists;
    }

    struct PendingPerfParams {
        uint256 rateX;
        uint64 minInterval;
        uint64 eta;
        bool exists;
    }

    struct PendingMinDelay {
        uint64 newDelay;
        uint64 eta;
        bool exists;
    }

    /// @notice Validate that a pending change can be accepted
    function validateEta(uint64 eta, bool exists) internal view {
        if (!exists) revert NotPending();
        if (block.timestamp < eta) revert EtaNotReached();
        if (block.timestamp > eta + MAX_WINDOW) revert EtaExpired();
    }

    /// @notice Submit new fee params with timelock
    function submitFee(
        PendingFeeParams storage p,
        uint16 dep,
        uint16 wit,
        address treasury,
        uint64 delay
    ) internal {
        uint64 eta = uint64(block.timestamp) + delay;
        p.dep = dep;
        p.wit = wit;
        p.treasury = treasury;
        p.eta = eta;
        p.exists = true;
        emit Events.FeeParamsSubmitted(dep, wit, treasury, eta);
    }

    /// @notice Accept pending fee params
    function acceptFee(PendingFeeParams storage p)
        internal
        returns (uint16 dep, uint16 wit, address treasury)
    {
        validateEta(p.eta, p.exists);
        dep = p.dep;
        wit = p.wit;
        treasury = p.treasury;
        delete p.dep;
        delete p.wit;
        delete p.treasury;
        delete p.eta;
        p.exists = false;
        emit Events.FeeParamsAccepted(dep, wit, treasury);
    }

    /// @notice Revoke pending fee params
    function revokeFee(PendingFeeParams storage p) internal {
        delete p.dep;
        delete p.wit;
        delete p.treasury;
        delete p.eta;
        p.exists = false;
        emit Events.FeeParamsRevoked();
    }

    /// @notice Submit new perf params with timelock
    function submitPerf(
        PendingPerfParams storage p,
        uint256 rateX,
        uint64 minInterval,
        uint64 delay
    ) internal {
        if (rateX > 5e17) revert PerfRateTooHigh();
        uint64 eta = uint64(block.timestamp) + delay;
        p.rateX = rateX;
        p.minInterval = minInterval;
        p.eta = eta;
        p.exists = true;
        emit Events.PerfParamsSubmitted(rateX, minInterval, eta);
    }

    /// @notice Accept pending perf params
    function acceptPerf(PendingPerfParams storage p)
        internal
        returns (uint256 rateX, uint64 minInterval)
    {
        validateEta(p.eta, p.exists);
        rateX = p.rateX;
        minInterval = p.minInterval;
        delete p.rateX;
        delete p.minInterval;
        delete p.eta;
        p.exists = false;
        emit Events.PerfParamsAccepted(rateX, minInterval);
    }

    /// @notice Revoke pending perf params
    function revokePerf(PendingPerfParams storage p) internal {
        delete p.rateX;
        delete p.minInterval;
        delete p.eta;
        p.exists = false;
        emit Events.PerfParamsRevoked();
    }

    /// @notice Submit new delay with timelock
    function submitDelay(PendingMinDelay storage p, uint64 newDelay, uint64 currentDelay) internal {
        uint64 eta = uint64(block.timestamp) + currentDelay;
        p.newDelay = newDelay;
        p.eta = eta;
        p.exists = true;
    }

    /// @notice Accept pending delay
    function acceptDelay(PendingMinDelay storage p) internal returns (uint64 newDelay) {
        validateEta(p.eta, p.exists);
        newDelay = p.newDelay;
        delete p.newDelay;
        delete p.eta;
        p.exists = false;
    }

    /// @notice Revoke pending delay
    function revokeDelay(PendingMinDelay storage p) internal {
        delete p.newDelay;
        delete p.eta;
        p.exists = false;
    }
}
