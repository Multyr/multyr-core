// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {CoreVault} from "@multyr-core/core/CoreVault.sol";
import {StrategyRouter} from "@multyr-core/core/modules/StrategyRouter.sol";
import {GlobalConfig} from "@multyr-core/core/config/GlobalConfig.sol";

/// @notice Zero-delay test-governance batches. The StrategyRouter's independent
///         two-day allowlist delay remains intact.
contract ConfigureTestDeployment is Script {
    function runReduceStrategyDelay() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        TimelockController timelock =
            TimelockController(payable(vm.envAddress("TIMELOCK_ADDRESS")));
        address router = vm.envAddress("STRATEGY_ROUTER_ADDRESS");
        address strategy = vm.envAddress("STRATEGY_ADDRESS");

        StrategyRouter strategyRouter = StrategyRouter(router);
        uint256 previousEta = strategyRouter.strategyAllowlistEta(strategy);
        require(previousEta != 0, "strategy proposal missing");

        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);
        for (uint256 i; i < targets.length; ++i) targets[i] = router;
        payloads[0] = abi.encodeCall(StrategyRouter.setStrategyAllowlistDelay, (1 days));
        payloads[1] =
            abi.encodeCall(StrategyRouter.cancelStrategyAllowlistProposal, (strategy));
        payloads[2] = abi.encodeCall(StrategyRouter.proposeStrategyAllowlist, (strategy));
        bytes32 salt = keccak256(
            abi.encode("MULTYR_TEST_REDUCE_STRATEGY_DELAY", router, strategy, previousEta)
        );

        vm.startBroadcast(deployerPk);
        timelock.scheduleBatch(
            targets, values, payloads, bytes32(0), salt, timelock.getMinDelay()
        );
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        vm.stopBroadcast();

        require(strategyRouter.strategyAllowlistDelay() == 1 days, "delay mismatch");
        require(
            strategyRouter.strategyAllowlistEta(strategy) > block.timestamp,
            "new proposal missing"
        );
    }

    function runInitial() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        TimelockController timelock =
            TimelockController(payable(vm.envAddress("TIMELOCK_ADDRESS")));
        address vault = vm.envAddress("VAULT_ADDRESS");
        address router = vm.envAddress("STRATEGY_ROUTER_ADDRESS");
        address strategy = vm.envAddress("STRATEGY_ADDRESS");

        address[] memory targets = new address[](3);
        targets[0] = vault;
        targets[1] = router;
        targets[2] = vault;
        uint256[] memory values = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);
        payloads[0] = abi.encodeCall(CoreVault.acceptOwnerTransfer, ());
        payloads[1] = abi.encodeCall(StrategyRouter.proposeStrategyAllowlist, (strategy));
        payloads[2] = abi.encodeCall(CoreVault.unpauseAll, ());
        bytes32 salt = keccak256(abi.encode("MULTYR_TEST_INITIAL", vault, strategy));

        vm.startBroadcast(deployerPk);
        timelock.scheduleBatch(
            targets, values, payloads, bytes32(0), salt, timelock.getMinDelay()
        );
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        vm.stopBroadcast();

        require(CoreVault(payable(vault)).owner() == address(timelock), "vault owner mismatch");
        require(!CoreVault(payable(vault)).paused(), "vault still paused");
        require(
            StrategyRouter(router).strategyAllowlistEta(strategy) != 0,
            "strategy proposal missing"
        );
    }

    function runActivateStrategy() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        TimelockController timelock =
            TimelockController(payable(vm.envAddress("TIMELOCK_ADDRESS")));
        address router = vm.envAddress("STRATEGY_ROUTER_ADDRESS");
        address strategy = vm.envAddress("STRATEGY_ADDRESS");

        address[] memory targets = new address[](4);
        uint256[] memory values = new uint256[](4);
        bytes[] memory payloads = new bytes[](4);
        for (uint256 i; i < targets.length; ++i) targets[i] = router;
        payloads[0] = abi.encodeCall(StrategyRouter.executeStrategyAllowlist, (strategy));
        payloads[1] = abi.encodeCall(StrategyRouter.register, (strategy, 100, 10000));
        payloads[2] = abi.encodeCall(StrategyRouter.setMaxStrategyBps, (strategy, 10000));
        payloads[3] = abi.encodeCall(StrategyRouter.setLossCapPerStrategy, (strategy, 50));
        bytes32 salt = keccak256(abi.encode("MULTYR_TEST_ACTIVATE", router, strategy));

        vm.startBroadcast(deployerPk);
        timelock.scheduleBatch(
            targets, values, payloads, bytes32(0), salt, timelock.getMinDelay()
        );
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        vm.stopBroadcast();

        require(StrategyRouter(router).isStrategyEnabled(strategy), "strategy not enabled");
    }

    function runRestoreWithdrawalPolicy() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        TimelockController timelock =
            TimelockController(payable(vm.envAddress("TIMELOCK_ADDRESS")));
        address globalConfig = vm.envAddress("GLOBAL_CONFIG_ADDRESS");
        address vault = vm.envAddress("VAULT_ADDRESS");
        bytes memory payload = abi.encodeCall(
            GlobalConfig.setVaultWithdrawalOverride,
            (
                vault,
                GlobalConfig.WithdrawalConfig({
                    capPerEpochBps: 1000,
                    maxWithdrawalPerBlock: 0,
                    maxWithdrawalPerTx: 0,
                    minClaimAmount: 0,
                    lockPeriod: 1 days
                })
            )
        );
        bytes32 salt = keccak256(abi.encode("MULTYR_TEST_RESTORE_WITHDRAWAL", vault));

        vm.startBroadcast(deployerPk);
        timelock.schedule(
            globalConfig, 0, payload, bytes32(0), salt, timelock.getMinDelay()
        );
        timelock.execute(globalConfig, 0, payload, bytes32(0), salt);
        vm.stopBroadcast();

        (uint16 capPerEpochBps,,, uint256 minClaimAmount, uint64 lockPeriod) =
            GlobalConfig(globalConfig).vaultWithdrawalOverrides(vault);
        require(capPerEpochBps == 1000, "withdraw cap mismatch");
        require(minClaimAmount == 0, "withdraw minimum mismatch");
        require(lockPeriod == 1 days, "withdraw lock mismatch");
    }
}
