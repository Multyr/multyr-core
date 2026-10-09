// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {CoreVault} from "../src/core/CoreVault.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Retain deployer ownership and manual keeper access without sealing the system.
contract FinishDeployerConfiguration is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(key);
        CoreVault vault = CoreVault(payable(vm.envAddress("VAULT_ADDRESS")));
        IAccessControl strategy = IAccessControl(vm.envAddress("STRATEGY_ADDRESS"));
        require(vault.owner() == deployer, "unexpected vault owner");
        require(strategy.hasRole(bytes32(0), deployer), "missing strategy admin");
        bytes32 keeper = keccak256("KEEPER_ROLE");
        vm.startBroadcast(key);
        if (vault.pendingOwner() == deployer) vault.acceptOwnerTransfer();
        if (!strategy.hasRole(keeper, deployer)) strategy.grantRole(keeper, deployer);
        vm.stopBroadcast();
        require(vault.owner() == deployer && vault.pendingOwner() == address(0), "ownership mismatch");
        require(strategy.hasRole(keeper, deployer), "missing keeper role");
        require(!vault.isSystemSealed() && !vault.isRoutingFrozen(), "unexpected seal");
        require(vault.paused(), "vault unexpectedly active");
    }
}
