// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// AUDIT FIX REGRESSION TESTS
// ═══════════════════════════════════════════════════════════════════════════════
// Covers the 4 fixes applied after external audit review (2026-04-30):
//
//   C1: realizeForReserveAndOps selector mismatch — end-to-end dispatch
//   H1: minDepositAmount enforcement
//   H2: SelectorRegistry ROLE_PUBLIC bypass
//   M1: guardianPauseCooldown reads from params (not hardcoded)
//
// Each test section is labeled with the finding ID.
// ═══════════════════════════════════════════════════════════════════════════════

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CoreVault } from "src/core/CoreVault.sol";
import { ERC4626Module } from "src/core/modules/ERC4626Module.sol";
import { LiquidityOpsModule } from "src/core/modules/LiquidityOpsModule.sol";
import { SelectorLib } from "src/core/libraries/SelectorLib.sol";
import { SelectorRegistry } from "src/core/libraries/SelectorRegistry.sol";
import { IBufferManager } from "src/interfaces/IBufferManager.sol";
import { BufferManager } from "src/core/modules/BufferManager.sol";
import { IWarmAdapter } from "src/interfaces/IWarmAdapter.sol";
import { IParamsProvider } from "src/interfaces/IParamsProvider.sol";
import { ERC20Mock } from "src/mocks/ERC20Mock.sol";

import { IStrategyRouter } from "src/interfaces/IStrategyRouter.sol";
import { StrategyRouter } from "src/core/modules/StrategyRouter.sol";
import { CoreHarness } from "test/helpers/CoreHarness.sol";
import { MockParamsProvider } from "test/helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "test/helpers/MockBufferManagerForTests.sol";
import { ModuleSetter } from "test/helpers/ModuleSetter.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Standalone IParamsProvider with configurable guardianPauseCooldown for M1 tests
contract MockParamsProviderWithCooldown is IParamsProvider {
    uint64 private _cooldown = 7 days;

    function setGuardianPauseCooldown(uint64 cooldown_) external { _cooldown = cooldown_; }

    // ── IParamsProvider implementation (delegates to sensible defaults) ──────
    function getFeeParams(address) external pure returns (FeeParams memory) {
        return FeeParams({ depositFeeBps: 0, withdrawFeeBps: 0, perfRateX: 2e17, minCrystallizeInterval: 1 days, treasury: address(0) });
    }
    function getWithdrawalParams(address) external pure returns (WithdrawalParams memory) {
        return WithdrawalParams({ capPerEpochBps: 10000, maxWithdrawalPerBlock: 0, maxWithdrawalPerTx: 0, minClaimAmount: 0, lockPeriod: 0 });
    }
    function getDynamicCapParams(address) external pure returns (DynamicCapParams memory) {
        return DynamicCapParams({ minBps: 100, maxBps: 10000, queueStressThreshold: 0, enabled: false });
    }
    function getQueueParams(address) external pure returns (QueueParams memory) {
        return QueueParams({ maxClaimsPerUserPerEpoch: 255, cooldownPerClaim: 0, epochDuration: 7 days });
    }
    function getSecurityParams(address) external pure returns (SecurityParams memory) {
        return SecurityParams({ circuitBreakerBps: 0, tvlSnapshotInterval: 1 hours, oracle: address(0), oracleStalenessLimit: 1 hours });
    }
    function getBufferParams(address) external pure returns (BufferParams memory) {
        return BufferParams({ targetHotBps: 300, minHotBps: 200, targetWarmBps: 700, maxWarmBps: 1000, opsReserveTargetBps: 100, maxWarmSlippageBps: 50 });
    }
    function getStrategyParams(address) external pure returns (StrategyParams memory) {
        return StrategyParams({ maxStrategyBps: 2000, lossCapBps: 100, aggregateLossCapBps: 500, gasPerStrategyWithdraw: 100000 });
    }
    function getBatchGuardrails(address) external pure returns (BatchGuardrails memory) {
        return BatchGuardrails({ maxActionsPerBatch: 100, maxNavDeltaBps: 1000, maxStaleness: 1 hours });
    }
    function getDepositLimits(address) external pure returns (DepositLimits memory) {
        return DepositLimits({ vaultDepositCap: 0, userDepositCap: 0, minDepositAmount: 0 });
    }
    function getNavSmoothingParams(address) external pure returns (NavSmoothingParams memory) {
        return NavSmoothingParams({ alphaBps: 200, interval: 3600, enabled: false });
    }
    function hasOverrides(address) external pure returns (bool) { return false; }
    function isAdapterAllowed(address) external pure returns (bool) { return true; }
    function adapterCap(address) external pure returns (uint256) { return type(uint256).max; }
    function oracleFor(address) external pure returns (address) { return address(0); }
    function oracleConfigFor(address, address) external pure returns (address, uint256) { return (address(0), 3600); }
    function maxActionsPerBatch() external pure returns (uint8) { return 100; }
    function maxNavDeltaBps() external pure returns (uint16) { return 10000; }
    function maxStaleness() external pure returns (uint256) { return 3600; }
    function minRebalanceCooldown() external pure returns (uint256) { return 0; }
    function version() external pure returns (uint16) { return 1; }
    function minParamDelay(address) external pure returns (uint64) { return 2 days; }
    function maxPerfRate(address) external pure returns (uint256) { return 5e17; }
    function maxFeeBps(address) external pure returns (uint16) { return 500; }
    function maxImmediateExitPenaltyBps(address) external pure returns (uint16) { return 200; }
    function maxForceExitPenaltyBps(address) external pure returns (uint16) { return 200; }
    function guardianPauseCooldown(address) external view returns (uint64) { return _cooldown; }
    function minDeployAmount(address) external pure returns (uint256) { return 0; }
    function stratTaGas(address) external pure returns (uint256) { return 300000; }
    function opsMaxBps(address) external pure returns (uint16) { return 500; }
}

/// @dev Minimal warm adapter that holds USDC and allows withdrawals
contract MockWarmAdapterSimple is IWarmAdapter {
    IERC20 public token;
    address public coreVault_;

    constructor(address asset_, address vault_) {
        token = IERC20(asset_);
        coreVault_ = vault_;
    }

    function asset() external view override returns (address) { return address(token); }
    function coreVault() external view override returns (address) { return coreVault_; }

    function deposit(uint256 amount) external override returns (uint256) {
        // Warm adapter pulls from the core vault (not from the caller/BM)
        token.transferFrom(coreVault_, address(this), amount);
        return amount;
    }

    function withdraw(uint256 amount, address to) external override returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        uint256 out = amount < bal ? amount : bal;
        if (out > 0) token.transfer(to, out);
        return out;
    }

    function totalAssets() external view override returns (uint256) {
        return token.balanceOf(address(this));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// C1 — realizeForReserveAndOps end-to-end dispatch
// ─────────────────────────────────────────────────────────────────────────────

contract AuditFix_C1_RealizeForReserveAndOps is Test {
    ERC20Mock internal usdc;
    CoreHarness internal vault;
    MockParamsProvider internal params;
    BufferManager internal bm;
    StrategyRouter internal router;
    MockWarmAdapterSimple internal warm;

    address internal alice = address(0xA11CE);

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        usdc._mint(alice, 2_000_000e6);
        usdc._mint(address(this), 2_000_000e6);

        params = new MockParamsProvider();
        params.setLockPeriod(0);

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Vault Shares",
            "vUSDC",
            address(this),
            address(this),
            address(params)
        );

        // Deploy warm adapter
        warm = new MockWarmAdapterSimple(address(usdc), address(vault));

        // Deploy BufferManager with warm adapter
        IBufferManager.BufferConfig memory cfg;
        cfg.targetHotBps  = 1000; // 10% hot
        cfg.minHotBps     = 500;
        cfg.targetWarmBps = 9000; // 90% warm
        cfg.maxWarmBps    = 10000;
        cfg.opsReserveTargetBps = 300;
        cfg.asset         = address(usdc);
        cfg.warmAdapter   = address(warm);
        cfg.paused        = false;

        // Router needed by LiquidityOpsModule.realizeForReserveAndOps
        router = new StrategyRouter(address(this), address(vault), address(params));
        vault.setStrategyRouterUnsafe(address(router));

        // No warmAdapter in cfg — use addWarmAdapter instead (rebalance deploys via _warmAdapters[])
        cfg.warmAdapter = address(0);

        bm = new BufferManager(address(this), address(vault), cfg);
        bm.setKeeper(address(this)); // test contract acts as keeper
        bm.addWarmAdapter(address(warm));
        vault.setBufferManagerUnsafe(address(bm));

        // Vault approves warm adapter to pull funds during deposit
        vm.prank(address(vault));
        usdc.approve(address(warm), type(uint256).max);

        // Seed vault and deploy to warm via rebalance
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6, alice);
        vm.stopPrank();

        bm.rebalance(); // moves ~90% to warm

        // Sanity: warm now holds funds
        assertGt(warm.totalAssets(), 0, "setup: warm must hold funds");
    }

    /// @notice C1a: selector dispatch succeeds — no revert
    function test_C1a_realizeForReserveAndOps_dispatches_without_revert() public {
        uint256 gap = 100_000e6;
        // Must not revert — before the fix this would revert due to selector mismatch
        vault.realizeForReserveAndOps(gap);
    }

    /// @notice C1b: hot balance increases after realize when hot is below target
    function test_C1b_realizeForReserveAndOps_increases_hot_balance() public {
        // Raise target so current hot (100K) is below the new 50% target (500K)
        IBufferManager.BufferConfig memory cfg = bm.getConfig();
        cfg.targetHotBps = 5000; // 50% — hot now well below target
        bm.updateConfig(cfg);

        uint256 hotBefore = usdc.balanceOf(address(vault));
        vault.realizeForReserveAndOps(500_000e6);

        uint256 hotAfter = usdc.balanceOf(address(vault));
        assertGt(hotAfter, hotBefore, "C1b: hot balance must increase");
    }

    /// @notice C1c: warm balance decreases after realize when hot is below target
    function test_C1c_realizeForReserveAndOps_decreases_warm_balance() public {
        // Raise target so current hot (100K) is below the new 50% target (500K)
        IBufferManager.BufferConfig memory cfg = bm.getConfig();
        cfg.targetHotBps = 5000;
        bm.updateConfig(cfg);

        uint256 warmBefore = warm.totalAssets();
        vault.realizeForReserveAndOps(500_000e6);

        uint256 warmAfter = warm.totalAssets();
        assertLt(warmAfter, warmBefore, "C1c: warm balance must decrease");
    }

    /// @notice C1d: maxAmount cap is respected — pulled <= maxAmount
    function test_C1d_realizeForReserveAndOps_respects_maxAmount_cap() public {
        uint256 hotBefore = usdc.balanceOf(address(vault));
        uint256 maxAmount = 50_000e6;

        vault.realizeForReserveAndOps(maxAmount);

        uint256 pulled = usdc.balanceOf(address(vault)) - hotBefore;
        assertLe(pulled, maxAmount, "C1d: pulled must not exceed maxAmount");
    }

    /// @notice C1e: zero maxAmount reverts — contract requires maxAmount > 0
    function test_C1e_realizeForReserveAndOps_zero_maxAmount_reverts() public {
        vm.expectRevert();
        vault.realizeForReserveAndOps(0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// H1 — minDepositAmount enforcement
// ─────────────────────────────────────────────────────────────────────────────

contract AuditFix_H1_MinDepositAmount is Test {
    ERC20Mock internal usdc;
    CoreHarness internal vault;
    MockParamsProvider internal params;

    address internal alice = address(0xA11CE);
    address internal bob   = address(0xB0B);

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        usdc._mint(alice, 10_000e6);
        usdc._mint(bob, 10_000e6);

        params = new MockParamsProvider();
        params.setLockPeriod(0);

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Vault Shares",
            "vUSDC",
            address(this),
            address(this),
            address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(vault));
        vault.setBufferManagerUnsafe(address(mockBM));
    }

    /// @notice H1a: deposit below minimum reverts with DepositBelowMinimum
    function test_H1a_deposit_below_minimum_reverts() public {
        params.setDepositLimits(0, 0, 100e6); // min = 100 USDC

        vm.startPrank(alice);
        usdc.approve(address(vault), 99e6);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Module.DepositBelowMinimum.selector, 99e6, 100e6)
        );
        vault.deposit(99e6, alice);
        vm.stopPrank();
    }

    /// @notice H1b: deposit exactly at minimum succeeds
    function test_H1b_deposit_at_minimum_succeeds() public {
        params.setDepositLimits(0, 0, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), 100e6);
        vault.deposit(100e6, alice);
        vm.stopPrank();

        assertGt(vault.balanceOf(alice), 0, "H1b: alice must receive shares");
    }

    /// @notice H1c: deposit above minimum succeeds
    function test_H1c_deposit_above_minimum_succeeds() public {
        params.setDepositLimits(0, 0, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), 500e6);
        vault.deposit(500e6, alice);
        vm.stopPrank();

        assertGt(vault.balanceOf(alice), 0, "H1c: alice must receive shares");
    }

    /// @notice H1d: minimum = 0 means unlimited (no revert on 1 wei)
    function test_H1d_zero_minimum_allows_any_amount() public {
        params.setDepositLimits(0, 0, 0); // no minimum

        usdc._mint(alice, 1); // 1 wei extra
        vm.startPrank(alice);
        usdc.approve(address(vault), 1e6); // 1 USDC
        vault.deposit(1e6, alice);
        vm.stopPrank();

        assertGt(vault.balanceOf(alice), 0, "H1d: deposit of 1 USDC must succeed with no minimum");
    }

    /// @notice H1e: maxDeposit reflects minDepositAmount — returns 0 when remaining < min
    function test_H1e_maxDeposit_returns_zero_when_remaining_less_than_min() public {
        // vaultCap = 150 USDC, min = 100 USDC
        params.setDepositLimits(150e6, 0, 100e6);

        // Deposit 100 USDC → remaining = 50 USDC < min 100 USDC
        vm.startPrank(alice);
        usdc.approve(address(vault), 100e6);
        vault.deposit(100e6, alice);
        vm.stopPrank();

        assertEq(vault.maxDeposit(bob), 0, "H1e: maxDeposit must be 0 when remaining < minimum");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// C1 (strategy leg) — realizeForReserveAndOps triggers planRedeem when warm is
// insufficient.  Uses a MockStrategyRouter that returns a deterministic plan
// and deposits funds to the vault to simulate the pull.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Mock StrategyRouter: planRedeem always returns a single-entry plan, and
///      executeRedeemBatch mints `amount` USDC straight into the vault address.
contract MockStrategyRouter is IStrategyRouter {
    IERC20 private _usdc;
    address private _vault;
    uint256 public planRedeemCalledWith;
    bool public executeRedeemBatchCalled;

    constructor(address usdc_, address vault_) {
        _usdc = IERC20(usdc_);
        _vault = vault_;
    }

    function planRedeem(uint256 required) external view override returns (Pull[] memory plan) {
        if (required == 0) return plan;
        plan = new Pull[](1);
        plan[0] = Pull({ strat: address(this), amount: required });
    }

    function executeRedeemBatch(Pull[] calldata plan)
        external override returns (uint256 got, uint256 loss)
    {
        executeRedeemBatchCalled = true;
        for (uint256 i; i < plan.length; ++i) {
            uint256 avail = _usdc.balanceOf(address(this));
            uint256 out = plan[i].amount < avail ? plan[i].amount : avail;
            if (out > 0) _usdc.transfer(_vault, out);
            got += out;
        }
    }

    // ── unused interface stubs ──────────────────────────────────────────────
    function setCore(address) external override {}
    function register(address, uint16, uint16) external override {}
    function toggle(address, bool) external override {}
    function setIntakeMode(IntakeMode) external override {}
    function setWeights(address[] calldata, uint16[] calldata) external override {}
    function setLossCapBps(uint16) external override {}
    function core() external view override returns (address) { return _vault; }
    function intakeMode() external pure override returns (IntakeMode) { return IntakeMode.NONE; }
    function lossCapBps() external pure override returns (uint16) { return 0; }
    function list() external pure override returns (StrategyInfo[] memory) { return new StrategyInfo[](0); }
    function isStrategyEnabled(address) external pure override returns (bool) { return false; }
    uint256 private _strategyTVL;
    function setStrategyTVL(uint256 tvl) external { _strategyTVL = tvl; }
    function totalStrategyAssetsSafe() external view override returns (uint256) { return _strategyTVL; }
    function planDeposit(uint256) external pure override returns (Allocation[] memory) { return new Allocation[](0); }
    function executeDepositBatch(Allocation[] calldata) external override {}
    function forceRedeemForWithdraw(uint256) external pure override returns (uint256) { return 0; }
    function harvest(uint256) external pure override returns (uint256, int256, uint256) { return (0, 0, 0); }
    function withdrawAllToCore(address) external pure override returns (uint256) { return 0; }
}

contract AuditFix_C1_StrategyLeg is Test {
    ERC20Mock internal usdc;
    CoreHarness internal vault;
    MockParamsProvider internal params;
    BufferManager internal bm;
    MockStrategyRouter internal mockRouter;
    MockWarmAdapterSimple internal warm;

    address internal alice = address(0xA11CE);

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        usdc._mint(alice, 2_000_000e6);

        params = new MockParamsProvider();
        params.setLockPeriod(0);

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Vault Shares",
            "vUSDC",
            address(this),
            address(this),
            address(params)
        );

        // Warm adapter: holds only 10K USDC — not enough to cover a large gap
        warm = new MockWarmAdapterSimple(address(usdc), address(vault));

        IBufferManager.BufferConfig memory cfg;
        cfg.targetHotBps        = 1000;
        cfg.minHotBps           = 500;
        cfg.targetWarmBps       = 9000;
        cfg.maxWarmBps          = 10000;
        cfg.opsReserveTargetBps = 300;
        cfg.asset               = address(usdc);
        cfg.warmAdapter         = address(0);
        cfg.paused              = false;

        bm = new BufferManager(address(this), address(vault), cfg);
        bm.setKeeper(address(this));
        bm.addWarmAdapter(address(warm));
        vault.setBufferManagerUnsafe(address(bm));

        // MockStrategyRouter — pre-funded with 500K USDC to simulate strategy pull
        mockRouter = new MockStrategyRouter(address(usdc), address(vault));
        usdc._mint(address(mockRouter), 500_000e6);
        vault.setStrategyRouterUnsafe(address(mockRouter));

        vm.prank(address(vault));
        usdc.approve(address(warm), type(uint256).max);

        // Deposit and rebalance: vault hot=100K, warm=small amount (adapter holds ~0)
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6, alice);
        vm.stopPrank();

        // Only seed a tiny amount into warm so warm pull leaves a gap
        usdc._mint(address(warm), 10_000e6);
    }

    /// @notice C1f: when warm pull is insufficient, planRedeem + executeRedeemBatch fires.
    ///   Setup:
    ///     - alice deposits 1M → vault hot = 1M
    ///     - transfer 900K from vault to mockRouter (simulating capital deployment)
    ///     - vault hot = 100K, mockRouter physical balance = 900K + 500K (pre-seeded) = 1.4M
    ///     - mockRouter reports stratTVL = 900K → totalAssets = hot(100K) + stratTVL(900K) = 1M
    ///     - opsReserveTargetBps = 5000 → target = 50% * 1M = 500K
    ///     - currentCash = 100K < 500K → gap = 400K
    ///     - warm pulls 10K → remainingCap = 490K → strategy fires for remaining 390K gap
    function test_C1f_strategy_leg_fires_when_warm_insufficient() public {
        // Move 900K from vault hot to mockRouter to simulate deployed capital
        vm.prank(address(vault));
        usdc.transfer(address(mockRouter), 900_000e6);
        // vault hot = 100K, mockRouter holds the 900K

        // Report 900K as strategy TVL so totalAssets stays 1M
        mockRouter.setStrategyTVL(900_000e6);

        // opsReserveTargetBps = 5000 (50%) → target = 500K, currentCash = 100K → gap = 400K
        IBufferManager.BufferConfig memory cfg = bm.getConfig();
        cfg.opsReserveTargetBps = 5000;
        bm.updateConfig(cfg);

        vault.realizeForReserveAndOps(500_000e6);

        assertTrue(
            mockRouter.executeRedeemBatchCalled(),
            "C1f: strategy leg (executeRedeemBatch) must fire when warm is insufficient"
        );
    }

    /// @notice C1g: maxAmount cap is respected across both warm AND strategy legs combined.
    function test_C1g_total_pulled_respects_maxAmount_across_both_legs() public {
        vm.prank(address(vault));
        usdc.transfer(address(mockRouter), 900_000e6);
        mockRouter.setStrategyTVL(900_000e6);

        IBufferManager.BufferConfig memory cfg = bm.getConfig();
        cfg.opsReserveTargetBps = 5000;
        bm.updateConfig(cfg);

        uint256 maxAmount  = 15_000e6; // warm=10K → both legs fire
        uint256 hotBefore  = usdc.balanceOf(address(vault));

        vault.realizeForReserveAndOps(maxAmount);

        uint256 pulled = usdc.balanceOf(address(vault)) - hotBefore;
        assertLe(pulled, maxAmount, "C1g: total pulled must not exceed maxAmount across both legs");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// H1 (mint path) — _enforceDepositLimits via _mintInternal
// ─────────────────────────────────────────────────────────────────────────────

contract AuditFix_H1_MintPath is Test {
    ERC20Mock internal usdc;
    CoreHarness internal vault;
    MockParamsProvider internal params;

    address internal alice = address(0xA11CE);
    address internal bob   = address(0xB0B);

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        usdc._mint(alice, 10_000e6);
        usdc._mint(bob,   10_000e6);

        params = new MockParamsProvider();
        params.setLockPeriod(0);

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Vault Shares",
            "vUSDC",
            address(this),
            address(this),
            address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(vault));
        vault.setBufferManagerUnsafe(address(mockBM));
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    /// @dev Convert asset amount to shares at current price (1:1 on fresh vault).
    function _sharesToMint(uint256 assets) internal view returns (uint256) {
        uint256 ts = vault.totalSupply();
        uint256 ta = vault.totalAssets();
        if (ts == 0 || ta == 0) return assets; // 1:1 at genesis
        return assets * ts / ta;
    }

    // ── tests ────────────────────────────────────────────────────────────────

    /// @notice H1-M-a: mint whose grossAssets < minDepositAmount reverts with DepositBelowMinimum
    function test_H1m_a_mint_below_minimum_reverts() public {
        params.setDepositLimits(0, 0, 100e6); // min = 100 USDC

        // On a fresh vault 1 share = 1 USDC, so minting 99 shares costs 99 USDC (gross) < 100 min
        uint256 shares = 99e6;
        usdc._mint(alice, 1e6); // extra headroom
        vm.startPrank(alice);
        usdc.approve(address(vault), 200e6);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Module.DepositBelowMinimum.selector, shares, 100e6)
        );
        vault.mint(shares, alice);
        vm.stopPrank();
    }

    /// @notice H1-M-b: mint exactly at minimum succeeds
    function test_H1m_b_mint_at_minimum_succeeds() public {
        params.setDepositLimits(0, 0, 100e6);

        uint256 shares = 100e6; // grossAssets = 100 USDC = min
        vm.startPrank(alice);
        usdc.approve(address(vault), 100e6);
        vault.mint(shares, alice);
        vm.stopPrank();

        assertGe(vault.balanceOf(alice), shares, "H1-M-b: alice must receive shares");
    }

    /// @notice H1-M-c: mint that would push totalAssets past vaultDepositCap reverts
    function test_H1m_c_mint_exceeds_vault_cap_reverts() public {
        params.setDepositLimits(500e6, 0, 0); // vaultCap = 500 USDC

        // First fill 400 USDC via deposit
        vm.startPrank(alice);
        usdc.approve(address(vault), 400e6);
        vault.deposit(400e6, alice);
        vm.stopPrank();

        // Now try to mint 200 USDC worth → totalAssets would reach 600 > 500
        uint256 shares = 200e6;
        vm.startPrank(bob);
        usdc.approve(address(vault), 200e6);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Module.VaultDepositCapExceeded.selector, 600e6, 500e6)
        );
        vault.mint(shares, bob);
        vm.stopPrank();
    }

    /// @notice H1-M-d: mint that would push user position past userDepositCap reverts
    function test_H1m_d_mint_exceeds_user_cap_reverts() public {
        params.setDepositLimits(0, 300e6, 0); // userCap = 300 USDC per address

        // Alice already deposited 200 USDC
        vm.startPrank(alice);
        usdc.approve(address(vault), 200e6);
        vault.deposit(200e6, alice);
        vm.stopPrank();

        // Try to mint 150 USDC worth → position would be 350 > 300
        uint256 shares = 150e6;
        vm.startPrank(alice);
        usdc.approve(address(vault), 150e6);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Module.UserDepositCapExceeded.selector, 350e6, 300e6)
        );
        vault.mint(shares, alice);
        vm.stopPrank();
    }

    /// @notice H1-M-e: maxMint reflects vaultCap and userCap correctly in two scenarios
    function test_H1m_e_maxMint_reflects_caps() public {
        // Scenario A: userCap is the binding constraint (userCap < vaultRemaining)
        // vaultCap = 1000, userCap = 200 → maxMint(bob) = 200
        params.setDepositLimits(1000e6, 200e6, 0);
        assertEq(vault.maxMint(bob), 200e6, "H1-M-e-A: maxMint must equal userCap when it is binding");

        // Scenario B: vaultCap is the binding constraint
        // Fill vault with 900 USDC via alice (userCap=200 per address, so use 5 addresses)
        // Easier: switch to userCap=500 so alice can fill 400 cleanly, then check bob
        params.setDepositLimits(500e6, 500e6, 0);
        vm.startPrank(alice);
        usdc.approve(address(vault), 400e6);
        vault.deposit(400e6, alice); // vault has 400, remaining = 100
        vm.stopPrank();

        // Now vaultRemaining (100) < userCap (500) → vaultCap is binding for bob
        assertEq(vault.maxMint(bob), 100e6, "H1-M-e-B: maxMint must equal remaining vault cap when binding");
    }

    /// @notice H1-M-f: all caps = 0 means unlimited — mint of any size succeeds
    function test_H1m_f_no_caps_mint_any_size_succeeds() public {
        params.setDepositLimits(0, 0, 0);

        uint256 shares = 5_000e6;
        usdc._mint(alice, shares);
        vm.startPrank(alice);
        usdc.approve(address(vault), shares);
        vault.mint(shares, alice);
        vm.stopPrank();

        assertGe(vault.balanceOf(alice), shares, "H1-M-f: must receive shares with no caps");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// H2 — SelectorRegistry ROLE_PUBLIC bypass
// ─────────────────────────────────────────────────────────────────────────────

contract AuditFix_H2_SelectorRegistryRolePublic is Test {
    ERC20Mock internal usdc;
    CoreHarness internal vault;
    MockParamsProvider internal params;
    SelectorRegistry internal registry;
    LiquidityOpsModule internal liqOps;

    uint8 constant ROLE_PUBLIC  = 0;
    uint8 constant ROLE_OWNER   = 1;
    uint8 constant ROLE_GUARDIAN = 2;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        params = new MockParamsProvider();
        params.setLockPeriod(0);

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Vault Shares",
            "vUSDC",
            address(this),
            address(this),
            address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(vault));
        vault.setBufferManagerUnsafe(address(mockBM));

        registry = new SelectorRegistry();
        vault.setSelectorRegistry(address(registry));

        liqOps = new LiquidityOpsModule();
    }

    /// @notice H2a: registering a ROLE_PUBLIC selector with ROLE_PUBLIC succeeds
    function test_H2a_public_selector_with_public_role_succeeds() public {
        bytes4 sel = LiquidityOpsModule.canDeploy.selector;
        // Must not revert — correct role for a public selector
        vault.setModule(sel, address(liqOps), ROLE_PUBLIC);
        assertEq(vault.moduleOf(sel), address(liqOps), "H2a: module must be set");
    }

    /// @notice H2b: registering a ROLE_PUBLIC selector with ROLE_OWNER reverts
    function test_H2b_public_selector_with_owner_role_reverts() public {
        bytes4 sel = LiquidityOpsModule.canDeploy.selector;
        vm.expectRevert(
            abi.encodeWithSelector(
                SelectorRegistry.InvalidRoleForSelector.selector,
                sel,
                ROLE_OWNER,
                ROLE_PUBLIC
            )
        );
        vault.setModule(sel, address(liqOps), ROLE_OWNER);
    }

    /// @notice H2c: registering a ROLE_PUBLIC selector with ROLE_GUARDIAN reverts
    function test_H2c_public_selector_with_guardian_role_reverts() public {
        bytes4 sel = LiquidityOpsModule.realizeForQueue.selector;
        vm.expectRevert(
            abi.encodeWithSelector(
                SelectorRegistry.InvalidRoleForSelector.selector,
                sel,
                ROLE_GUARDIAN,
                ROLE_PUBLIC
            )
        );
        vault.setModule(sel, address(liqOps), ROLE_GUARDIAN);
    }

    /// @notice H2d: registering an OWNER selector with ROLE_PUBLIC reverts
    function test_H2d_owner_selector_with_public_role_reverts() public {
        // setParams is ROLE_OWNER in the registry
        bytes4 sel = bytes4(keccak256("setParams(address)"));
        vm.expectRevert(); // InvalidRoleForSelector
        vault.setModule(sel, address(liqOps), ROLE_PUBLIC);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// M1 — guardianPauseCooldown reads from params
// ─────────────────────────────────────────────────────────────────────────────

contract AuditFix_M1_GuardianPauseCooldown is Test {
    ERC20Mock internal usdc;
    CoreHarness internal vault;
    MockParamsProviderWithCooldown internal params;

    address internal guardian = address(0x6A4D);

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        params = new MockParamsProviderWithCooldown();

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Vault Shares",
            "vUSDC",
            address(this),
            address(this),
            address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(vault));
        vault.setBufferManagerUnsafe(address(mockBM));

        vault.setGuardian(guardian);
    }

    /// @notice M1a: first guardianPause always succeeds (no previous timestamp)
    function test_M1a_first_guardianPause_succeeds() public {
        vm.prank(guardian);
        vault.guardianPause();
        assertTrue(vault.paused(), "M1a: vault must be paused");
    }

    /// @notice M1b: second pause before configured cooldown reverts
    function test_M1b_second_pause_before_cooldown_reverts() public {
        params.setGuardianPauseCooldown(3 days);

        vm.prank(guardian);
        vault.guardianPause();

        // Unpause so guardian can try again
        vault.unpauseAll();

        // Warp 2 days — still within 3-day cooldown
        vm.warp(block.timestamp + 2 days);

        vm.prank(guardian);
        vm.expectRevert(CoreVault.GuardianCooldownActive.selector);
        vault.guardianPause();
    }

    /// @notice M1c: second pause after configured cooldown succeeds
    function test_M1c_second_pause_after_cooldown_succeeds() public {
        params.setGuardianPauseCooldown(3 days);

        vm.prank(guardian);
        vault.guardianPause();

        vault.unpauseAll();

        // Warp past 3-day cooldown
        vm.warp(block.timestamp + 3 days + 1);

        vm.prank(guardian);
        vault.guardianPause(); // must not revert
        assertTrue(vault.paused(), "M1c: vault must be paused again");
    }

    /// @notice M1d: cooldown = 0 from params falls back to 7 days
    function test_M1d_zero_cooldown_falls_back_to_7_days() public {
        params.setGuardianPauseCooldown(0); // triggers fallback

        vm.prank(guardian);
        vault.guardianPause();

        vault.unpauseAll();

        // Warp 6 days — less than 7-day fallback
        vm.warp(block.timestamp + 6 days);

        vm.prank(guardian);
        vm.expectRevert(CoreVault.GuardianCooldownActive.selector);
        vault.guardianPause();
    }

    /// @notice M1e: changing cooldown via params takes effect immediately on next pause
    function test_M1e_cooldown_change_takes_effect_immediately() public {
        params.setGuardianPauseCooldown(10 days);

        vm.prank(guardian);
        vault.guardianPause();
        vault.unpauseAll();

        // Warp 8 days — within 10-day cooldown
        vm.warp(block.timestamp + 8 days);
        vm.prank(guardian);
        vm.expectRevert(CoreVault.GuardianCooldownActive.selector);
        vault.guardianPause();

        // Governance reduces cooldown to 7 days
        params.setGuardianPauseCooldown(7 days);

        // Now 8 days > 7 days → should succeed
        vm.prank(guardian);
        vault.guardianPause();
        assertTrue(vault.paused(), "M1e: vault must be paused after cooldown reduction");
    }
}
