// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Script} from "forge-std/Script.sol";
import {CoreVault} from "../src/core/CoreVault.sol";
import {BufferManager} from "../src/core/modules/BufferManager.sol";
import {StrategyRouter} from "../src/core/modules/StrategyRouter.sol";
import {StrategyHealthRegistry} from "../src/core/modules/StrategyHealthRegistry.sol";
import {PriceOracleMiddleware} from "../src/core/modules/PriceOracleMiddleware.sol";
import {FeeCollector} from "../src/core/modules/FeeCollector.sol";
import {GlobalConfig} from "../src/core/config/GlobalConfig.sol";
import {VaultFactory} from "../src/factory/VaultFactory.sol";
import {RecoveryGate} from "../src/governance/RecoveryGate.sol";
import {VaultUpkeep} from "../src/automation/VaultUpkeep.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Finish the initial strategy registration, then transfer setup authority.
/// The Governor Safe must subsequently accept the four pending transfers.
contract CompleteCoreHandover is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(key);
        address governor = vm.envAddress("GOVERNOR_ADDRESS");
        require(governor != deployer && governor.code.length > 0, "independent governor contract required");
        CoreVault vault = CoreVault(payable(vm.envAddress("VAULT_ADDRESS")));
        StrategyRouter router = StrategyRouter(vm.envAddress("STRATEGY_ROUTER_ADDRESS"));
        BufferManager buffer = BufferManager(vm.envAddress("BUFFER_MANAGER_ADDRESS"));
        address strategy = vm.envAddress("STRATEGY_ADDRESS");
        require(vault.owner() == deployer && router.owner() == deployer, "setup authority mismatch");
        require(vault.guardian() == vm.envAddress("GUARDIAN_ADDRESS"), "guardian mismatch");
        require(vault.vetoer() == vm.envAddress("VETOER_ADDRESS"), "vetoer mismatch");
        require(IAccessControl(strategy).hasRole(bytes32(0), governor), "strategy handover incomplete");
        require(!IAccessControl(strategy).hasRole(bytes32(0), deployer), "deployer retains strategy admin");
        FeeCollector collector = FeeCollector(vm.envAddress("FEE_COLLECTOR_ADDRESS"));
        VaultFactory factory = VaultFactory(vm.envAddress("VAULT_FACTORY_ADDRESS"));
        RecoveryGate gate = RecoveryGate(vm.envAddress("RECOVERY_GATE_ADDRESS"));
        require(gate.securityApprover() == vm.envAddress("SECURITY_APPROVER_ADDRESS"), "approver mismatch");
        vm.startBroadcast(key);
        if (!router.strategyAllowlist(strategy)) router.executeStrategyAllowlist(strategy);
        if (!router.isStrategyEnabled(strategy)) router.register(strategy, 100, 10000);
        router.setMaxStrategyBps(strategy, 10000);
        router.setLossCapPerStrategy(strategy, 50);
        // Keep the deployed keeper's 600-second NAV freshness configuration.
        buffer.setRebalanceParams(600, 1_000_000, 600);
        buffer.refreshWarmNav();
        // Testing activation is explicit and occurs before relinquishing setup ownership.
        if (vm.envOr("ACTIVATE_FOR_TESTING", false)) {
            buffer.setPaused(false);
            vault.unpauseAll();
        }
        GlobalConfig(vm.envAddress("GLOBAL_CONFIG_ADDRESS")).setGovernor(governor);
        buffer.transferOwnership(governor);
        router.transferOwnership(governor);
        StrategyHealthRegistry(vm.envAddress("HEALTH_REGISTRY_ADDRESS")).transferOwnership(governor);
        PriceOracleMiddleware(vm.envAddress("PRICE_ORACLE_ADDRESS")).transferOwnership(governor);
        VaultUpkeep(vm.envAddress("VAULT_UPKEEP_ADDRESS")).transferOwnership(governor);
        collector.beginGovernorTransfer(governor);
        factory.transferOwnership(governor);
        gate.beginRootTimelockTransfer(governor);
        vault.beginOwnerTransfer(governor);
        vm.stopBroadcast();
        require(router.owner() == governor && buffer.owner() == governor, "component handover failed");
        require(vault.pendingOwner() == governor, "core nomination failed");
        require(collector.pendingGovernor() == governor, "collector nomination failed");
        require(factory.pendingOwner() == governor, "factory nomination failed");
        require(gate.pendingRootTimelock() == governor, "root nomination failed");
    }
}
