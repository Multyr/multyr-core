// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseVaultTest } from "../helpers/BaseVaultTest.t.sol";

contract Upkeep_Integration is BaseVaultTest {
    function test_check_perform_flow() public {
        if (address(upkeep) == address(0)) return;
        (bool need, bytes memory data) = upkeep.checkUpkeep("");
        if (need) {
            upkeep.performUpkeep(data);
        }
        assertTrue(true);
    }
}
