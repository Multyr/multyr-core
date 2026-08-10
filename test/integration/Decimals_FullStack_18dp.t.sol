// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreHarness } from "../helpers/CoreHarness.sol";
import { GlobalConfig } from "../../src/core/config/GlobalConfig.sol";
import { MockPriceOracleMiddleware } from "../helpers/MockPriceOracleMiddleware.sol";
import { ERC20Mock } from "../../src/mocks/ERC20Mock.sol";
import { StrategyMock } from "../helpers/StrategyMock.sol";
import { BufferManager } from "../../src/core/modules/BufferManager.sol";
import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";
import { RouterAllocationPolicy } from "../../src/core/modules/RouterAllocationPolicy.sol";
import { RouterRebalanceGuard } from "../../src/core/modules/RouterRebalanceGuard.sol";
import { ExecutionMemory } from "../../src/core/modules/ExecutionMemory.sol";
import { LiquidityOpsModule } from "../../src/core/modules/LiquidityOpsModule.sol";
import { AllocationTypes } from "../../src/interfaces/IAllocationTypes.sol";

/// @notice Full-stack proof that the decimals + oracle-normalization fixes work together
///         for a real 18-decimal (WETH-like) deployment: real GlobalConfig (oracle-backed),
///         real BufferManager (decimals-derived minRebalanceAmount), real
///         RouterAllocationPolicy + RouterRebalanceGuard + ExecutionMemory, and a real user
///         deposit — all wired through the actual CoreVault diamond dispatch, not mocks.
///
///         Scope note: exercises deposit -> build-plan -> evaluate (the path the decimals/
///         oracle fixes touch). Does not drive actual deployToStrategies/rebalanceStrategies
///         fund movement — that's plain ERC20 transfer mechanics, already asset-decimals-
///         agnostic and covered by the existing USDC-path test suite.
contract Decimals_FullStack_18dp_Test is Test {
    address internal governor;
    address internal owner;
    address internal keeper;
    address internal user;

    ERC20Mock internal weth; // 18 decimals
    GlobalConfig internal params;
    MockPriceOracleMiddleware internal oracle;
    CoreHarness internal vault;
    BufferManager internal bufferManager;
    StrategyMock internal stratA;
    StrategyMock internal stratB;
    RouterAllocationPolicy internal policy;
    RouterRebalanceGuard internal guard;
    ExecutionMemory internal execMem;

    function setUp() public {
        governor = makeAddr("governor");
        owner = makeAddr("owner");
        keeper = makeAddr("keeper");
        user = makeAddr("user");

        weth = new ERC20Mock("WETH", "WETH", 18);

        oracle = new MockPriceOracleMiddleware();
        vm.startPrank(governor);
        params = new GlobalConfig(governor, 50, 100, 2000, 86400, 10, 500, 3600, 3600);
        params.setAssetOracleConfig(address(weth), address(oracle), 3600);
        vm.stopPrank();

        vault = new CoreHarness(
            IERC20Metadata(address(weth)), "WETH Vault", "vWETH", owner, address(0xFEE), address(params)
        );

        // Real-world deploy-checklist step: GlobalConfig's default deposit caps
        // (defaultVaultDepositCap = 10_000_000e6, i.e. 6dp-shaped) are far too small in raw
        // 18dp terms for any real WETH deposit. A production deployment MUST set a
        // per-vault override — this is exactly what setVaultDepositLimits is for.
        vm.prank(governor);
        params.setVaultDepositLimits(address(vault), 10_000e18, 1_000e18, 0.001e18);

        // Real BufferManager, sized for 18dp (proves the BufferManager.sol fix in situ).
        IBufferManager.BufferConfig memory bufCfg;
        bufCfg.targetHotBps = 1000;
        bufCfg.minHotBps = 500;
        bufCfg.targetWarmBps = 9000;
        bufCfg.maxWarmBps = 10000;
        bufCfg.asset = address(weth);
        bufCfg.warmAdapter = address(0);
        bufCfg.paused = true;
        bufferManager = new BufferManager(owner, address(vault), bufCfg);
        assertEq(bufferManager.minRebalanceAmount(), 5_000e18, "sanity: BufferManager fix in effect");
        vault.setBufferManagerUnsafe(address(bufferManager));

        // Real user deposit — proves basic 18dp deposit mechanics with the real (non-mock)
        // BufferManager wired in. Done before addStrategyUnsafe below: that helper's
        // allowlist-timelock warp/restore dance leaves block.timestamp visibly advanced
        // (a pre-existing CoreHarness quirk, unrelated to the decimals fix), which would
        // otherwise make the deposit's warm-NAV freshness check see a large, confusing gap.
        weth._mint(user, 10e18);
        vm.startPrank(user);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // Two strategies registered via StrategyRouter, pre-funded directly (simulates
        // already-deployed capital without exercising the deploy path — out of scope here).
        stratA = new StrategyMock(address(weth));
        stratB = new StrategyMock(address(weth));
        vault.addStrategyUnsafe(address(stratA));
        vault.addStrategyUnsafe(address(stratB));
        weth._mint(address(stratA), 50e18);
        weth._mint(address(stratB), 50e18);

        // Set the oracle price AFTER the timestamp-advancing addStrategyUnsafe calls above,
        // so its lastUpdate is fresh relative to whatever block.timestamp tests actually run at.
        oracle.setPrice(address(weth), 3500e18); // $3500/WETH

        // V10 Policy/Guard/ExecutionMemory, real oracle-backed conversion.
        policy = new RouterAllocationPolicy(owner, address(0), address(0));
        guard = new RouterRebalanceGuard(owner, keeper, address(weth), address(params));
        execMem = new ExecutionMemory(owner, keeper);
        vm.startPrank(owner);
        guard.setOrchestrator(address(vault));
        guard.setExecutionMemory(address(execMem));
        vm.stopPrank();
        vault.setRebalanceModulesUnsafe(address(policy), address(guard), address(execMem));
    }

    function test_deposit_succeeds_at18dp() public view {
        assertEq(vault.balanceOf(user), 10e18);
        assertEq(weth.balanceOf(address(vault)), 10e18);
    }

    /// @dev Exercises the real delegatecall dispatch path (vault -> LiquidityOpsModule ->
    ///      Policy/Guard) end to end. The call must not revert: that alone proves the real
    ///      GlobalConfig resolves the oracle, the price fetch succeeds, and the decimals
    ///      conversion runs cleanly through the full diamond wiring.
    function test_fullStack_canRebalanceStrategies_doesNotRevert() public view {
        LiquidityOpsModule(address(vault)).canRebalanceStrategies();
    }

    /// @dev Calls Policy + Guard directly (bypassing vault dispatch) to inspect the actual
    ///      gate reason. Strategies hold 100 WETH (~$350,000) against guard.minMoveUsd of
    ///      $1000 — if the oracle conversion were broken (e.g. still comparing against a raw
    ///      1000*1e6 USDC-shaped constant instead of a real oracle-converted WETH amount),
    ///      this real-dollar-sized move could be wrongly gated as MIN_MOVE or blow up the
    ///      comparison entirely. It must not be.
    function test_fullStack_evaluatePlan_doesNotFalselyBlockOnMinMove() public {
        address[] memory strategies = new address[](2);
        strategies[0] = address(stratA);
        strategies[1] = address(stratB);
        uint256[] memory currentAllocs = new uint256[](2);
        currentAllocs[0] = 50e18;
        currentAllocs[1] = 50e18;
        uint256 tvl = 100e18;

        AllocationTypes.RebalancePlan memory plan = policy.buildRebalancePlan(strategies, currentAllocs, tvl);
        AllocationTypes.QueueSafetyContext memory qs;
        qs.availableIdleAfterPlanBps = 1000; // 10% idle/tvl, matches the 10 WETH deposit vs 100 WETH tvl

        AllocationTypes.PlanEvaluation memory r = guard.evaluatePlan(plan, tvl, 10e18, qs);
        assertTrue(
            r.reasonCode != uint8(AllocationTypes.GuardReason.MIN_MOVE),
            "must not be MIN_MOVE: a $350k WETH move must clear a $1000 floor"
        );
    }
}
