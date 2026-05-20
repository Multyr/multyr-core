// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title RevertClassifier
/// @notice Classifies StrategyRouter errors for forceWithdraw error handling
/// @dev CRITICAL errors bubble up; non-critical errors convert to InsufficientLiquidity
/// @dev Used by ERC4626Module.forceWithdraw() to determine which router errors
///      represent safety invariants (must propagate) vs operational failures (can swallow)
library RevertClassifier {
    // ═══════════════════════════════════════════════════════════════════════════════
    // ERROR SELECTORS (computed via keccak256)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @dev LossCapExceeded(address,uint256,uint256,uint256) selector
    /// @dev This error indicates a per-strategy loss cap violation - CRITICAL
    bytes4 internal constant LOSS_CAP_EXCEEDED =
        bytes4(keccak256("LossCapExceeded(address,uint256,uint256,uint256)"));

    /// @dev AggregatedLossCapExceeded(uint256,uint256,uint256) selector
    /// @dev This error indicates aggregated batch loss cap violation - CRITICAL
    bytes4 internal constant AGGREGATED_LOSS_CAP_EXCEEDED =
        bytes4(keccak256("AggregatedLossCapExceeded(uint256,uint256,uint256)"));

    // ═══════════════════════════════════════════════════════════════════════════════
    // CLASSIFICATION FUNCTION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Check if a revert reason is a CRITICAL error that should bubble up
    /// @dev CRITICAL errors represent safety invariants that must not be silently swallowed
    /// @param reason The revert reason bytes from a failed external call
    /// @return critical True if the error should bubble up, false if it should be swallowed
    function isCritical(bytes memory reason) internal pure returns (bool critical) {
        // Need at least 4 bytes for a selector
        if (reason.length < 4) return false;

        bytes4 selector;
        assembly {
            // Load first 4 bytes of reason data (after length prefix at offset 32)
            selector := mload(add(reason, 32))
        }

        return selector == LOSS_CAP_EXCEEDED || selector == AGGREGATED_LOSS_CAP_EXCEEDED;
    }
}
