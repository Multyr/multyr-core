// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { AaveV3WarmAdapter_USDC } from "@multyr-core/adapters/warm/AaveV3WarmAdapter_USDC.sol";
import { MorphoVaultWarmAdapter_USDC } from "@multyr-core/adapters/warm/MorphoBlueWarmAdapter_USDC.sol";
import { BufferManager } from "@multyr-core/core/modules/BufferManager.sol";

/// @title DeployWarmAdapters -- Aave + Morpho warm adapters standalone deploy (Phase 4)
/// @notice Deploys AaveV3WarmAdapter_USDC and MorphoVaultWarmAdapter_USDC for an existing BufferManager.
///         Run after DeployCoreSystem when warm adapters were not included (DEPLOY_WARM_ADAPTERS=false).
///         After deploy, register adapters in BufferManager and approve in vault.
/// @dev Both adapters are stateless (controller + vault addresses only).
///      Requires BufferManager owner to call addWarmAdapter + vault to call approveWarmAdapters after deploy.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, CORE_VAULT_ADDRESS, BUFFER_MANAGER_ADDRESS,
///                  MORPHO_VAULT (opt, default MORPHO_GAUNTLET_CORE),
///                  MORPHO_SLIPPAGE_BPS (opt, default 5), DEPLOY_AAVE (opt, default true),
///                  DEPLOY_MORPHO (opt, default true)
/// @custom:post-deploy 1) bufferManager.addWarmAdapter(aaveAdapter) -- requires BM owner
///                     2) bufferManager.addWarmAdapter(morphoAdapter) -- requires BM owner
///                     3) vault.approveWarmAdapters([aaveAdapter, morphoAdapter]) -- requires vault owner
contract DeployWarmAdapters is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;

    // Canonical Arbitrum addresses
    address constant MORPHO_GAUNTLET_CORE = 0x7e97fa6893871A2751B5fE961978DCCb2c201E65;

    struct WarmAdaptersResult {
        AaveV3WarmAdapter_USDC aaveAdapter;
        MorphoVaultWarmAdapter_USDC morphoAdapter;
    }

    function run() external returns (WarmAdaptersResult memory result) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployWarmAdapters is Arbitrum-only (chainId 42161)"
        );

        uint256 deployerPk   = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer     = vm.addr(deployerPk);
        address coreVault    = vm.envAddress("CORE_VAULT_ADDRESS");
        address bufferManager = vm.envAddress("BUFFER_MANAGER_ADDRESS");
        address morphoVault  = vm.envOr("MORPHO_VAULT", MORPHO_GAUNTLET_CORE);
        uint256 morphoSlippage = vm.envOr("MORPHO_SLIPPAGE_BPS", uint256(5));
        bool deployAave      = vm.envOr("DEPLOY_AAVE",  true);
        bool deployMorpho    = vm.envOr("DEPLOY_MORPHO", true);

        require(coreVault != address(0),     "CORE_VAULT_ADDRESS required");
        require(bufferManager != address(0), "BUFFER_MANAGER_ADDRESS required");

        console.log("================================================================");
        console.log("   DEPLOY WARM ADAPTERS (Aave + Morpho)");
        console.log("================================================================");
        console.log("Deployer:     ", deployer);
        console.log("CoreVault:    ", coreVault);
        console.log("BufferManager:", bufferManager);
        console.log("MorphoVault:  ", morphoVault);
        console.log("Deploy Aave:  ", deployAave);
        console.log("Deploy Morpho:", deployMorpho);
        console.log("================================================================");

        vm.startBroadcast(deployerPk);

        if (deployAave) {
            result.aaveAdapter = new AaveV3WarmAdapter_USDC(
                bufferManager,
                coreVault,
                address(0), // use default AAVE_POOL from constructor
                address(0)  // use default AAVE_DATA_PROVIDER from constructor
            );
            console.log("[1] AaveV3WarmAdapter_USDC:", address(result.aaveAdapter));
        }

        if (deployMorpho) {
            result.morphoAdapter = new MorphoVaultWarmAdapter_USDC(
                bufferManager,
                coreVault,
                morphoVault,
                uint16(morphoSlippage)
            );
            console.log("[2] MorphoVaultWarmAdapter_USDC:", address(result.morphoAdapter));
        }

        vm.stopBroadcast();

        console.log("");
        console.log("NEXT STEPS (requires BufferManager owner + vault owner):");
        if (deployAave) {
            console.log("  bufferManager.addWarmAdapter(", address(result.aaveAdapter), ")");
        }
        if (deployMorpho) {
            console.log("  bufferManager.addWarmAdapter(", address(result.morphoAdapter), ")");
        }
        if (deployAave && deployMorpho) {
            console.log("  vault.approveWarmAdapters([aaveAdapter, morphoAdapter])");
        }
        console.log("================================================================");
    }
}
