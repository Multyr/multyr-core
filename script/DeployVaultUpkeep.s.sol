// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { VaultUpkeep } from "@multyr-core/automation/VaultUpkeep.sol";
import { BufferManager } from "@multyr-core/core/modules/BufferManager.sol";
import { ChainConfig } from "./config/ChainConfig.sol";

/// @title DeployVaultUpkeep -- OE VaultUpkeep standalone deploy
/// @notice Deploys a VaultUpkeep keeper for an existing OE CoreVault.
///         Run after DeployCoreSystem or DeployCoreIntegrated when upkeep was not included.
///         Grants no special permissions automatically -- caller must set BM keeper after deploy.
/// @dev Idempotent in the sense that deploying twice creates a second keeper; only one should
///      be registered with Chainlink at a time. Stateless: no storage, just constructor args.
/// @custom:chain-id Arbitrum One (42161), Base (8453), Ethereum Mainnet (1) -- see script/config/ChainConfig.sol
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, VAULT_ADDRESS, BUFFER_MANAGER_ADDRESS,
///                  STRATEGY_ROUTER_ADDRESS, GLOBAL_CONFIG_ADDRESS,
///                  DEFAULT_MAX_REALIZE (opt, default 1000000e6), DEFAULT_MAX_DEPLOY (opt, default 1000000e6),
///                  MIN_REALIZE_GAP_BPS (opt, default 10), MIN_REALIZE_FLOOR (opt, default 10000)
/// @custom:post-deploy 1) bufferManager.setKeeper(upkeep) -- caller must hold BM owner role
///                     2) upkeep.transferOwnership(timelock)
///                     3) Register on Chainlink Automation (forwarder address from registration)
contract DeployVaultUpkeep is Script {

    function run() external returns (VaultUpkeep upkeep) {
        ChainConfig.Config memory chain = ChainConfig.current();

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);

        address vault         = vm.envAddress("VAULT_ADDRESS");
        address bufferManager = vm.envAddress("BUFFER_MANAGER_ADDRESS");
        address strategyRouter = vm.envAddress("STRATEGY_ROUTER_ADDRESS");
        address globalConfig  = vm.envAddress("GLOBAL_CONFIG_ADDRESS");

        uint256 defaultMaxRealize = vm.envOr("DEFAULT_MAX_REALIZE",  uint256(1000000e6));
        uint256 defaultMaxDeploy  = vm.envOr("DEFAULT_MAX_DEPLOY",   uint256(1000000e6));
        uint256 minRealizeGapBps  = vm.envOr("MIN_REALIZE_GAP_BPS", uint256(10));
        uint256 minRealizeFloor   = vm.envOr("MIN_REALIZE_FLOOR",   uint256(10000));

        require(vault != address(0),          "VAULT_ADDRESS required");
        require(bufferManager != address(0),  "BUFFER_MANAGER_ADDRESS required");
        require(strategyRouter != address(0), "STRATEGY_ROUTER_ADDRESS required");
        require(globalConfig != address(0),   "GLOBAL_CONFIG_ADDRESS required");

        console.log("================================================================");
        console.log("   DEPLOY VAULT UPKEEP (OE standalone)");
        console.log("================================================================");
        console.log("Chain:            ", chain.chainName);
        console.log("Deployer:         ", deployer);
        console.log("Vault:            ", vault);
        console.log("BufferManager:    ", bufferManager);
        console.log("StrategyRouter:   ", strategyRouter);
        console.log("GlobalConfig:     ", globalConfig);
        console.log("defaultMaxRealize:", defaultMaxRealize);
        console.log("defaultMaxDeploy: ", defaultMaxDeploy);
        console.log("================================================================");

        vm.startBroadcast(deployerPk);

        upkeep = new VaultUpkeep(
            vault,
            bufferManager,
            strategyRouter,
            globalConfig,
            defaultMaxRealize,
            defaultMaxDeploy,
            uint16(minRealizeGapBps),
            minRealizeFloor
        );

        vm.stopBroadcast();

        console.log("");
        console.log("VaultUpkeep deployed:", address(upkeep));
        console.log("");
        console.log("NEXT STEPS:");
        console.log("  1. bufferManager.setKeeper(", address(upkeep), ")");
        console.log("     Requires: BufferManager owner or timelock");
        console.log("  2. upkeep.transferOwnership(<timelock>)");
        console.log("  3. Register on Chainlink Automation");
        console.log("     -> forwarder address from Chainlink registration");
        console.log("     -> no additional vault grants needed for VaultUpkeep");
    }
}
