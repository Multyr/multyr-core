// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ClaimSettlementUpkeep} from "../src/automation/ClaimSettlementUpkeep.sol";
import {CoreVault} from "../src/core/CoreVault.sol";

/// @notice Deploy claim settlement automation for an existing current-generation vault.
/// Ownership transfers to GOVERNOR_ADDRESS once the upkeep has been configured.
contract DeployClaimSettlementUpkeep is Script {
    function run() external returns (ClaimSettlementUpkeep upkeep) {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address vault = vm.envAddress("VAULT_ADDRESS");
        require(vault.code.length > 0, "vault has no code");
        require(CoreVault(payable(vault)).owner() == vm.addr(key), "deployer must own vault");
        (bool ok, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("fundedOutstandingClaimCount()")
        );
        require(ok && data.length == 32, "missing funded claim counter");
        vm.startBroadcast(key);
        upkeep = new ClaimSettlementUpkeep(vault);
        address governor = vm.envAddress("GOVERNOR_ADDRESS");
        require(governor != vm.addr(key) && governor.code.length > 0, "governor must be an independent contract");
        upkeep.transferOwnership(governor);
        vm.stopBroadcast();
        require(upkeep.owner() == governor, "wrong owner");
        console2.log("ClaimSettlementUpkeep", address(upkeep));
        string memory json = "claimSettlement";
        vm.serializeAddress(json, "vault", vault);
        vm.serializeAddress(json, "owner", governor);
        string memory result = vm.serializeAddress(json, "claimSettlementUpkeep", address(upkeep));
        vm.writeJson(result, vm.envOr("CLAIM_OUTPUT_JSON", string("broadcast/claim-settlement-addresses.json")));
    }
}
