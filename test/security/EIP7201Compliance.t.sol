// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { CoreStorage } from "src/core/storage/CoreStorage.sol";
import { FeeStorage } from "src/core/storage/FeeStorage.sol";
import { QueueStorage } from "src/core/storage/QueueStorage.sol";
import { FixedMaturityStorage } from "src/core/storage/FixedMaturityStorage.sol";

/// @title EIP-7201 Compliance Test
/// @notice Verifies that all storage library SLOT constants are computed
///         according to the EIP-7201 formula:
///         SLOT = keccak256(abi.encode(uint256(keccak256(namespace)) - 1)) & ~bytes32(uint256(0xff))
contract EIP7201ComplianceTest is Test {
    function _eip7201Slot(string memory namespace) internal pure returns (bytes32) {
        uint256 inner = uint256(keccak256(bytes(namespace)));
        return keccak256(abi.encode(inner - 1)) & ~bytes32(uint256(0xff));
    }

    function test_CoreStorage_SLOT_matches_EIP7201() public {
        bytes32 expected = _eip7201Slot("dsf.core.main.storage.v1");
        assertEq(CoreStorage.SLOT, expected, "CoreStorage SLOT must match EIP-7201 formula");
    }

    function test_FeeStorage_SLOT_matches_EIP7201() public {
        bytes32 expected = _eip7201Slot("dsf.core.fee.storage.v1");
        assertEq(FeeStorage.SLOT, expected, "FeeStorage SLOT must match EIP-7201 formula");
    }

    function test_QueueStorage_SLOT_matches_EIP7201() public {
        bytes32 expected = _eip7201Slot("dsf.core.queue.storage.v1");
        assertEq(QueueStorage.SLOT, expected, "QueueStorage SLOT must match EIP-7201 formula");
    }

    function test_FixedMaturityStorage_SLOT_matches_EIP7201() public {
        bytes32 expected = _eip7201Slot("dsf.core.fixedmaturity.storage.v1");
        assertEq(FixedMaturityStorage.SLOT, expected, "FixedMaturityStorage SLOT must match EIP-7201 formula");
    }

    /// @notice Sanity check: no two namespaces produce colliding storage slots.
    function test_namespace_uniqueness() public {
        bytes32 a = _eip7201Slot("dsf.core.main.storage.v1");
        bytes32 b = _eip7201Slot("dsf.core.fee.storage.v1");
        bytes32 c = _eip7201Slot("dsf.core.queue.storage.v1");
        bytes32 d = _eip7201Slot("dsf.core.fixedmaturity.storage.v1");
        assertTrue(a != b && a != c && a != d && b != c && b != d && c != d, "namespaces must be unique");
    }
}
