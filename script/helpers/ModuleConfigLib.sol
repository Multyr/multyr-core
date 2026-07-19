// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CoreVault } from "@multyr-core/core/CoreVault.sol";
import { SelectorLib } from "@multyr-core/core/libraries/SelectorLib.sol";
import { LiquidityOpsModule } from "@multyr-core/core/modules/LiquidityOpsModule.sol";

/// @title ModuleConfigLib -- CoreVault module routing helper
/// @notice Helper library for configuring CoreVault selector-to-module routing in deploy scripts.
/// @dev Used by DeployCoreSystem and DeployFixedMaturityVault. Pure internal library -- no deploy artifact.
/// @custom:chain-id 42161 (Arbitrum One)
library ModuleConfigLib {
    /// @notice Configure all module routing for a CoreVault
    function configureAllRouting(
        CoreVault router,
        address queueModule,
        address adminModule,
        address liquidityOpsModule
    ) internal {
        // Configure QueueModule selectors (PUBLIC)
        bytes4[] memory queueSels = SelectorLib.getQueueModuleSelectors();
        _setModulesBatch(router, queueSels, queueModule, SelectorLib.ROLE_PUBLIC);

        // Configure AdminModule owner selectors (OWNER)
        bytes4[] memory adminOwnerSels = SelectorLib.getAdminModuleOwnerSelectors();
        _setModulesBatch(router, adminOwnerSels, adminModule, SelectorLib.ROLE_OWNER);

        // Configure AdminModule view selectors (PUBLIC)
        bytes4[] memory adminViewSels = SelectorLib.getAdminModuleViewSelectors();
        _setModulesBatch(router, adminViewSels, adminModule, SelectorLib.ROLE_PUBLIC);

        // Configure LiquidityOpsModule selectors (mixed roles: deployToStrategiesWithPlan = OWNER_OR_GUARDIAN)
        bytes4[] memory liquidityOpsSels = SelectorLib.getLiquidityOpsModuleSelectors();
        uint256 loLen = liquidityOpsSels.length;
        address[] memory loModules = new address[](loLen);
        uint8[]   memory loRoles   = new uint8[](loLen);
        for (uint256 i; i < loLen; i++) {
            loModules[i] = liquidityOpsModule;
            loRoles[i] = liquidityOpsSels[i] == LiquidityOpsModule.deployToStrategiesWithPlan.selector
                ? SelectorLib.ROLE_OWNER_OR_GUARDIAN
                : SelectorLib.ROLE_PUBLIC;
        }
        router.setModulesBatch(liquidityOpsSels, loModules, loRoles);
    }

    /// @notice Helper to batch set modules with same module and role
    function _setModulesBatch(
        CoreVault router,
        bytes4[] memory selectors,
        address module,
        uint8 role
    ) internal {
        uint256 len = selectors.length;
        address[] memory modules = new address[](len);
        uint8[] memory roles = new uint8[](len);
        for (uint256 i; i < len; i++) {
            modules[i] = module;
            roles[i] = role;
        }
        router.setModulesBatch(selectors, modules, roles);
    }
}
