// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { StrategyRouter } from "@multyr-core/core/modules/StrategyRouter.sol";

/// @title DeployStrategyRouter -- standalone StrategyRouter redeploy
/// @notice Deploys a new StrategyRouter for an existing CoreVault + GlobalConfig.
///         Use for incident response or initial standalone deploy (separate from DeployCoreSystem).
///         After deploy, caller must re-register strategies and update ecosystem config.
/// @dev WARNING: Redeploying StrategyRouter clears strategy registry -- all strategies must be
///      re-registered via registerStrategy() after wiring. No state is migrated automatically.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, CORE_VAULT_ADDRESS, GLOBAL_CONFIG_ADDRESS
/// @custom:post-deploy 1) strategyRouter.setHealthRegistry(healthRegistry) -- requires SR owner
///                     2) vault.setEcosystem() with new SR address -- requires vault owner/timelock
///                     3) Re-register all strategies: strategyRouter.registerStrategy(...)
///                     4) strategyRouter.transferOwnership(timelock)
contract DeployStrategyRouter is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;

    function run() external returns (StrategyRouter router) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployStrategyRouter is Arbitrum-only (chainId 42161)"
        );

        uint256 deployerPk   = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer     = vm.addr(deployerPk);
        address coreVault    = vm.envAddress("CORE_VAULT_ADDRESS");
        address globalConfig = vm.envAddress("GLOBAL_CONFIG_ADDRESS");

        require(coreVault != address(0),    "CORE_VAULT_ADDRESS required");
        require(globalConfig != address(0), "GLOBAL_CONFIG_ADDRESS required");

        console.log("================================================================");
        console.log("   DEPLOY STRATEGY ROUTER (standalone)");
        console.log("================================================================");
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
