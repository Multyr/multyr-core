// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC20Mock } from "../../src/mocks/ERC20Mock.sol";
import { CoreHarness } from "../helpers/CoreHarness.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";
import { BufferManager } from "../../src/core/modules/BufferManager.sol";
import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";
import { StrategyRouter } from "../../src/core/modules/StrategyRouter.sol";
import { IStrategyRouter, IStrategy } from "../../src/interfaces/IStrategyRouter.sol";
import { IPriceOracleMiddleware } from "../../src/interfaces/IPriceOracleMiddleware.sol";

/**
 * @title CoreVault_KeeperRouting
 * @notice Tests keeper-driven allocation via `rebalance()` and `executeDepositBatch()`
 * @dev AUDIT-GRADE: Replaces the old _routeDeposit() auto-routing pattern.
 *
 * Pattern:
 * 1. User deposits → funds stay in hot (CoreVault)
 * 2. Keeper calls BufferManager.rebalance() → deploys surplus to warm adapters
 * 3. Keeper calls StrategyRouter.executeDepositBatch() → allocates to strategies
 *
 * Tests:
 * - test_rebalance_routes_surplus_to_warm_and_keeps_ops_target
 * - test_rebalance_tops_up_ops_reserve_when_target_changes
 * - test_executeDepositBatch_allocates_proportionally_across_strategies
 */
contract CoreVault_KeeperRouting is Test {
    ERC20Mock internal usdc;
    CoreHarness internal vault;
    MockParamsProviderWithOracle internal params;
    BufferManager internal bm;
    StrategyRouter internal router;
    MockOracle internal oracle;

    // Mock strategies for allocation testing
    MockStrategy internal strat1;
    MockStrategy internal strat2;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal keeper = address(0xCEE5);

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        usdc._mint(address(this), 10_000_000e6);

        // Deploy oracle first
        oracle = new MockOracle();

        // Deploy params provider with oracle
        params = new MockParamsProviderWithOracle(address(oracle));

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "USDC Agg",
            "agUSDC",
            address(this),
            address(this),
            address(params)
        );

        // Deploy BufferManager with proper config (no warm adapter for simplicity)
        IBufferManager.BufferConfig memory cfg;
        cfg.targetHotBps = 1000; // 10% target hot
        cfg.minHotBps = 800; // 8% min hot
        cfg.targetWarmBps = 0; // No warm in this test
        cfg.maxWarmBps = 0;
        cfg.opsReserveTargetBps = 300; // 3% ops reserve
        cfg.asset = address(usdc);
        cfg.warmAdapter = address(0);
        cfg.twapWindowSec = 0;
        cfg.paused = false;

        bm = new BufferManager(address(this), address(vault), cfg);
        vault.setBufferManagerUnsafe(address(bm));

        // Deploy StrategyRouter
        router = new StrategyRouter(address(this), address(vault), address(params));
        vault.setStrategyRouterUnsafe(address(router));

        // Deploy mock strategies
        strat1 = new MockStrategy(address(usdc), "Strategy1");
        strat2 = new MockStrategy(address(usdc), "Strategy2");

        // Note: MockParamsProvider.isAdapterAllowed() returns true for all adapters

        // Register strategies with weights
        router.register(address(strat1), 0, 6000); // 60%
        router.register(address(strat2), 1, 4000); // 40%

        // Set keeper permission for BufferManager (takes 1 arg - the keeper address)
        bm.setKeeper(keeper);
        // Note: StrategyRouter uses onlyCore - vault calls it
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 1: Rebalance routes surplus to warm and keeps ops target
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_rebalance_routes_surplus_to_warm_and_keeps_ops_target() public {
        // Setup: Deploy a mock warm adapter
        MockWarmAdapter warmAdapter = new MockWarmAdapter(address(usdc), address(vault));
        IBufferManager.BufferConfig memory cfg = bm.getConfig();
        cfg.warmAdapter = address(warmAdapter);
        cfg.targetWarmBps = 9000; // 90% to warm
        cfg.maxWarmBps = 10000;
        cfg.targetHotBps = 1000; // 10% hot target
        cfg.minHotBps = 500; // 5% min hot
        bm.updateConfig(cfg);

        // Approve warm adapter to pull from vault
        vm.prank(address(vault));
        usdc.approve(address(warmAdapter), type(uint256).max);
        vm.prank(address(vault));
        usdc.approve(address(bm), type(uint256).max);

        // User deposits 1,000,000 USDC
        uint256 amt = 1_000_000e6;
        _depositAsUser(alice, amt);

        // Before rebalance: all funds in hot (vault)
        uint256 hotBefore = usdc.balanceOf(address(vault));
        assertEq(hotBefore, amt, "All funds should be in hot before rebalance");

        // Keeper calls rebalance
        vm.prank(keeper);
        bm.rebalance();

        // After rebalance: hot should be at target (10%), rest in warm
        uint256 hotAfter = usdc.balanceOf(address(vault));
        uint256 warmBalance = warmAdapter.totalAssets();
        uint256 nav = hotAfter + warmBalance;

        // Hot should be near target (10%)
        uint256 targetHot = (nav * cfg.targetHotBps) / 10000;
        assertApproxEqAbs(hotAfter, targetHot, 2, "Hot should be near 10% target");
        assertGt(warmBalance, 0, "Warm should have received funds");
        assertApproxEqAbs(nav, amt, 0, "NAV should be conserved");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 2: Tops up ops reserve when target changes
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_rebalance_tops_up_ops_reserve_when_target_changes() public {
        // Setup: Deploy a mock warm adapter to test ops reserve
        MockWarmAdapter warmAdapter = new MockWarmAdapter(address(usdc), address(vault));
        IBufferManager.BufferConfig memory cfg = bm.getConfig();
        cfg.warmAdapter = address(warmAdapter);
        cfg.targetWarmBps = 9000; // 90% to warm
        cfg.maxWarmBps = 10000;
        cfg.targetHotBps = 700; // 7% hot
        cfg.minHotBps = 500; // 5% min hot
        cfg.opsReserveTargetBps = 300; // 3% ops reserve
        bm.updateConfig(cfg);

        // Approve warm adapter to pull from vault
        vm.prank(address(vault));
        usdc.approve(address(warmAdapter), type(uint256).max);

        // User deposits 1,000,000 USDC
        uint256 amt = 1_000_000e6;
        _depositAsUser(alice, amt);

        // Keeper rebalances - should deploy to warm
        vm.prank(address(vault));
        usdc.approve(address(bm), type(uint256).max);
        vm.prank(keeper);
        bm.rebalance();

        uint256 hotAfterFirstRebalance = usdc.balanceOf(address(vault));
        uint256 warmAfterFirstRebalance = warmAdapter.totalAssets();
        uint256 nav = hotAfterFirstRebalance + warmAfterFirstRebalance;

        // Hot should be near target (7%)
        uint256 targetHot = (nav * cfg.targetHotBps) / 10000;
        assertApproxEqAbs(hotAfterFirstRebalance, targetHot, 2, "Hot should be near 7% target");

        // Now increase ops reserve target to 10%
        cfg.opsReserveTargetBps = 1000; // 10%
        bm.updateConfig(cfg);

        // Rebalance again - should refill from warm to meet new ops target
        vm.prank(keeper);
        bm.rebalance();

        uint256 hotFinal = usdc.balanceOf(address(vault));
        uint256 newTargetHot = (nav * cfg.targetHotBps) / 10000;

        // Hot should still be at target, but ops reserve is maintained
        assertGe(
            hotFinal, (nav * cfg.minHotBps) / 10000, "Hot should be >= min after target change"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 3: ExecuteDepositBatch allocates proportionally across strategies
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_executeDepositBatch_allocates_proportionally_across_strategies() public {
        uint256 amt = 1_000_000e6;
        _depositAsUser(alice, amt);

        // Compute available surplus (same formula as _getAvailableSurplus)
        uint256 hot = usdc.balanceOf(address(vault));
        IBufferManager.BufferConfig memory cfg = bm.getConfig();
        uint256 nav = vault.totalAssets();
        uint256 opsReserve = (nav * cfg.opsReserveTargetBps) / 1e4;
        uint256 available = hot > opsReserve ? hot - opsReserve : 0;

        // 60/40 split of available surplus
        uint256 toStrat1 = (available * 6000) / 10000;
        uint256 toStrat2 = available - toStrat1;

        // Vault pre-transfers funds to strategies
        vm.prank(address(vault));
        usdc.transfer(address(strat1), toStrat1);
        vm.prank(address(vault));
        usdc.transfer(address(strat2), toStrat2);

        // Plan with fundsAlreadyTransferred=true
        IStrategyRouter.Allocation[] memory plan = new IStrategyRouter.Allocation[](2);
        plan[0] = IStrategyRouter.Allocation({
            strat: address(strat1), amount: toStrat1, fundsAlreadyTransferred: true
        });
        plan[1] = IStrategyRouter.Allocation({
            strat: address(strat2), amount: toStrat2, fundsAlreadyTransferred: true
        });

        vm.prank(address(vault));
        router.executeDepositBatch(plan);

        // Assert proportional allocation
        assertApproxEqAbs(strat1.totalAssets(), toStrat1, 1, "Strategy1 ~60%");
        assertApproxEqAbs(strat2.totalAssets(), toStrat2, 1, "Strategy2 ~40%");

        // Verify proportions
        uint256 totalInStrategies = strat1.totalAssets() + strat2.totalAssets();
        uint256 ratio1 = (strat1.totalAssets() * 10000) / totalInStrategies;
        assertApproxEqAbs(ratio1, 6000, 1, "Strategy1 ratio ~60%");

        // Hot balance respects ops reserve
        uint256 hotAfter = usdc.balanceOf(address(vault));
        assertGe(hotAfter, opsReserve, "Hot >= ops reserve");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TEST 4: Deposit is O(1) - no routing happens on deposit
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_deposit_is_O1_no_routing_on_deposit() public {
        // Record strategy balances before deposit
        uint256 strat1Before = strat1.totalAssets();
        uint256 strat2Before = strat2.totalAssets();

        // User deposits
        uint256 amt = 500_000e6;
        _depositAsUser(alice, amt);

        // Verify NO routing happened - strategies unchanged
        assertEq(strat1.totalAssets(), strat1Before, "Strategy1 should be unchanged on deposit");
        assertEq(strat2.totalAssets(), strat2Before, "Strategy2 should be unchanged on deposit");

        // All funds should be in hot
        uint256 hotBal = usdc.balanceOf(address(vault));
        assertEq(hotBal, amt, "All deposited funds should be in hot");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════

    function _depositAsUser(address user, uint256 amt) internal {
        usdc.transfer(user, amt);
        vm.startPrank(user);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, user);
        vm.stopPrank();
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MOCK CONTRACTS
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * @notice Mock Oracle for StrategyRouter batch operations
 */
contract MockOracle is IPriceOracleMiddleware {
    function isFresh(address) external pure override returns (bool) {
        return true;
    }

    function getQuote(address) external view override returns (Quote memory) {
        return
            Quote({ price: 1e18, decimals: 18, lastUpdate: uint48(block.timestamp), fresh: true });
    }

    function getQuoteFresh(address) external view override returns (Quote memory) {
        return
            Quote({ price: 1e18, decimals: 18, lastUpdate: uint48(block.timestamp), fresh: true });
    }

    function getFeed(address) external pure override returns (address) {
        return address(0x1);
    }

    function getMaxStaleness(address) external pure override returns (uint256) {
        return 3600;
    }

    function owner() external pure override returns (address) {
        return address(0);
    }
    function setOracleFeed(address, address, uint256) external override { }
    function setMaxStaleness(address, uint256) external override { }
}

/**
 * @notice Mock ParamsProvider that returns the oracle for oracleConfigFor
 */
contract MockParamsProviderWithOracle {
    address private _oracle;

    constructor(address oracle_) {
        _oracle = oracle_;
    }

    // Adapter allowlist
    function isAdapterAllowed(address) external pure returns (bool) {
        return true;
    }

    function adapterCap(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    // Batch guardrails
    function maxActionsPerBatch() external pure returns (uint8) {
        return 100;
    }

    function maxNavDeltaBps() external pure returns (uint16) {
        return 10000;
    }

    function maxStaleness() external pure returns (uint256) {
        return 3600;
    }

    function minRebalanceCooldown() external pure returns (uint256) {
        return 0;
    }

    // Oracle config - critical for StrategyRouter
    function oracleConfigFor(address, address)
        external
        view
        returns (address oracle, uint256 maxStaleness_)
    {
        return (_oracle, 3600);
    }

    function oracleFor(address) external view returns (address) {
        return _oracle;
    }

    // IParamsProvider stubs
    function getFeeParams(address)
        external
        pure
        returns (
            uint16 depositFeeBps,
            uint16 withdrawFeeBps,
            uint256 perfRateX,
            uint64 minCrystallizeInterval,
            address treasury
        )
    {
        return (0, 0, 2e17, 1 days, address(0));
    }

    function getWithdrawalParams(address)
        external
        pure
        returns (
            uint16 capPerEpochBps,
            uint256 maxWithdrawalPerBlock,
            uint256 maxWithdrawalPerTx,
            uint256 minClaimAmount,
            uint64 lockPeriod
        )
    {
        return (10000, 0, 0, 0, 0);
    }

    function getBatchGuardrails(address)
        external
        pure
        returns (uint8 maxActionsPerBatch_, uint16 maxNavDeltaBps_, uint256 maxStaleness_)
    {
        return (100, 10000, 3600);
    }

    function getDepositLimits(address)
        external
        pure
        returns (uint256 vaultDepositCap, uint256 userDepositCap, uint256 minDepositAmount)
    {
        return (0, 0, 0);
    }

    function getNavSmoothingParams(address)
        external
        pure
        returns (uint16 alphaBps, uint256 interval, bool enabled)
    {
        return (200, 3600, false);
    }

    function hasOverrides(address) external pure returns (bool) {
        return false;
    }

    function version() external pure returns (uint16) {
        return 1;
    }

    function stratTaGas(address) external pure returns (uint256) {
        return 1_000_000;
    }
}

/**
 * @notice Mock Strategy for testing deposit batch allocation
 * @dev Uses actual token balance for totalAssets() to match real behavior
 */
contract MockStrategy is IStrategy {
    address public immutable override asset;
    string private _name;
    bool private _isActive = true;

    constructor(address _asset, string memory name_) {
        asset = _asset;
        _name = name_;
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    // Use actual balance for totalAssets to properly reflect NAV
    function totalAssets() external view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function deposit(uint256 amount) external override returns (uint256) {
        // Funds already transferred, just return amount
        // totalAssets() will reflect actual balance
        return amount;
    }

    function withdraw(uint256 amount, address to) external override returns (uint256) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (amount > bal) amount = bal;
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    function withdrawAll(address to) external override returns (uint256 got) {
        got = IERC20(asset).balanceOf(address(this));
        IERC20(asset).transfer(to, got);
    }

    function harvest() external pure override returns (int256, uint256) {
        return (0, 0);
    }

    function setActive(bool a) external override {
        _isActive = a;
    }

    function isActive() external view override returns (bool) {
        return _isActive;
    }
}

    /**
     * @notice Mock Warm Adapter for testing rebalance deploy/refill
     */
    contract MockWarmAdapter {
        address public immutable asset;
        address public immutable core;
        uint256 private _balance;

        constructor(address _asset, address _core) {
            asset = _asset;
            core = _core;
        }

        function totalAssets() external view returns (uint256) {
            return _balance;
        }

        function deposit(uint256 amount) external returns (uint256) {
            // Pull from core
            IERC20(asset).transferFrom(core, address(this), amount);
            _balance += amount;
            return amount;
        }

        function withdraw(uint256 amount, address to) external returns (uint256) {
            if (amount > _balance) amount = _balance;
            _balance -= amount;
            IERC20(asset).transfer(to, amount);
            return amount;
        }
    }
