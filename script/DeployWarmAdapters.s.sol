// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { AaveV3WarmAdapter_USDC } from "@multyr-core/adapters/warm/AaveV3WarmAdapter_USDC.sol";
import { MorphoVaultWarmAdapter_USDC } from "@multyr-core/adapters/warm/MorphoBlueWarmAdapter_USDC.sol";
import { BufferManager } from "@multyr-core/core/modules/BufferManager.sol";
import { ChainConfig } from "./config/ChainConfig.sol";

/// @title DeployWarmAdapters -- Aave + Morpho warm adapters standalone deploy (Phase 4)
/// @notice Deploys AaveV3WarmAdapter_USDC and MorphoVaultWarmAdapter_USDC for an existing BufferManager.
///         Run after DeployCoreSystem when warm adapters were not included (DEPLOY_WARM_ADAPTERS=false).
///         After deploy, register adapters in BufferManager and approve in vault.
/// @dev Both adapters are stateless (controller + vault addresses only).
///      Requires BufferManager owner to call addWarmAdapter + vault to call approveWarmAdapters after deploy.
/// @custom:chain-id Arbitrum One (42161), Base (8453), Ethereum Mainnet (1) -- see script/config/ChainConfig.sol
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, CORE_VAULT_ADDRESS, BUFFER_MANAGER_ADDRESS,
///                  MORPHO_VAULT (required on chains with no vetted default -- see ChainConfig),
///                  MORPHO_SLIPPAGE_BPS (opt, default from ChainConfig), DEPLOY_AAVE (opt, default true),
///                  DEPLOY_MORPHO (opt, default true)
/// @custom:post-deploy 1) bufferManager.addWarmAdapter(aaveAdapter) -- requires BM owner
///                     2) bufferManager.addWarmAdapter(morphoAdapter) -- requires BM owner
///                     3) vault.approveWarmAdapters([aaveAdapter, morphoAdapter]) -- requires vault owner
contract DeployWarmAdapters is Script {

    struct WarmAdaptersResult {
        AaveV3WarmAdapter_USDC aaveAdapter;
        MorphoVaultWarmAdapter_USDC morphoAdapter;
    }

    function run() external returns (WarmAdaptersResult memory result) {
        ChainConfig.Config memory chain = ChainConfig.current();

        uint256 deployerPk   = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer     = vm.addr(deployerPk);
        address coreVault    = vm.envAddress("CORE_VAULT_ADDRESS");
        address bufferManager = vm.envAddress("BUFFER_MANAGER_ADDRESS");
        address morphoVault  = vm.envOr("MORPHO_VAULT", chain.morphoVaultDefault);
        uint256 morphoSlippage = vm.envOr("MORPHO_SLIPPAGE_BPS", uint256(chain.morphoSlippageBps));
        bool deployAave      = vm.envOr("DEPLOY_AAVE",  true);
        bool deployMorpho    = vm.envOr("DEPLOY_MORPHO", true);

        require(coreVault != address(0),     "CORE_VAULT_ADDRESS required");
        require(bufferManager != address(0), "BUFFER_MANAGER_ADDRESS required");
        require(
            !deployMorpho || morphoVault != address(0),
            "MORPHO_VAULT required: no vetted default vault for this chain"
        );

        console.log("================================================================");
        console.log("   DEPLOY WARM ADAPTERS (Aave + Morpho)");
        console.log("================================================================");
        console.log("Chain:        ", chain.chainName);
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
                chain.usdc,
                chain.aavePool,
                chain.aaveDataProvider
            );
            console.log("[1] AaveV3WarmAdapter_USDC:", address(result.aaveAdapter));
        }

        if (deployMorpho) {
            result.morphoAdapter = new MorphoVaultWarmAdapter_USDC(
                bufferManager,
                coreVault,
                chain.usdc,
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
