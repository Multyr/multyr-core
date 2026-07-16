// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BaseVaultTest } from "../../helpers/BaseVaultTest.t.sol";

contract CoreVault_ViewsAutomation is BaseVaultTest {
    function test_views_CompileAndReturn() public view {
        vault.canSettle();
        vault.canCrystallize();
        vault.canRealize();
        vault.totalAssets();
    }
}
