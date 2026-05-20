// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title MerkleTreeHelper
/// @notice Simple library for building 2-4 leaf Merkle trees in Foundry tests
/// @dev Uses OpenZeppelin's sorted-pair hashing convention
library MerkleTreeHelper {
    /// @notice Build root from 2 leaves
    function buildRoot(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return _hashPair(a, b);
    }

    /// @notice Build root from 4 leaves
    function buildRoot(bytes32 a, bytes32 b, bytes32 c, bytes32 d) internal pure returns (bytes32) {
        bytes32 ab = _hashPair(a, b);
        bytes32 cd = _hashPair(c, d);
        return _hashPair(ab, cd);
    }

    /// @notice Get proof for leaf a in a 2-leaf tree [a, b]
    function proofForFirst(bytes32 b) internal pure returns (bytes32[] memory) {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        return proof;
    }

    /// @notice Get proof for leaf b in a 2-leaf tree [a, b]
    function proofForSecond(bytes32 a) internal pure returns (bytes32[] memory) {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = a;
        return proof;
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
