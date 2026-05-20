// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { BufferManager } from "@multyr-core/core/modules/BufferManager.sol";
import { IBufferManager } from "@multyr-core/interfaces/IBufferManager.sol";

/// @title DeployBufferManager -- standalone BufferManager redeploy
/// @notice Deploys a new BufferManager for an existing CoreVault.
///         Use for incident response or initial standalone deploy.
///         After deploy, caller must call vault.setEcosystem() to wire the new BM.
/// @dev Idempotent: safe to deploy multiple times; only the one set in ecosystem is active.
///      Fails fast if vault is address(0) -- never deploy against zero vault.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, CORE_VAULT_ADDRESS,
///                  TARGET_HOT_BPS (opt, default 400), MIN_HOT_BPS (opt, default 200),
///                  TARGET_WARM_BPS (opt, default 600), MAX_WARM_BPS (opt, default 800),
///                  OPS_RESERVE_BPS (opt, default 400), MAX_WARM_SLIPPAGE_BPS (opt, default 50)
/// @custom:post-deploy 1) vault.setEcosystem() with new BM address -- requires vault owner/timelock
///                     2) bufferManager.transferOwnership(timelock)
///                     3) If warm adapters: bufferManager.addWarmAdapter(...) + vault.approveWarmAdapters(...)
contract DeployBufferManager is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function run() external returns (BufferManager bm) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployBufferManager is Arbitrum-only (chainId 42161)"
        );

        uint256 deployerPk  = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerPk);
        address coreVault   = vm.envAddress("CORE_VAULT_ADDRESS");

        uint256 targetHotBps       = vm.envOr("TARGET_HOT_BPS",          uint256(400));
        uint256 minHotBps          = vm.envOr("MIN_HOT_BPS",             uint256(200));
        uint256 targetWarmBps      = vm.envOr("TARGET_WARM_BPS",         uint256(600));
        uint256 maxWarmBps         = vm.envOr("MAX_WARM_BPS",            uint256(800));
        uint256 opsReserveBps      = vm.envOr("OPS_RESERVE_BPS",         uint256(400));
        uint256 maxWarmSlippageBps = vm.envOr("MAX_WARM_SLIPPAGE_BPS",   uint256(50));

        require(coreVault != address(0), "CORE_VAULT_ADDRESS required");
        require(targetHotBps + targetWarmBps == 1000, "targetHotBps + targetWarmBps must equal 1000");
        require(maxWarmBps == 1000 - minHotBps, "maxWarmBps must equal 1000 - minHotBps");
        require(opsReserveBps == targetHotBps, "opsReserveBps must equal targetHotBps");

        console.log("================================================================");
        console.log("   DEPLOY BUFFER MANAGER (standalone)");
        console.log("================================================================");
        console.log("Deployer:          ", deployer);
        console.log("CoreVault:         ", coreVault);
        console.log("targetHotBps:      ", targetHotBps);
        console.log("minHotBps:         ", minHotBps);
        console.log("targetWarmBps:     ", targetWarmBps);
        console.log("maxWarmBps:        ", maxWarmBps);
        console.log("opsReserveBps:     ", opsReserveBps);
        console.log("================================================================");

        IBufferManager.BufferConfig memory cfg = IBufferManager.BufferConfig({
            targetHotBps:        uint16(targetHotBps),
            minHotBps:           uint16(minHotBps),
            targetWarmBps:       uint16(targetWarmBps),
            maxWarmBps:          uint16(maxWarmBps),
            opsReserveTargetBps: uint16(opsReserveBps),
            maxWarmSlippageBps:  uint16(maxWarmSlippageBps),
            asset:               USDC,
            warmAdapter:         address(0), // deprecated field
            twapWindowSec:       0,
            paused:              false
        });

        vm.startBroadcast(deployerPk);

        bm = new BufferManager(deployer, coreVault, cfg);

        // Verify invariants (audit-grade)
        IBufferManager.BufferConfig memory v = bm.getConfig();
        require(v.targetHotBps + v.targetWarmBps == 1000, "DEPLOY_BUG: hot+warm != 1000");
        require(v.maxWarmBps == 1000 - v.minHotBps, "DEPLOY_BUG: maxWarm != 1000-minHot");
        require(v.opsReserveTargetBps == v.targetHotBps, "DEPLOY_BUG: opsReserve != targetHot");

        vm.stopBroadcast();

        console.log("BufferManager deployed:", address(bm));
        console.log("");
        console.log("NEXT STEPS (requires vault owner/timelock):");
        console.log("  vault.setEcosystem() -- update bufferManager to", address(bm));
        console.log("  bufferManager.transferOwnership(<timelock>)");
    }
}
