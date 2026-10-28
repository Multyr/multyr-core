// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;
import {Vm} from "forge-std/Vm.sol";

/// @notice Off-chain deployment preflight; never linked into production contracts.
library ReleaseGuard {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    function check() internal {
        // Local unit tests do not broadcast to public chains.
        if (block.chainid == 31337) return;
        string[] memory args = new string[](3);
        args[0] = "python3";
        args[1] = "script/release/release.py";
        args[2] = "attest";
        require(keccak256(vm.ffi(args)) == keccak256(hex"01"), "release attestation failed");
    }
}
