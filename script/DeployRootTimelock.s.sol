// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IncentivesTimelock} from "@multyr-core/governance/IncentivesTimelock.sol";

/// @notice Deploys the root TimelockController with one EOA as the temporary
///         proposer, executor, and setup admin. Those roles can later be moved
///         to Safes without changing immutable protocol governance references.
contract DeployRootTimelock is Script {
    function run() external returns (IncentivesTimelock rootTimelock) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address controller = vm.envOr("ROOT_CONTROLLER_ADDRESS", deployer);
        uint256 minDelay = vm.envOr("ROOT_TIMELOCK_MIN_DELAY", uint256(0));

        require(controller != address(0), "ROOT_CONTROLLER_ADDRESS is zero");

        address[] memory proposers = new address[](1);
        proposers[0] = controller;
        address[] memory executors = new address[](1);
        executors[0] = controller;

        vm.startBroadcast(deployerPk);
        rootTimelock = new IncentivesTimelock(minDelay, proposers, executors, controller);
        vm.stopBroadcast();

        require(rootTimelock.getMinDelay() == minDelay, "timelock delay mismatch");
        console.log("ROOT_TIMELOCK_ADDRESS=", address(rootTimelock));
        console.log("ROOT_TIMELOCK_MIN_DELAY=", minDelay);
        console.log("ROOT_CONTROLLER_ADDRESS=", controller);
    }
}
