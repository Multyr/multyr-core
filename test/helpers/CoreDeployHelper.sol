// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DeployTypes } from "../../src/libs/DeployTypes.sol";
import { CoreVault } from "../../src/core/CoreVault.sol";
import { QueueModule } from "../../src/core/modules/QueueModule.sol";
import { AdminModule } from "../../src/core/modules/AdminModule.sol";
import { ERC4626Module } from "../../src/core/modules/ERC4626Module.sol";
import { LiquidityOpsModule } from "../../src/core/modules/LiquidityOpsModule.sol";
import { IAdminModule } from "../../src/interfaces/IAdminModule.sol";
import { SelectorLib } from "../../src/core/libraries/SelectorLib.sol";

/// @dev Test-only deploy helper — mirrors DeployLib.deploy() without script/lib imports.
///      Omits DeployVerify.verifyProductionReady() (not required in test context).
///      Single source of truth for vault deployment wiring in integration tests.
library CoreDeployHelper {
    error ConfigZeroAddress();

    function deploy(
        DeployTypes.DeployConfig memory config,
        QueueModule queueModule,
        AdminModule adminModule,
        ERC4626Module erc4626Module,
        LiquidityOpsModule liquidityOpsModule
    ) internal returns (DeployTypes.DeployResult memory result) {
        if (address(config.asset) == address(0)) revert ConfigZeroAddress();
        if (config.owner == address(0)) revert ConfigZeroAddress();
        if (config.feeCollector == address(0)) revert ConfigZeroAddress();
        if (config.paramsProvider == address(0)) revert ConfigZeroAddress();

        CoreVault vault = new CoreVault(
            config.asset,
            config.name,
            config.symbol,
            address(this),
            config.feeCollector,
            config.paramsProvider
        );

        _configureRouting(vault, queueModule, adminModule, erc4626Module, liquidityOpsModule);

        if (config.selectorRegistry != address(0)) {
            vault.setSelectorRegistry(config.selectorRegistry);
        }

        if (config.freezeRouting) {
            vault.freezeRouting();
        }

        IAdminModule(address(vault)).setEcosystem(config.ecosystem);

        if (!IAdminModule(address(vault)).isDeadDepositDone()) {
            uint256 deadDepositAmount = 10_000_000; // 10 USDC (6 decimals)
            config.asset.approve(address(vault), deadDepositAmount);
            IAdminModule(address(vault)).seedDeadDeposit(deadDepositAmount);
        }

        vault.beginOwnerTransfer(config.owner);

        result.vault = vault;
        result.queueModule = queueModule;
        result.adminModule = adminModule;
        result.erc4626Module = erc4626Module;
        result.liquidityOpsModule = liquidityOpsModule;
    }

    function _configureRouting(
        CoreVault vault,
        QueueModule queueModule,
        AdminModule adminModule,
        ERC4626Module erc4626Module,
        LiquidityOpsModule liquidityOpsModule
    ) private {
        bytes4[] memory queueSelectors = SelectorLib.getQueueModuleSelectors();
        bytes4[] memory queueViewSelectors = SelectorLib.getQueueModuleViewSelectors();
        bytes4[] memory adminOwnerSelectors = SelectorLib.getAdminModuleOwnerSelectors();
        bytes4[] memory adminViewSelectors = SelectorLib.getAdminModuleViewSelectors();
        bytes4[] memory erc4626Selectors = SelectorLib.getERC4626ModuleSelectors();
        bytes4[] memory liquidityOpsSelectors = SelectorLib.getLiquidityOpsModuleSelectors();

        for (uint256 i; i < queueSelectors.length;) {
            vault.setModule(queueSelectors[i], address(queueModule), SelectorLib.ROLE_PUBLIC);
            unchecked { ++i; }
        }
        for (uint256 i; i < queueViewSelectors.length;) {
            vault.setModule(queueViewSelectors[i], address(queueModule), SelectorLib.ROLE_PUBLIC);
            unchecked { ++i; }
        }
        for (uint256 i; i < adminOwnerSelectors.length;) {
            vault.setModule(adminOwnerSelectors[i], address(adminModule), SelectorLib.ROLE_OWNER);
            unchecked { ++i; }
        }
        for (uint256 i; i < adminViewSelectors.length;) {
            vault.setModule(adminViewSelectors[i], address(adminModule), SelectorLib.ROLE_PUBLIC);
            unchecked { ++i; }
        }
        for (uint256 i; i < erc4626Selectors.length;) {
            vault.setModule(erc4626Selectors[i], address(erc4626Module), SelectorLib.ROLE_PUBLIC);
            unchecked { ++i; }
        }
        for (uint256 i; i < liquidityOpsSelectors.length;) {
            vault.setModule(liquidityOpsSelectors[i], address(liquidityOpsModule), SelectorLib.ROLE_PUBLIC);
            unchecked { ++i; }
        }

        vault.authorizeModule(address(erc4626Module), true);
    }
}
