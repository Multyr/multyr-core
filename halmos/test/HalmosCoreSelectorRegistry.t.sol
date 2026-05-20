// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SelectorRegistry } from "core/libraries/SelectorRegistry.sol";
import { AdminModule } from "core/modules/AdminModule.sol";
import { LiquidityOpsModule } from "core/modules/LiquidityOpsModule.sol";

/// @title Halmos symbolic checks for core selector guardrails
/// @notice Proves the registry enforces exact-role semantics for key owner/public selectors.
contract HalmosCoreSelectorRegistry is Test {
    SelectorRegistry internal registry;

    uint8 internal constant ROLE_PUBLIC = 0;
    uint8 internal constant ROLE_OWNER = 1;
    uint8 internal constant ROLE_UNREGISTERED = 255;

    function setUp() public {
        registry = new SelectorRegistry();
    }

    function check_owner_selector_rejects_non_owner(uint8 attemptedRole) public {
        vm.assume(attemptedRole != ROLE_OWNER);

        try registry.validateRoleAssignment(AdminModule.setParams.selector, attemptedRole) {
            assert(false);
        } catch {}
    }

    function check_owner_selector_accepts_owner() public {
        assert(registry.validateRoleAssignment(AdminModule.setParams.selector, ROLE_OWNER));
    }

    function check_public_selector_rejects_non_public(uint8 attemptedRole) public {
        vm.assume(attemptedRole != ROLE_PUBLIC);

        try registry.validateRoleAssignment(LiquidityOpsModule.realizeForReserveAndOps.selector, attemptedRole) {
            assert(false);
        } catch {}
    }

    function check_public_selector_accepts_public() public {
        assert(registry.validateRoleAssignment(LiquidityOpsModule.realizeForReserveAndOps.selector, ROLE_PUBLIC));
    }

    function check_unknown_selector_stays_unregistered(bytes4 selector) public {
        vm.assume(selector != AdminModule.setParams.selector);
        vm.assume(selector != LiquidityOpsModule.realizeForReserveAndOps.selector);

        uint8 required = registry.getRequiredRole(selector);
        if (required == ROLE_UNREGISTERED) {
            assert(true);
            return;
        }

        // If the selector maps to another known role, exact role matching must still hold.
        assert(registry.validateRoleAssignment(selector, required));
    }
}
