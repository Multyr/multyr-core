// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ──────────────────────────────────────────────────────────────────────────────
// SPRINT SECURITY TEST -- depositFor unauthorized-payer fix (Option C)
//
// ORIGINAL BUG (now fixed):
// ─────────────────────────
// ERC4626Module.depositFor(assets, receiver, payer) accepted a caller-supplied
// payer address and passed it directly to safeTransferFrom(payer, vault, assets).
// Any EOA could call depositFor(amount, attacker, victim) to drain any address
// that had a standing vault approval -- no capital required, O(1) cost.
//
// FIX -- Option C (remove payer parameter):
// ─────────────────────────────────────────
// depositFor(uint256 assets, address receiver) now uses msg.sender as the payer.
// Routers (e.g. DepositRouter + Permit2) pull user tokens to themselves first,
// then call depositFor(amount, user) -- the router is both msg.sender and the
// token source. Any attacker calling depositFor is forced to use their OWN tokens.
// ──────────────────────────────────────────────────────────────────────────────

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness } from "../helpers/CoreHarness.sol";
import { MockUSDC } from "../helpers/MockUSDC.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";
import { ERC4626Module } from "../../src/core/modules/ERC4626Module.sol";

contract DepositFor_UnauthorizedPayer_POC is Test {
    address constant USDC_UNDERLYING = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 constant ONE_MILLION_USDC = 1_000_000e6;
    uint16  constant FORCE_PENALTY_BPS = 200;

    address internal victim;
    address internal attacker;

    CoreHarness        internal core;
    MockUSDC           internal mock;
    MockParamsProvider internal params;

    function setUp() public {
        victim   = makeAddr("victim");
        attacker = makeAddr("attacker");

        mock = new MockUSDC();
        vm.etch(USDC_UNDERLYING, address(mock).code);

        params = new MockParamsProvider();
        core   = new CoreHarness(
            IERC20Metadata(USDC_UNDERLYING),
            "USDC Agg",
            "agUSDC",
            address(this),
            address(this),
            address(params)
        );
    }

    function _victimApproves(uint256 amount) internal {
        MockUSDC(USDC_UNDERLYING).mint(victim, amount);
        vm.prank(victim);
        IERC20(USDC_UNDERLYING).approve(address(core), type(uint256).max);
    }

    // =========================================================================
    // TEST 1 -- FIX: attacker cannot drain victim with a standing approval
    //
    // Old attack: depositFor(amount, attacker, victim) -- victim pays, attacker
    // gets shares, exits and pockets victim's USDC.
    //
    // New 2-arg form: depositFor(amount, attacker) -- msg.sender = attacker is
    // the payer. Attacker has no USDC, call reverts immediately.
    // Victim's USDC is fully preserved.
    // =========================================================================
    function test_fix_full_theft_blocked_attacker_has_no_usdc() public {
        _victimApproves(ONE_MILLION_USDC);

        uint256 victimBefore   = IERC20(USDC_UNDERLYING).balanceOf(victim);
        uint256 attackerBefore = IERC20(USDC_UNDERLYING).balanceOf(attacker);

        // Attacker tries to deposit using victim's approval -- now reverts
        // because msg.sender (attacker) is the payer and has no USDC.
        vm.prank(attacker);
        vm.expectRevert(); // ERC20 transfer failure: attacker has no USDC
        ERC4626Module(address(core)).depositFor(ONE_MILLION_USDC, attacker);

        // Victim's USDC is untouched
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(victim),   victimBefore,   "FIX: victim USDC unchanged");
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(attacker), attackerBefore, "FIX: attacker received nothing");
        assertEq(core.balanceOf(attacker), 0, "FIX: attacker received no shares");
    }

    // =========================================================================
    // TEST 2 -- FIX: theft-with-penalty attack also blocked
    //
    // Even with a 2 % force-exit penalty the old attack was profitable (98 %
    // recovery on stolen funds). The fix prevents it entirely.
    // =========================================================================
    function test_fix_profitable_theft_with_penalty_blocked() public {
        core.setExitFeesUnsafe(0, 0, FORCE_PENALTY_BPS);
        _victimApproves(ONE_MILLION_USDC);

        uint256 victimBefore = IERC20(USDC_UNDERLYING).balanceOf(victim);

        vm.prank(attacker);
        vm.expectRevert();
        ERC4626Module(address(core)).depositFor(ONE_MILLION_USDC, attacker);

        assertEq(IERC20(USDC_UNDERLYING).balanceOf(victim), victimBefore, "FIX: victim USDC unchanged");
        assertEq(core.balanceOf(attacker), 0, "FIX: attacker received no shares");
    }

    // =========================================================================
    // TEST 3 -- FIX: griefing attack (forced lock) also blocked
    //
    // Old path: attacker deposited victim's USDC without consent, locking it
    // in the vault at an arbitrary time. Now the call reverts -- victim's USDC
    // stays in their wallet.
    // =========================================================================
    function test_fix_griefing_locked_funds_prevented() public {
        core.setExitFeesUnsafe(500, 0, 200);
        _victimApproves(ONE_MILLION_USDC);

        uint256 victimBefore = IERC20(USDC_UNDERLYING).balanceOf(victim);

        vm.prank(attacker);
        vm.expectRevert();
        ERC4626Module(address(core)).depositFor(ONE_MILLION_USDC, attacker);

        assertEq(
            IERC20(USDC_UNDERLYING).balanceOf(victim),
            victimBefore,
            "FIX: victim USDC not locked -- deposit reverted"
        );
        assertEq(core.balanceOf(victim),   0, "FIX: victim has no unwanted shares");
        assertEq(core.balanceOf(attacker), 0, "FIX: attacker received no shares");
    }

    // =========================================================================
    // TEST 4 -- Control: standard deposit() still cannot steal victim USDC
    // =========================================================================
    function test_control_standard_deposit_cannot_steal_victim_usdc() public {
        _victimApproves(ONE_MILLION_USDC);

        uint256 victimBefore   = IERC20(USDC_UNDERLYING).balanceOf(victim);
        uint256 attackerBefore = IERC20(USDC_UNDERLYING).balanceOf(attacker);

        vm.prank(attacker);
        vm.expectRevert();
        ERC4626Module(address(core)).deposit(ONE_MILLION_USDC, attacker);

        assertEq(IERC20(USDC_UNDERLYING).balanceOf(victim),   victimBefore,   "victim USDC unchanged");
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(attacker), attackerBefore, "attacker USDC unchanged");
    }

    // =========================================================================
    // TEST 5 -- FIX positive path: router deposits for a user (intended usage)
    //
    // Simulates DepositRouter flow:
    //   1. Router receives user's USDC (via Permit2, not shown here)
    //   2. Router (msg.sender) calls depositFor(amount, user)
    //   3. User receives shares; router's USDC is used as payment
    // =========================================================================
    function test_fix_router_can_deposit_for_user() public {
        address router = makeAddr("router");
        address depositor = makeAddr("depositor");

        // Router holds USDC (pulled from user via Permit2 off-chain)
        MockUSDC(USDC_UNDERLYING).mint(router, ONE_MILLION_USDC);
        vm.prank(router);
        IERC20(USDC_UNDERLYING).approve(address(core), ONE_MILLION_USDC);

        uint256 routerBefore    = IERC20(USDC_UNDERLYING).balanceOf(router);
        uint256 depositorBefore = core.balanceOf(depositor);

        // Router deposits: msg.sender = router = payer, receiver = depositor
        vm.prank(router);
        uint256 shares = ERC4626Module(address(core)).depositFor(ONE_MILLION_USDC, depositor);

        assertGt(shares, 0, "FIX: shares minted to depositor");
        assertEq(core.balanceOf(depositor) - depositorBefore, shares, "FIX: depositor received shares");
        assertEq(routerBefore - IERC20(USDC_UNDERLYING).balanceOf(router), ONE_MILLION_USDC, "FIX: router paid");
        assertEq(core.balanceOf(router), 0, "FIX: router received no shares");
    }

    // =========================================================================
    // TEST 6 -- Partial approval is no longer exploitable
    //
    // Old: attacker drained exactly the approved amount.
    // New: attacker has no USDC, reverts regardless of victim's approval size.
    // =========================================================================
    function test_fix_partial_approval_no_longer_exploitable() public {
        uint256 partialApproval = 100_000e6;

        MockUSDC(USDC_UNDERLYING).mint(victim, ONE_MILLION_USDC);
        vm.prank(victim);
        IERC20(USDC_UNDERLYING).approve(address(core), partialApproval);

        uint256 victimBefore = IERC20(USDC_UNDERLYING).balanceOf(victim);

        // Old attack was: depositFor(partialApproval, attacker, victim)
        // New call puts attacker as payer -- reverts
        vm.prank(attacker);
        vm.expectRevert();
        ERC4626Module(address(core)).depositFor(partialApproval, attacker);

        assertEq(
            IERC20(USDC_UNDERLYING).balanceOf(victim),
            victimBefore,
            "FIX: victim's partial approval is no longer exploitable"
        );
    }
}
