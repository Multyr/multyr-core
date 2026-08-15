// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { EpochedQueueModule } from "@multyr-core/core/modules/EpochedQueueModule.sol";
import { SelectorLib } from "@multyr-core/core/libraries/SelectorLib.sol";
import { CoreVault } from "@multyr-core/core/CoreVault.sol";

/// @title DeployQueueModule -- EpochedQueueModule standalone redeploy (incident response)
/// @notice Deploys a new EpochedQueueModule delegatecall target and re-wires it to an
///         existing CoreVault. Idempotent: safe to redeploy and re-wire.
///         Designed for incident response when the queue module must be upgraded
///         without a full redeploy.
/// @dev EpochedQueueModule is stateless -- no constructor arguments, no own storage
///      (EIP-7201 namespaced storage lives at a fixed slot, independent of which
///      module instance is wired to it).
///      Re-wiring requires vault owner (pre-seal) or timelock (post-seal routing freeze lifted).
///      CRITICAL: Do NOT re-wire after routing is frozen unless a timelock tx is submitted first.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, CORE_VAULT_ADDRESS, REWIRE (opt, default false)
///                  REWIRE=true -- also calls setModulesBatch to update selector routing on vault
///                  REWIRE=false (default) -- deploys only, caller wires manually
/// @custom:post-deploy If REWIRE=false:
///                     1) Check isRoutingFrozen() on vault before proceeding
///                     2) vault.setModulesBatch(queueModuleSelectors, newQueueModule, ROLE_PUBLIC)
///                     3) Verify routing: vault.moduleOf(requestEpochWithdrawal.selector) == newModule
contract DeployQueueModule is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;

    function run() external returns (EpochedQueueModule queueModule) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployQueueModule is Arbitrum-only (chainId 42161)"
        );

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);
        bool    rewire     = vm.envOr("REWIRE", false);

        address payable coreVault;
        if (rewire) {
            coreVault = payable(vm.envAddress("CORE_VAULT_ADDRESS"));
            require(coreVault != address(0), "CORE_VAULT_ADDRESS required when REWIRE=true");
        }

        console.log("================================================================");
        console.log("   DEPLOY QUEUE MODULE (standalone -- incident response)");
        console.log("================================================================");
        console.log("Deployer:  ", deployer);
        console.log("Rewire:    ", rewire);
        if (rewire) { console.log("CoreVault: ", coreVault); }
        console.log("================================================================");

        vm.startBroadcast(deployerPk);

        // EpochedQueueModule has no constructor -- purely stateless delegatecall target
        queueModule = new EpochedQueueModule();
        console.log("EpochedQueueModule deployed:", address(queueModule));

        if (rewire) {
            CoreVault vault = CoreVault(coreVault);
            require(!vault.isRoutingFrozen(), "GATE: routing is frozen -- cannot rewire without timelock");

            bytes4[] memory writeSels = SelectorLib.getQueueModuleSelectors();
            bytes4[] memory viewSels  = SelectorLib.getQueueModuleViewSelectors();

            uint256 writeLen = writeSels.length;
            address[] memory writeModules = new address[](writeLen);
            uint8[]   memory writeRoles   = new uint8[](writeLen);
            for (uint256 i; i < writeLen; i++) {
                writeModules[i] = address(queueModule);
                writeRoles[i]   = SelectorLib.ROLE_PUBLIC;
            }
            vault.setModulesBatch(writeSels, writeModules, writeRoles);

            uint256 viewLen = viewSels.length;
            address[] memory viewModules = new address[](viewLen);
            uint8[]   memory viewRoles   = new uint8[](viewLen);
            for (uint256 i; i < viewLen; i++) {
                viewModules[i] = address(queueModule);
                viewRoles[i]   = SelectorLib.ROLE_PUBLIC;
            }
            vault.setModulesBatch(viewSels, viewModules, viewRoles);

            console.log("  [OK] Selector routing updated for", writeSels.length + viewSels.length, "selectors");
        }

        vm.stopBroadcast();

        console.log("");
        if (!rewire) {
            console.log("NEXT STEPS (rewire manually):");
            console.log("  1. Check vault.isRoutingFrozen() -- must be false");
            console.log("  2. vault.setModulesBatch(queueWriteSelectors,", address(queueModule), ", ROLE_PUBLIC)");
            console.log("  3. vault.setModulesBatch(queueViewSelectors,",  address(queueModule), ", ROLE_PUBLIC)");
        } else {
            console.log("Rewire complete. Verify:");
            console.log("  vault.moduleOf(requestEpochWithdrawal.selector) ==", address(queueModule));
        }
    }
}
