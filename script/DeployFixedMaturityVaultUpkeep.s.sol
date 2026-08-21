// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { FixedMaturityVaultUpkeep } from "@multyr-core/automation/FixedMaturityVaultUpkeep.sol";
import { ChainConfig } from "./config/ChainConfig.sol";

/// @title DeployFixedMaturityVaultUpkeep -- FM FixedMaturityVaultUpkeep standalone deploy
/// @notice Deploys a FixedMaturityVaultUpkeep keeper for an existing FM CoreVault.
///         Run after DeployFixedMaturityVault or DeployFixedMaturityVaultIntegrated.
///         The upkeep handles the full FM lifecycle automatically (start/fail-after-deadline,
///         activate, matured, recall, settle, close) via Chainlink Automation.
/// @dev Stateless: takes vault address + configuration params only.
///      Does not require any special permissions to deploy -- Chainlink registers as forwarder.
/// @custom:chain-id Arbitrum One (42161), Base (8453), Ethereum Mainnet (1) -- see script/config/ChainConfig.sol
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, FM_VAULT_ADDRESS,
///                  FM_UPKEEP_STRICT_MODE (opt, default true)
/// @custom:post-deploy 1) Register on Chainlink Automation
///                     2) No additional vault grants needed -- upkeep reads public FM state
contract DeployFixedMaturityVaultUpkeep is Script {

    function run() external returns (FixedMaturityVaultUpkeep fmUpkeep) {
        ChainConfig.Config memory chain = ChainConfig.current();

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);

        address fmVault       = vm.envAddress("FM_VAULT_ADDRESS");
        bool    strictMode    = vm.envOr("FM_UPKEEP_STRICT_MODE",         true);

        require(fmVault != address(0), "FM_VAULT_ADDRESS required");

        console.log("================================================================");
        console.log("   DEPLOY FIXED MATURITY VAULT UPKEEP");
        console.log("================================================================");
        console.log("Chain:         ", chain.chainName);
        console.log("Deployer:      ", deployer);
        console.log("FM Vault:      ", fmVault);
        console.log("Strict Mode:   ", strictMode);
        console.log("================================================================");

        vm.startBroadcast(deployerPk);

        fmUpkeep = new FixedMaturityVaultUpkeep(fmVault, strictMode);

        vm.stopBroadcast();

        console.log("");
        console.log("FixedMaturityVaultUpkeep deployed:", address(fmUpkeep));
        console.log("");
        console.log("NEXT STEPS:");
        console.log("  1. Register on Chainlink Automation");
        console.log("     -> no additional vault grants needed");
        console.log("  2. Upkeep handles lifecycle automatically:");
        console.log("     Funding -> (deadline) -> Active/Failed -> Matured -> Recall -> Settle -> Close");
    }
}
