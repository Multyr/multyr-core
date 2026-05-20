// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CoreVault } from "@multyr-core/core/CoreVault.sol";
import { SelectorLib } from "@multyr-core/core/libraries/SelectorLib.sol";

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

        // Configure LiquidityOpsModule selectors (PUBLIC - keeper/permissionless)
        bytes4[] memory liquidityOpsSels = SelectorLib.getLiquidityOpsModuleSelectors();
        _setModulesBatch(router, liquidityOpsSels, liquidityOpsModule, SelectorLib.ROLE_PUBLIC);
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
