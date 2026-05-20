// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { FixedMaturityVaultUpkeep } from "@multyr-core/automation/FixedMaturityVaultUpkeep.sol";

/// @title DeployFixedMaturityVaultUpkeep -- FM FixedMaturityVaultUpkeep standalone deploy
/// @notice Deploys a FixedMaturityVaultUpkeep keeper for an existing FM CoreVault.
///         Run after DeployFixedMaturityVault or DeployFixedMaturityVaultIntegrated.
///         The upkeep handles the full FM lifecycle automatically (start/fail-after-deadline,
///         activate, matured, recall, settle, close) via Chainlink Automation.
/// @dev Stateless: takes vault address + configuration params only.
///      Does not require any special permissions to deploy -- Chainlink registers as forwarder.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, FM_VAULT_ADDRESS,
///                  FM_MAX_SETTLE_CLAIMS (opt, default 15), FM_UPKEEP_STRICT_MODE (opt, default true)
/// @custom:post-deploy 1) Register on Chainlink Automation
///                     2) No additional vault grants needed -- upkeep reads public FM state
contract DeployFixedMaturityVaultUpkeep is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;

    function run() external returns (FixedMaturityVaultUpkeep fmUpkeep) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployFixedMaturityVaultUpkeep is Arbitrum-only (chainId 42161)"
        );

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);

        address fmVault       = vm.envAddress("FM_VAULT_ADDRESS");
        uint32  maxClaims     = uint32(vm.envOr("FM_MAX_SETTLE_CLAIMS",   uint256(15)));
        bool    strictMode    = vm.envOr("FM_UPKEEP_STRICT_MODE",         true);

        require(fmVault != address(0), "FM_VAULT_ADDRESS required");

        console.log("================================================================");
        console.log("   DEPLOY FIXED MATURITY VAULT UPKEEP");
        console.log("================================================================");
        console.log("Deployer:      ", deployer);
        console.log("FM Vault:      ", fmVault);
        console.log("Max Claims:    ", maxClaims);
        console.log("Strict Mode:   ", strictMode);
        console.log("================================================================");

        vm.startBroadcast(deployerPk);

        fmUpkeep = new FixedMaturityVaultUpkeep(fmVault, maxClaims, strictMode);

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
