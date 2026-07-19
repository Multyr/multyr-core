// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DeployTypes } from "@multyr-core/libs/DeployTypes.sol";
import { CoreVault } from "@multyr-core/core/CoreVault.sol";
import { QueueModule } from "@multyr-core/core/modules/QueueModule.sol";
import { AdminModule } from "@multyr-core/core/modules/AdminModule.sol";
import { ERC4626Module } from "@multyr-core/core/modules/ERC4626Module.sol";
import { LiquidityOpsModule } from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import { IAdminModule } from "@multyr-core/interfaces/IAdminModule.sol";
import { SelectorLib } from "@multyr-core/core/libraries/SelectorLib.sol";
import { Events } from "@multyr-core/core/libraries/Events.sol";

library DeployLib {
    using DeployTypes for DeployTypes.DeployConfig;
    error ConfigZeroAddress();

    function decode(bytes memory initData)
        internal
        pure
        returns (DeployTypes.DeployConfig memory cfg)
    {
        cfg = abi.decode(initData, (DeployTypes.DeployConfig));
    }

    function deploy(
        DeployTypes.DeployConfig memory config,
        QueueModule queueModule,
        AdminModule adminModule,
        ERC4626Module erc4626Module,
        LiquidityOpsModule liquidityOpsModule
    ) internal returns (DeployTypes.DeployResult memory result) {
        return _deploy(
            config, queueModule, adminModule, erc4626Module, liquidityOpsModule, bytes32(0), false
        );
    }

    function deployDeterministic(
        DeployTypes.DeployConfig memory config,
        QueueModule queueModule,
        AdminModule adminModule,
        ERC4626Module erc4626Module,
        LiquidityOpsModule liquidityOpsModule,
        bytes32 salt
    ) internal returns (DeployTypes.DeployResult memory result) {
        return _deploy(
            config, queueModule, adminModule, erc4626Module, liquidityOpsModule, salt, true
        );
    }

    function _deploy(
        DeployTypes.DeployConfig memory config,
        QueueModule queueModule,
        AdminModule adminModule,
        ERC4626Module erc4626Module,
        LiquidityOpsModule liquidityOpsModule,
        bytes32 salt,
        bool useCreate2
    ) private returns (DeployTypes.DeployResult memory result) {
        if (address(config.asset) == address(0)) revert ConfigZeroAddress();
        if (config.owner == address(0)) revert ConfigZeroAddress();
        if (config.feeCollector == address(0)) revert ConfigZeroAddress();
        if (config.paramsProvider == address(0)) revert ConfigZeroAddress();

        CoreVault vault = useCreate2
            ? new CoreVault{
                salt: salt
            }(
                config.asset,
                config.name,
                config.symbol,
                address(this),
                config.feeCollector,
                config.paramsProvider
            )
            : new CoreVault(
                config.asset,
                config.name,
                config.symbol,
                address(this),
                config.feeCollector,
                config.paramsProvider
            );

        emit Events.VaultCreated(
            address(vault),
            address(config.asset),
            config.owner,
            config.feeCollector,
            config.name,
            config.symbol
        );

        // Wire all module selectors: Queue + Admin + ERC4626 + LiquidityOps
        _configureRouting(vault, queueModule, adminModule, erc4626Module, liquidityOpsModule);

        emit Events.VaultRoutingConfigured(
            address(vault), address(queueModule), address(adminModule)
        );

        // SelectorRegistry guardrail (must be set AFTER routing, BEFORE freeze)
        if (config.selectorRegistry != address(0)) {
            vault.setSelectorRegistry(config.selectorRegistry);
        }

        if (config.freezeRouting) {
            vault.freezeRouting();
        }

        IAdminModule(address(vault)).setEcosystem(config.ecosystem);

        // Inflation attack hardening -- seed dead deposit
        // Note: caller must have approved vault for deadDeposit amount of asset
        if (!IAdminModule(address(vault)).isDeadDepositDone()) {
            uint256 deadDepositAmount = 10_000_000; // 10 USDC (6 decimals)
            config.asset.approve(address(vault), deadDepositAmount);
            IAdminModule(address(vault)).seedDeadDeposit(deadDepositAmount);
        }

        // DeployVerify.verifyProductionReady: executed by multyr-deployment/script/lib/DeployVerify.sol

        emit Events.VaultProductionReady(address(vault));

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
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < queueViewSelectors.length;) {
            vault.setModule(queueViewSelectors[i], address(queueModule), SelectorLib.ROLE_PUBLIC);
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < adminOwnerSelectors.length;) {
            vault.setModule(adminOwnerSelectors[i], address(adminModule), SelectorLib.ROLE_OWNER);
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < adminViewSelectors.length;) {
            vault.setModule(adminViewSelectors[i], address(adminModule), SelectorLib.ROLE_PUBLIC);
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < erc4626Selectors.length;) {
            vault.setModule(erc4626Selectors[i], address(erc4626Module), SelectorLib.ROLE_PUBLIC);
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < liquidityOpsSelectors.length;) {
            uint8 role = liquidityOpsSelectors[i] == LiquidityOpsModule.deployToStrategiesWithPlan.selector
                ? SelectorLib.ROLE_OWNER_OR_GUARDIAN
                : SelectorLib.ROLE_PUBLIC;
            vault.setModule(liquidityOpsSelectors[i], address(liquidityOpsModule), role);
            unchecked {
                ++i;
            }
        }

        // Authorize ERC4626Module for processor calls (depositFor payer model)
        vault.authorizeModule(address(erc4626Module), true);
    }
}
