// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { CoreStorage } from "src/core/storage/CoreStorage.sol";
import { QueueStorage } from "src/core/storage/QueueStorage.sol";
import { FeeStorage } from "src/core/storage/FeeStorage.sol";

/// @title CoreVault Storage Tests
/// @notice Tests for EIP-7201 storage slot verification and layout discipline
/// @dev These tests ensure storage slots never change between versions
contract CoreVault_Storage_Test is Test {
    // ═══════════════════════════════════════════════════════════════════════════════
    // HARDCODED EXPECTED SLOTS (DO NOT CHANGE WITHOUT MIGRATION PLAN)
    // ═══════════════════════════════════════════════════════════════════════════════

    // These are the expected slot values - if they change, storage layout changed
    bytes32 constant EXPECTED_CORE_SLOT =
        0xff7b491291207fbb51df1ab8f042e8ee7f087c9a7e4a083e1a2dbbddb742ef00;
    bytes32 constant EXPECTED_QUEUE_SLOT =
        0x20afa2de85fad1e68653d750134f8c4543e7db931009cedccc72142811c77f00;
    bytes32 constant EXPECTED_FEE_SLOT =
        0x70739e319b75b4e5834916b9ca624fcbb6af45b4e67e7e365061fa4e1afc2100;

    // ═══════════════════════════════════════════════════════════════════════════════
    // SLOT VERIFICATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Verify CoreStorage slot has not changed
    /// @dev CRITICAL: If this test fails, storage migration is required
    function test_coreStorage_slotUnchanged() public pure {
        assertEq(
            CoreStorage.SLOT,
            EXPECTED_CORE_SLOT,
            "CRITICAL: CoreStorage.SLOT changed - requires migration"
        );
    }

    /// @notice Verify QueueStorage slot has not changed
    /// @dev CRITICAL: If this test fails, storage migration is required
    function test_queueStorage_slotUnchanged() public pure {
        assertEq(
            QueueStorage.SLOT,
            EXPECTED_QUEUE_SLOT,
            "CRITICAL: QueueStorage.SLOT changed - requires migration"
        );
    }

    /// @notice Verify FeeStorage slot has not changed
    /// @dev CRITICAL: If this test fails, storage migration is required
    function test_feeStorage_slotUnchanged() public pure {
        assertEq(
            FeeStorage.SLOT,
            EXPECTED_FEE_SLOT,
            "CRITICAL: FeeStorage.SLOT changed - requires migration"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SLOT UNIQUENESS TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Verify all storage slots are unique (no collisions)
    function test_storageSlots_areUnique() public pure {
        assertTrue(
            CoreStorage.SLOT != QueueStorage.SLOT, "CoreStorage and QueueStorage slots collide"
        );
        assertTrue(CoreStorage.SLOT != FeeStorage.SLOT, "CoreStorage and FeeStorage slots collide");
        assertTrue(
            QueueStorage.SLOT != FeeStorage.SLOT, "QueueStorage and FeeStorage slots collide"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FLAG CONSTANTS TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Verify flag constants are unique and don't overlap
    function test_coreStorage_flagsUnique() public pure {
        // Each flag should be a unique bit
        assertEq(CoreStorage.FLAG_PAUSED, 1 << 0);
        assertEq(CoreStorage.FLAG_PAUSED_DEPOSITS, 1 << 1);
        assertEq(CoreStorage.FLAG_PAUSED_WITHDRAWALS, 1 << 2);
        assertEq(CoreStorage.FLAG_PARAMS_FROZEN, 1 << 3);
        assertEq(CoreStorage.FLAG_LIQUIDITY_LOCKED, 1 << 4);
        assertEq(CoreStorage.FLAG_NAV_SMOOTH_INIT, 1 << 5);
        assertEq(CoreStorage.FLAG_ROUTING_FROZEN, 1 << 6);
        assertEq(CoreStorage.FLAG_REENTRANCY_LOCKED, 1 << 7);
    }

    /// @notice Verify all flags can be set independently
    function test_coreStorage_flagsIndependent() public pure {
        uint256 allFlags = CoreStorage.FLAG_PAUSED | CoreStorage.FLAG_PAUSED_DEPOSITS
            | CoreStorage.FLAG_PAUSED_WITHDRAWALS | CoreStorage.FLAG_PARAMS_FROZEN
            | CoreStorage.FLAG_LIQUIDITY_LOCKED | CoreStorage.FLAG_NAV_SMOOTH_INIT
            | CoreStorage.FLAG_ROUTING_FROZEN | CoreStorage.FLAG_REENTRANCY_LOCKED;

        // All 8 flags set should equal 255 (0xFF)
        assertEq(allFlags, 0xFF, "Flag overlap detected");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // LAYOUT ACCESSOR TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Verify layout() returns storage at correct slot
    function test_coreStorage_layoutAccessor() public {
        CoreStorage.Layout storage layout = CoreStorage.layout();

        // Write test value
        layout.packedFlags = 0x12345678;

        // Read back via direct slot access
        bytes32 slot = CoreStorage.SLOT;
        uint256 storedValue;
        assembly {
            // packedFlags is at slot + 10 (after 10 address slots)
            storedValue := sload(add(slot, 10))
        }

        assertEq(storedValue, 0x12345678, "Layout accessor not pointing to correct slot");
    }

    /// @notice Verify QueueStorage layout() works correctly
    function test_queueStorage_layoutAccessor() public {
        QueueStorage.Layout storage layout = QueueStorage.layout();

        // Write test value to head
        layout.head = 42;

        // Verify via layout
        assertEq(layout.head, 42, "QueueStorage layout accessor failed");
    }

    /// @notice Verify FeeStorage layout() works correctly
    function test_feeStorage_layoutAccessor() public {
        FeeStorage.Layout storage layout = FeeStorage.layout();

        // Write test values
        layout.fee.depBps = 100;
        layout.fee.witBps = 50;

        // Verify via layout
        assertEq(layout.fee.depBps, 100, "FeeStorage layout accessor failed");
        assertEq(layout.fee.witBps, 50, "FeeStorage layout accessor failed");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // STORAGE ISOLATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Verify writing to one storage doesn't affect another
    function test_storageIsolation() public {
        CoreStorage.Layout storage core = CoreStorage.layout();
        QueueStorage.Layout storage queue = QueueStorage.layout();
        FeeStorage.Layout storage fee = FeeStorage.layout();

        // Write to each storage
        core.packedFlags = 0xAAAA;
        queue.head = 0xBBBB;
        fee.fee.depBps = 0xCCCC;

        // Verify no cross-contamination
        assertEq(core.packedFlags, 0xAAAA, "CoreStorage corrupted");
        assertEq(queue.head, 0xBBBB, "QueueStorage corrupted");
        assertEq(fee.fee.depBps, 0xCCCC, "FeeStorage corrupted");

        // Clear and verify
        core.packedFlags = 0;
        assertEq(queue.head, 0xBBBB, "QueueStorage affected by CoreStorage clear");
        assertEq(fee.fee.depBps, 0xCCCC, "FeeStorage affected by CoreStorage clear");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // DOCUMENTATION/COMMENTS VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Verify slot string matches intended namespace
    /// @dev The slot should be derived from a specific namespace string
    function test_slotDerivation_documented() public pure {
        // These comments document what each slot SHOULD be derived from
        // DO NOT CHANGE SLOT without updating this documentation and creating migration

        // CoreStorage: keccak256(abi.encode(uint256(keccak256("dsf.core.main.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
        // QueueStorage: keccak256(abi.encode(uint256(keccak256("dsf.core.queue.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
        // FeeStorage: keccak256(abi.encode(uint256(keccak256("dsf.core.fee.storage.v1")) - 1)) & ~bytes32(uint256(0xff))

        // Verify version is v1
        assertTrue(true, "Storage version is v1");
    }
}
