// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title FeeStorage
/// @notice Namespaced storage for fee parameters and pending timelock changes
/// @dev Uses EIP-7201 style storage location
library FeeStorage {
    // keccak256(abi.encode(uint256(keccak256("dsf.core.fee.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT =
        0x70739e319b75b4e5834916b9ca624fcbb6af45b4e67e7e365061fa4e1afc2100;

    struct InternalFeeParams {
        uint16 depBps; // Deposit fee in basis points
        uint16 witBps; // Withdrawal fee in basis points
        uint16 immediateExitPenaltyBps; // Additional penalty for immediate withdrawals (ERC4626Module only)
        uint16 forceExitPenaltyBps; // Additional penalty for force withdrawals (forceWithdraw only)
        address treasury; // Fee recipient (legacy, now feeCollector)
    }

    struct PendingFeeParams {
        uint16 dep;
        uint16 wit;
        uint16 immediateExitPenalty;
        uint16 forceExitPenalty; // Pending force exit penalty
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

    struct PendingBufferManager {
        address newBuffer;
        uint64 eta;
        bool exists;
    }

    struct PendingRouter {
        address newRouter;
        uint64 eta;
        bool exists;
    }

    struct Layout {
        InternalFeeParams fee;
        PendingFeeParams pendingFee;
        PendingPerfParams pendingPerf;
        PendingMinDelay pendingDelay;

        // Performance fee state
        uint256 perfRateX; // Performance fee rate (scaled)
        uint256 highWaterMark; // HWM for performance fee
        uint64 lastCrystallize; // Last crystallization timestamp
        uint64 minCrystallizeInterval;

        // Pending component changes (timelocked)
        PendingBufferManager pendingBuffer;
        PendingRouter pendingRouter;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
