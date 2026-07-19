// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────────────────────────────────────────────────────────────────
// SPRINT SECURITY TEST -- deployToStrategiesWithPlan drain: two-layer fix
//
// ORIGINAL BUG (now fixed):
// ─────────────────────────
// `LiquidityOpsModule.deployToStrategiesWithPlan` was registered as ROLE_PUBLIC
// and accepted a caller-supplied plan without validating plan[i].strat addresses.
// Any EOA could supply their own address as plan[0].strat and receive the vault's
// full deployable surplus in one transaction (Critical severity).
//
// TWO-LAYER FIX APPLIED:
// ──────────────────────
// Layer 1 -- Role restriction (SelectorRegistry.sol, CoreHarness.sol):
//   deployToStrategiesWithPlan is now ROLE_OWNER_OR_GUARDIAN.
//   deployToStrategies (auto-plan, fully deterministic) remains ROLE_PUBLIC.
//   Rationale: a caller-supplied plan controls which registered strategies
//   receive capital and in what proportion -- that is an operator decision, not
//   a permissionless keeper action. Even with address validation, a public caller
//   could manipulate allocation to favour strategies they have a stake in.
//
// Layer 2 -- Strategy address validation (LiquidityOpsModule.sol):
//   Each leg is validated before summing amounts:
//     if (!r.isStrategyEnabled(plan[i].strat))
//         revert UnregisteredStrategy(plan[i].strat);
//   This ensures even the owner/guardian cannot route funds to arbitrary addresses.
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
import { CoreVault } from "../../src/core/CoreVault.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal mock strategy -- satisfies StrategyRouter.register()'s asset() check.
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
    address constant USDC_UNDERLYING = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 constant ONE_MILLION_USDC = 1_000_000e6;

    address internal owner;
    address internal guardian;
    address internal attacker;

    CoreHarness        internal core;
    MockUSDC           internal mock;
    MockParamsProvider internal params;
    MockStrategy       internal legitimateStrat;

    function setUp() public {
        owner    = address(this); // test contract is the vault owner
        guardian = makeAddr("guardian");
        attacker = makeAddr("attacker");

        mock = new MockUSDC();
        vm.etch(USDC_UNDERLYING, address(mock).code);

        params = new MockParamsProvider();
        core   = new CoreHarness(
            IERC20Metadata(USDC_UNDERLYING),
            "USDC Agg",
            "agUSDC",
            owner,
            owner,
            address(params)
        );

        // Set a guardian so ROLE_OWNER_OR_GUARDIAN has two valid callers
        core.setGuardianUnsafe(guardian);

        legitimateStrat = new MockStrategy(USDC_UNDERLYING);
        core.addStrategyUnsafe(address(legitimateStrat));
    }

    function _fundVault(uint256 amount) internal {
        MockUSDC(USDC_UNDERLYING).mint(address(core), amount);
    }

    // =========================================================================
    // TEST 1 -- Layer 1: attacker blocked at the role gate (NotOwnerOrGuardian)
    //
    // deployToStrategiesWithPlan is now ROLE_OWNER_OR_GUARDIAN. A random EOA
    // never reaches the strategy-validation logic -- CoreVault's dispatcher
    // rejects the call before delegating to the module.
    // =========================================================================
    function test_fix_layer1_attacker_blocked_by_role_gate_zero_config() public {
        _fundVault(ONE_MILLION_USDC);

        uint256 vaultBefore = IERC20(USDC_UNDERLYING).balanceOf(address(core));

        IStrategyRouter.Allocation[] memory plan = new IStrategyRouter.Allocation[](1);
        plan[0] = IStrategyRouter.Allocation({
            strat:                   attacker,
            amount:                  ONE_MILLION_USDC,
            fundsAlreadyTransferred: false
        });

        // Layer 1: role gate fires before strategy validation
        vm.prank(attacker);
        vm.expectRevert(CoreVault.NotOwnerOrGuardian.selector);
        LiquidityOpsModule(address(core)).deployToStrategiesWithPlan(
            plan,
            ONE_MILLION_USDC
        );

        assertEq(
            IERC20(USDC_UNDERLYING).balanceOf(address(core)),
            vaultBefore,
            "FIX L1: vault fully preserved -- role gate blocked the drain"
        );
    }

    // =========================================================================
    // TEST 2 -- Layer 1: attacker also blocked with realistic BufferManager config
    // =========================================================================
    function test_fix_layer1_attacker_blocked_realistic_config() public {
        MockBufferManagerForTests realisticBm =
            new MockBufferManagerForTests(address(core));

        IBufferManager.BufferConfig memory cfg;
        cfg.opsReserveTargetBps = 1000;
        cfg.maxWarmBps          = 2000;
        realisticBm.setBufferConfig(cfg);
        core.setBufferManagerUnsafe(address(realisticBm));

        _fundVault(ONE_MILLION_USDC);
        uint256 vaultBefore = IERC20(USDC_UNDERLYING).balanceOf(address(core));

        IStrategyRouter.Allocation[] memory plan = new IStrategyRouter.Allocation[](1);
        plan[0] = IStrategyRouter.Allocation({
            strat:                   attacker,
            amount:                  700_000e6,
            fundsAlreadyTransferred: false
        });

        vm.prank(attacker);
        vm.expectRevert(CoreVault.NotOwnerOrGuardian.selector);
        LiquidityOpsModule(address(core)).deployToStrategiesWithPlan(
            plan,
            700_000e6
        );

        assertEq(
            IERC20(USDC_UNDERLYING).balanceOf(address(core)),
            vaultBefore,
            "FIX L1: vault preserved -- role gate blocked 70% drain attempt"
        );
    }

    // =========================================================================
    // TEST 3 -- Control: safe on-chain path (deployToStrategies) stays ROLE_PUBLIC
    //
    // The automatic path uses r.planDeposit() -- the caller has zero influence
    // over fund routing. Keeping it permissionless is correct and unaffected.
    // =========================================================================
    function test_control_safe_path_routes_to_registered_strategy_only() public {
        _fundVault(ONE_MILLION_USDC);

        uint256 stratBefore    = IERC20(USDC_UNDERLYING).balanceOf(address(legitimateStrat));
        uint256 attackerBefore = IERC20(USDC_UNDERLYING).balanceOf(attacker);

        // Attacker can still call the auto-plan path -- no influence over routing
        vm.prank(attacker);
        LiquidityOpsModule(address(core)).deployToStrategies(ONE_MILLION_USDC);

        assertEq(
            IERC20(USDC_UNDERLYING).balanceOf(attacker),
            attackerBefore,
            "Auto-plan path never transfers to the caller"
        );
        assertGt(
            IERC20(USDC_UNDERLYING).balanceOf(address(legitimateStrat)),
            stratBefore,
            "Auto-plan path routed to the registered strategy as expected"
        );
    }

    // =========================================================================
    // TEST 4 -- Layer 2: owner supplying an unregistered strategy is also blocked
    //
    // Even after passing the role gate, the strategy-address validation (Layer 2)
    // prevents the owner/guardian from routing funds to an arbitrary address.
    // This defends against a compromised or malicious owner key.
    // =========================================================================
    function test_fix_layer2_owner_blocked_for_unregistered_strategy() public {
        _fundVault(ONE_MILLION_USDC);
        uint256 vaultBefore = IERC20(USDC_UNDERLYING).balanceOf(address(core));

        address arbitraryAddr = makeAddr("arbitraryAddr");

        IStrategyRouter.Allocation[] memory plan = new IStrategyRouter.Allocation[](1);
        plan[0] = IStrategyRouter.Allocation({
            strat:                   arbitraryAddr,
            amount:                  ONE_MILLION_USDC,
            fundsAlreadyTransferred: false
        });

        // Owner passes the role gate but hits Layer 2 (strategy validation)
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityOpsModule.UnregisteredStrategy.selector, arbitraryAddr)
        );
        LiquidityOpsModule(address(core)).deployToStrategiesWithPlan(
            plan,
            ONE_MILLION_USDC
        );

        assertEq(
            IERC20(USDC_UNDERLYING).balanceOf(address(core)),
            vaultBefore,
            "FIX L2: vault preserved -- strategy validation blocked owner's unregistered route"
        );
    }

    // =========================================================================
    // TEST 5 -- Positive path: owner with a registered strategy succeeds
    //
    // Confirms the fix does not break the intended use case. Owner builds a plan
    // pointing to legitimateStrat (registered + enabled) and it executes correctly.
    // Guardian can do the same.
    // =========================================================================
    function test_fix_positive_owner_with_registered_strategy_succeeds() public {
        _fundVault(ONE_MILLION_USDC);

        uint256 deployAmount   = ONE_MILLION_USDC;
        uint256 stratBefore    = IERC20(USDC_UNDERLYING).balanceOf(address(legitimateStrat));
        uint256 attackerBefore = IERC20(USDC_UNDERLYING).balanceOf(attacker);

        IStrategyRouter.Allocation[] memory plan = new IStrategyRouter.Allocation[](1);
        plan[0] = IStrategyRouter.Allocation({
            strat:                   address(legitimateStrat),
            amount:                  deployAmount,
            fundsAlreadyTransferred: false
        });

        // Owner (address(this)) calls -- passes both role gate and strategy validation
        LiquidityOpsModule(address(core)).deployToStrategiesWithPlan(
            plan,
            deployAmount
        );

        assertEq(
            IERC20(USDC_UNDERLYING).balanceOf(address(legitimateStrat)),
            stratBefore + deployAmount,
            "FIX: funds correctly routed to registered strategy by owner"
        );
        assertEq(
            IERC20(USDC_UNDERLYING).balanceOf(attacker),
            attackerBefore,
            "FIX: attacker received nothing"
        );
    }

    // =========================================================================
    // TEST 6 -- Guardian can also call deployToStrategiesWithPlan
    //
    // ROLE_OWNER_OR_GUARDIAN allows the guardian (emergency multisig) to use
    // this function for urgent operational adjustments.
    // =========================================================================
    function test_fix_guardian_can_also_call_deployWithPlan() public {
        _fundVault(ONE_MILLION_USDC);

        uint256 stratBefore = IERC20(USDC_UNDERLYING).balanceOf(address(legitimateStrat));

        IStrategyRouter.Allocation[] memory plan = new IStrategyRouter.Allocation[](1);
        plan[0] = IStrategyRouter.Allocation({
            strat:                   address(legitimateStrat),
            amount:                  ONE_MILLION_USDC,
            fundsAlreadyTransferred: false
        });

        // Guardian passes the role gate
        vm.prank(guardian);
        LiquidityOpsModule(address(core)).deployToStrategiesWithPlan(
            plan,
            ONE_MILLION_USDC
        );

        assertGt(
            IERC20(USDC_UNDERLYING).balanceOf(address(legitimateStrat)),
            stratBefore,
            "Guardian can route funds to registered strategies via deployToStrategiesWithPlan"
        );
    }
}
