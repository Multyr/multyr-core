// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { StrategyRouter } from "@multyr-core/core/modules/StrategyRouter.sol";
import { ChainConfig } from "./config/ChainConfig.sol";

/// @title DeployStrategyRouter -- standalone StrategyRouter redeploy
/// @notice Deploys a new StrategyRouter for an existing CoreVault + GlobalConfig.
///         Use for incident response or initial standalone deploy (separate from DeployCoreSystem).
///         After deploy, caller must re-register strategies and update ecosystem config.
/// @dev WARNING: Redeploying StrategyRouter clears strategy registry -- all strategies must be
///      re-registered via registerStrategy() after wiring. No state is migrated automatically.
/// @custom:chain-id Arbitrum One (42161), Base (8453), Ethereum Mainnet (1) -- see script/config/ChainConfig.sol
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, CORE_VAULT_ADDRESS, GLOBAL_CONFIG_ADDRESS
/// @custom:post-deploy 1) strategyRouter.setHealthRegistry(healthRegistry) -- requires SR owner
///                     2) vault.setEcosystem() with new SR address -- requires vault owner/timelock
///                     3) Re-register all strategies: strategyRouter.registerStrategy(...)
///                     4) strategyRouter.transferOwnership(timelock)
contract DeployStrategyRouter is Script {

    function run() external returns (StrategyRouter router) {
        ChainConfig.Config memory chain = ChainConfig.current();

        uint256 deployerPk   = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer     = vm.addr(deployerPk);
        address coreVault    = vm.envAddress("CORE_VAULT_ADDRESS");
        address globalConfig = vm.envAddress("GLOBAL_CONFIG_ADDRESS");

        require(coreVault != address(0),    "CORE_VAULT_ADDRESS required");
        require(globalConfig != address(0), "GLOBAL_CONFIG_ADDRESS required");

        console.log("================================================================");
        console.log("   DEPLOY STRATEGY ROUTER (standalone)");
        console.log("================================================================");
        console.log("Chain:        ", chain.chainName);
        console.log("Deployer:     ", deployer);
        console.log("CoreVault:    ", coreVault);
        console.log("GlobalConfig: ", globalConfig);
        console.log("================================================================");
        console.log("WARNING: Redeploying StrategyRouter clears strategy registry.");
        console.log("         All strategies must be re-registered after wiring.");
        console.log("================================================================");

        vm.startBroadcast(deployerPk);

        router = new StrategyRouter(deployer, coreVault, globalConfig);

        vm.stopBroadcast();

        console.log("StrategyRouter deployed:", address(router));
        console.log("");
        console.log("NEXT STEPS:");
        console.log("  1. strategyRouter.setHealthRegistry(<healthRegistry>)");
        console.log("  2. vault.setEcosystem() -- update strategyRouter to", address(router));
        console.log("  3. Re-register all strategies");
        console.log("  4. strategyRouter.transferOwnership(<timelock>)");
    }
}
