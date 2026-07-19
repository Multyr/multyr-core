// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Minimal Chainlink Automation-compatible interface used by VaultUpkeep.
/// Declared as 'view' on checkUpkeep to match our implementation signatures.
interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData);

    function performUpkeep(bytes calldata performData) external;
}
