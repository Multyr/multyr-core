// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData);

    function performUpkeep(bytes calldata performData) external;
}

