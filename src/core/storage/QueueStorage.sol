// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title QueueStorage
/// @notice Namespaced storage for queue/claims functionality
/// @dev Uses EIP-7201 style storage location
library QueueStorage {
    // keccak256(abi.encode(uint256(keccak256("dsf.core.queue.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT =
        0x20afa2de85fad1e68653d750134f8c4543e7db931009cedccc72142811c77f00;

    /// @notice Claim struct - optimized packing for gas efficiency
    /// @dev Layout: slot0 = user (20 bytes) + ts (8 bytes) + immediate (1 byte) + settled (1 byte) = 30 bytes
    ///              slot1 = shares (32 bytes)
    /// Reordered for optimal packing: address + uint64 + bool + bool fit in one slot
    struct Claim {
        address user; // 20 bytes
        uint64 ts; // 8 bytes  (packed with user)
        bool immediate; // 1 byte   (packed with user, ts)
        bool settled; // 1 byte   (packed with user, ts, immediate)
        uint256 shares; // 32 bytes (separate slot)
    }

    struct Layout {
        uint256[] queue; // Array of claim IDs
        uint256 head; // First valid index (for compaction)
        uint256 nextClaimId; // Auto-increment claim ID
        uint256 pendingShares; // Total shares in queue
        mapping(uint256 => Claim) claims; // claimId => Claim
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
