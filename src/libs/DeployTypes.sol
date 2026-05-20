// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreVault } from "../core/CoreVault.sol";
import { QueueModule } from "../core/modules/QueueModule.sol";
import { AdminModule } from "../core/modules/AdminModule.sol";
import { ERC4626Module } from "../core/modules/ERC4626Module.sol";
import { LiquidityOpsModule } from "../core/modules/LiquidityOpsModule.sol";
import { IAdminModule } from "../interfaces/IAdminModule.sol";

library DeployTypes {
    struct DeployConfig {
        IERC20Metadata asset;
        string name;
        string symbol;
        address owner;
        address feeCollector;
        address paramsProvider;
        IAdminModule.EcosystemConfig ecosystem;
        bool freezeRouting;
        address selectorRegistry; // address(0) = skip guardrail
    }

    struct DeployResult {
        CoreVault vault;
        QueueModule queueModule;
        AdminModule adminModule;
        ERC4626Module erc4626Module;
        LiquidityOpsModule liquidityOpsModule;
    }
}
