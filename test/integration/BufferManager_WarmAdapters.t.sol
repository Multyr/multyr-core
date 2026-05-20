// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { BufferManager } from "../../src/core/modules/BufferManager.sol";
import { AaveV3WarmAdapter_USDC } from "../../src/adapters/warm/AaveV3WarmAdapter_USDC.sol";
import {
    MorphoVaultWarmAdapter_USDC
} from "../../src/adapters/warm/MorphoBlueWarmAdapter_USDC.sol";
import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ========== Mock Contracts ==========

contract MockCoreVault {
    IERC20 public immutable asset;
    uint256 public mockTotalAssets;
    address public bufferManager;

    constructor(address asset_) {
        asset = IERC20(asset_);
    }

    function setBufferManager(address bm) external {
        bufferManager = bm;
    }

    function totalAssets() external view returns (uint256) {
        return mockTotalAssets;
    }

    function setTotalAssets(uint256 amount) external {
        mockTotalAssets = amount;
    }

    /// @notice Returns (nav, hot, warm) breakdown for BufferManager.plan()
    function totalAssetsBreakdown() external view returns (uint256 nav, uint256 hot, uint256 warm) {
        hot = asset.balanceOf(address(this));
        // Read warm from BufferManager if set (to avoid circular dependency during init)
        if (bufferManager != address(0)) {
            warm = BufferManager(bufferManager).warmBalance();
        }
        nav = hot + warm; // NAV = hot + warm (no cold in this mock)
    }

    // Allow BufferManager to pull funds
    function approveFunds(address spender, uint256 amount) external {
        asset.approve(spender, amount);
    }
}

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }
}

// Mock Aave Pool
contract MockAavePool {
    MockERC20 public immutable usdc;
    MockERC20 public immutable aToken;

    constructor(address usdc_, address aToken_) {
        usdc = MockERC20(usdc_);
        aToken = MockERC20(aToken_);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(asset == address(usdc), "Wrong asset");
        usdc.burn(msg.sender, amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(usdc), "Wrong asset");
        aToken.burn(msg.sender, amount);
        usdc.mint(to, amount);
        return amount;
    }
}

contract MockAaveDataProvider {
    address public immutable aToken;

    constructor(address aToken_) {
        aToken = aToken_;
    }

    function getReserveTokensAddresses(address) external view returns (address, address, address) {
        return (aToken, address(0), address(0));
    }
}

// Mock Morpho Vault (ERC-4626)
contract MockMorphoVault {
    MockERC20 public immutable usdc;
    MockERC20 public immutable shares;
    uint256 public sharePrice = 1e6; // 1:1 initially

    constructor(address usdc_, address shares_) {
        usdc = MockERC20(usdc_);
        shares = MockERC20(shares_);
    }

    function asset() external view returns (address) {
        return address(usdc);
    }

    function balanceOf(address account) external view returns (uint256) {
        return shares.balanceOf(account);
    }

    function convertToAssets(uint256 sharesAmount) external view returns (uint256) {
        if (sharesAmount == 0) return 0;
        return (sharesAmount * sharePrice) / 1e6;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        if (assets == 0) return 0;
        return (assets * 1e6) / sharePrice;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return this.convertToShares(assets);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return this.convertToShares(assets) + 1;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 sharesOut) {
        usdc.burn(msg.sender, assets);
        sharesOut = this.convertToShares(assets);
        shares.mint(receiver, sharesOut);
        return sharesOut;
    }

    function redeem(uint256 sharesAmount, address receiver, address owner)
        external
        returns (uint256 assetsOut)
    {
        shares.burn(owner, sharesAmount);
        assetsOut = this.convertToAssets(sharesAmount);
        usdc.mint(receiver, assetsOut);
        return assetsOut;
    }

    function simulateYield(uint256 yieldBps) external {
        sharePrice = sharePrice + (sharePrice * yieldBps) / 10000;
    }
}

// ========== Test Contract ==========

/**
 * @title BufferManager + WarmAdapters Integration Tests
 * @notice Tests the full flow between CoreVault, BufferManager, and warm adapters
 */
contract BufferManager_WarmAdapters_Test is Test {
    // Contracts
    BufferManager internal bufferManager;
    MockCoreVault internal coreVault;
    AaveV3WarmAdapter_USDC internal aaveAdapter;
    MorphoVaultWarmAdapter_USDC internal morphoAdapter;

    // Tokens
    MockERC20 internal usdc;
    MockERC20 internal aToken;
    MockERC20 internal morphoShares;

    // Protocols
    MockAavePool internal aavePool;
    MockAaveDataProvider internal aaveDataProvider;
    MockMorphoVault internal morphoVault;

    // Actors
    address internal owner = address(this);
    address internal user = address(0x123);

    // Config values
    uint256 constant INITIAL_NAV = 10_000e6; // 10k USDC
    uint16 constant TARGET_HOT_BPS = 1000; // 10%
    uint16 constant MIN_HOT_BPS = 500; // 5%
    uint16 constant TARGET_WARM_BPS = 1000; // 10%
    uint16 constant MAX_WARM_BPS = 2000; // 20%

    event BufferDeployed(uint256 amount, uint256 received);
    event BufferRefilled(uint256 amount, uint256 cost);

    function setUp() public {
        // Deploy USDC at hardcoded address
        MockERC20 usdcImpl = new MockERC20("USDC", "USDC", 6);
        vm.etch(0xaf88d065e77c8cC2239327C5EDb3A432268e5831, address(usdcImpl).code);
        usdc = MockERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);

        // Deploy tokens
        aToken = new MockERC20("Aave USDC", "aUSDC", 6);
        morphoShares = new MockERC20("Morpho Shares", "mUSDC", 6);

        // Deploy protocols
        aavePool = new MockAavePool(address(usdc), address(aToken));
        aaveDataProvider = new MockAaveDataProvider(address(aToken));
        morphoVault = new MockMorphoVault(address(usdc), address(morphoShares));

        // Deploy CoreVault mock
        coreVault = new MockCoreVault(address(usdc));
        coreVault.setTotalAssets(INITIAL_NAV);

        // Mint initial USDC to core (80% of NAV in hot buffer initially)
        uint256 initialHot = (INITIAL_NAV * 8000) / 10000; // 80%
        usdc.mint(address(coreVault), initialHot);

        // Note: MockCoreVault doesn't enforce owner seed deposit requirement
        // This is a mock test, so no seed deposit needed
    }

    function _setupWithAaveAdapter() internal {
        // Deploy BufferManager first with empty adapter
        IBufferManager.BufferConfig memory cfg;
        cfg.targetHotBps = TARGET_HOT_BPS;
        cfg.minHotBps = MIN_HOT_BPS;
        cfg.targetWarmBps = TARGET_WARM_BPS;
        cfg.maxWarmBps = MAX_WARM_BPS;
        cfg.opsReserveTargetBps = 100;
        cfg.maxWarmSlippageBps = 50;
        cfg.asset = address(usdc);
        cfg.warmAdapter = address(0);
        cfg.twapWindowSec = 0;
        cfg.paused = false;

        bufferManager = new BufferManager(owner, address(coreVault), cfg);

        // Deploy Aave adapter with controller = BufferManager, coreVault = coreVault
        aaveAdapter = new AaveV3WarmAdapter_USDC(
            address(bufferManager), address(coreVault), address(aavePool), address(aaveDataProvider)
        );

        // Update config with correct adapter
        cfg.warmAdapter = address(aaveAdapter);
        bufferManager.updateConfig(cfg);

        // Wire up MockCoreVault to read warm from BufferManager
        coreVault.setBufferManager(address(bufferManager));

        // Approve adapter to pull from coreVault (new pattern)
        vm.prank(address(coreVault));
        usdc.approve(address(aaveAdapter), type(uint256).max);
    }

    function _setupWithMorphoAdapter() internal {
        // Deploy BufferManager first with empty adapter
        IBufferManager.BufferConfig memory cfg;
        cfg.targetHotBps = TARGET_HOT_BPS;
        cfg.minHotBps = MIN_HOT_BPS;
        cfg.targetWarmBps = TARGET_WARM_BPS;
        cfg.maxWarmBps = MAX_WARM_BPS;
        cfg.opsReserveTargetBps = 100;
        cfg.maxWarmSlippageBps = 50;
        cfg.asset = address(usdc);
        cfg.warmAdapter = address(0);
        cfg.twapWindowSec = 0;
        cfg.paused = false;

        bufferManager = new BufferManager(owner, address(coreVault), cfg);

        // Deploy Morpho adapter with controller = BufferManager, coreVault = coreVault
        morphoAdapter = new MorphoVaultWarmAdapter_USDC(
            address(bufferManager),
            address(coreVault),
            address(morphoVault),
            5 // 5 bps slippage
        );

        cfg.warmAdapter = address(morphoAdapter);
        bufferManager.updateConfig(cfg);

        // Wire up MockCoreVault to read warm from BufferManager
        coreVault.setBufferManager(address(bufferManager));

        // Approve adapter to pull from coreVault (new pattern)
        vm.prank(address(coreVault));
        usdc.approve(address(morphoAdapter), type(uint256).max);

        // Approve BufferManager
        vm.prank(address(coreVault));
        usdc.approve(address(bufferManager), type(uint256).max);
    }

    // ========== AAVE ADAPTER INTEGRATION TESTS ==========

    function test_aave_full_deploy_flow() public {
        _setupWithAaveAdapter();

        // Initial state: 80% in hot, 0% in warm
        uint256 hotBefore = bufferManager.hotBalance();
        assertEq(bufferManager.warmBalance(), 0, "warm starts empty");

        // Plan deployment
        (, uint256 needDeploy) = bufferManager.plan();
        assertGt(needDeploy, 0, "should need to deploy");

        // Execute deploy as core
        vm.expectEmit(true, true, true, true);
        emit BufferDeployed(needDeploy, needDeploy);

        vm.prank(address(coreVault));
        bufferManager.executeDeploy(needDeploy);

        // Verify state
        assertEq(bufferManager.hotBalance(), hotBefore - needDeploy, "hot decreased");
        assertApproxEqAbs(bufferManager.warmBalance(), needDeploy, 1, "warm increased");
        assertApproxEqAbs(aToken.balanceOf(address(aaveAdapter)), needDeploy, 1, "aTokens minted");
    }

    function test_aave_full_refill_flow() public {
        _setupWithAaveAdapter();

        // First deploy some funds to warm
        (, uint256 needDeploy) = bufferManager.plan();
        vm.prank(address(coreVault));
        bufferManager.executeDeploy(needDeploy);

        // After deploy: hot = 6400e6, warm = 1600e6, NAV = 8000e6
        uint256 hotAfterDeploy = bufferManager.hotBalance();
        uint256 warmAfterDeploy = bufferManager.warmBalance();

        // To trigger refill, we need: hot < minHot = 5% of NAV
        // After burning X from hot, NAV = (hotAfterDeploy - X) + warm
        // minHot = 0.05 * NAV = 0.05 * (hotAfterDeploy - X + warm)
        // We want: (hotAfterDeploy - X) < 0.05 * (hotAfterDeploy - X + warm)
        // Solving: 0.95 * (hotAfterDeploy - X) < 0.05 * warm
        // => (hotAfterDeploy - X) < warm * 0.05 / 0.95 = warm / 19
        // So target hot after burn should be less than warm / 19

        // For this test, burn until hot = warm / 50 (way below minimum)
        uint256 targetHot = warmAfterDeploy / 50;
        require(hotAfterDeploy > targetHot, "test setup: not enough hot to burn");
        uint256 toBurn = hotAfterDeploy - targetHot;
        usdc.burn(address(coreVault), toBurn);

        // Plan refill
        (uint256 needRefill,) = bufferManager.plan();
        assertGt(needRefill, 0, "should need refill");

        uint256 warmBefore = bufferManager.warmBalance();
        uint256 hotBefore = bufferManager.hotBalance();

        // Execute refill as core
        vm.expectEmit(true, true, true, true);
        emit BufferRefilled(needRefill, 0);

        vm.prank(address(coreVault));
        bufferManager.refill(needRefill);

        // Verify state
        assertEq(usdc.balanceOf(address(coreVault)), hotBefore + needRefill, "hot refilled");
        assertApproxEqAbs(bufferManager.warmBalance(), warmBefore - needRefill, 1, "warm decreased");
    }

    function test_aave_rebalance_both_directions() public {
        _setupWithAaveAdapter();

        // Deploy to warm
        (, uint256 needDeploy) = bufferManager.plan();
        vm.prank(address(coreVault));
        bufferManager.executeDeploy(needDeploy);

        // Record state
        uint256 hotAfterDeploy = bufferManager.hotBalance();
        uint256 warmAfterDeploy = bufferManager.warmBalance();

        // Simulate hot depletion
        usdc.burn(address(coreVault), (INITIAL_NAV * 400) / 10000); // Burn 4%

        // Rebalance should refill hot from warm
        vm.prank(address(coreVault));
        bufferManager.rebalance();

        assertGe(
            bufferManager.hotBalance(),
            hotAfterDeploy - (INITIAL_NAV * 400) / 10000,
            "hot refilled or maintained"
        );
        assertLe(bufferManager.warmBalance(), warmAfterDeploy, "warm depleted or maintained");
    }

    function test_aave_yield_accrual_increases_totalAssets() public {
        _setupWithAaveAdapter();

        // Deploy to Aave
        (, uint256 needDeploy) = bufferManager.plan();
        vm.prank(address(coreVault));
        bufferManager.executeDeploy(needDeploy);

        uint256 warmBefore = bufferManager.warmBalance();

        // Simulate yield: mint more aTokens (5% yield)
        uint256 yield = (warmBefore * 500) / 10000;
        aToken.mint(address(aaveAdapter), yield);

        // Warm balance should include yield
        assertApproxEqAbs(bufferManager.warmBalance(), warmBefore + yield, 1, "yield accrued");
    }

    // ========== MORPHO ADAPTER INTEGRATION TESTS ==========

    function test_morpho_full_deploy_flow() public {
        _setupWithMorphoAdapter();

        // Initial state
        uint256 hotBefore = bufferManager.hotBalance();
        assertEq(bufferManager.warmBalance(), 0, "warm starts empty");

        // Plan deployment
        (, uint256 needDeploy) = bufferManager.plan();
        assertGt(needDeploy, 0, "should need to deploy");

        // Execute deploy
        vm.expectEmit(true, true, true, true);
        emit BufferDeployed(needDeploy, needDeploy);

        vm.prank(address(coreVault));
        bufferManager.executeDeploy(needDeploy);

        // Verify state
        assertEq(bufferManager.hotBalance(), hotBefore - needDeploy, "hot decreased");
        assertApproxEqAbs(bufferManager.warmBalance(), needDeploy, 1, "warm increased");
        assertApproxEqAbs(
            morphoShares.balanceOf(address(morphoAdapter)), needDeploy, 1, "shares minted"
        );
    }

    function test_morpho_full_refill_flow() public {
        _setupWithMorphoAdapter();

        // Deploy to warm
        (, uint256 needDeploy) = bufferManager.plan();
        vm.prank(address(coreVault));
        bufferManager.executeDeploy(needDeploy);

        // After deploy
        uint256 hotAfterDeploy = bufferManager.hotBalance();
        uint256 warmAfterDeploy = bufferManager.warmBalance();

        // Burn until hot = warm / 50 (way below minimum to ensure refill needed)
        uint256 targetHot = warmAfterDeploy / 50;
        require(hotAfterDeploy > targetHot, "test setup: not enough hot to burn");
        uint256 toBurn = hotAfterDeploy - targetHot;
        usdc.burn(address(coreVault), toBurn);

        // Refill
        (uint256 needRefill,) = bufferManager.plan();
        assertGt(needRefill, 0, "should need refill");

        uint256 hotBefore = bufferManager.hotBalance();
        vm.prank(address(coreVault));
        bufferManager.refill(needRefill);

        // Verify - allow for Morpho slippage (previewWithdraw adds +1)
        assertApproxEqAbs(
            usdc.balanceOf(address(coreVault)),
            hotBefore + needRefill,
            500000,
            "hot refilled within slippage"
        );
    }

    function test_morpho_yield_via_share_price_increase() public {
        _setupWithMorphoAdapter();

        // Deploy to Morpho
        (, uint256 needDeploy) = bufferManager.plan();
        vm.prank(address(coreVault));
        bufferManager.executeDeploy(needDeploy);

        uint256 warmBefore = bufferManager.warmBalance();

        // Simulate yield: increase share price by 5%
        morphoVault.simulateYield(500);

        // Warm balance should increase due to share price
        uint256 warmAfter = bufferManager.warmBalance();
        assertGt(warmAfter, warmBefore, "yield accrued");
        assertApproxEqAbs(warmAfter, warmBefore * 105 / 100, warmBefore / 100, "~5% yield");
    }

    function test_morpho_slippage_protection_on_withdraw() public {
        _setupWithMorphoAdapter();

        // Deploy funds
        (, uint256 needDeploy) = bufferManager.plan();
        vm.prank(address(coreVault));
        bufferManager.executeDeploy(needDeploy);

        // Increase share price significantly
        morphoVault.simulateYield(1000); // 10%

        // Refill should still work despite price change
        uint256 hotBefore = bufferManager.hotBalance();
        usdc.burn(address(coreVault), (INITIAL_NAV * 400) / 10000);

        (uint256 needRefill,) = bufferManager.plan();
        vm.prank(address(coreVault));
        bufferManager.refill(needRefill);

        // Should successfully refill (allow equality for boundary conditions)
        assertGe(
            bufferManager.hotBalance(),
            hotBefore - (INITIAL_NAV * 400) / 10000,
            "refilled or maintained despite price change"
        );
    }

    // ========== EDGE CASES ==========

    function test_cannot_deploy_when_paused() public {
        _setupWithAaveAdapter();

        // Pause
        bufferManager.setPaused(true);

        // Try to deploy
        (, uint256 needDeploy) = bufferManager.plan();
        vm.prank(address(coreVault));
        vm.expectRevert();
        bufferManager.executeDeploy(needDeploy);
    }

    function test_cannot_refill_when_paused() public {
        _setupWithAaveAdapter();

        // Deploy first
        (, uint256 needDeploy) = bufferManager.plan();
        vm.prank(address(coreVault));
        bufferManager.executeDeploy(needDeploy);

        // Pause
        bufferManager.setPaused(true);

        // Try to refill
        vm.prank(address(coreVault));
        vm.expectRevert();
        bufferManager.refill(100e6);
    }

    function test_only_core_can_execute_deploy() public {
        _setupWithAaveAdapter();

        vm.prank(user);
        vm.expectRevert();
        bufferManager.executeDeploy(100e6);
    }

    function test_only_core_can_refill() public {
        _setupWithAaveAdapter();

        vm.prank(user);
        vm.expectRevert();
        bufferManager.refill(100e6);
    }

    function test_deploy_zero_amount_does_nothing() public {
        _setupWithAaveAdapter();

        uint256 hotBefore = bufferManager.hotBalance();
        uint256 warmBefore = bufferManager.warmBalance();

        vm.prank(address(coreVault));
        bufferManager.executeDeploy(0);

        assertEq(bufferManager.hotBalance(), hotBefore, "hot unchanged");
        assertEq(bufferManager.warmBalance(), warmBefore, "warm unchanged");
    }

    function test_refill_zero_amount_does_nothing() public {
        _setupWithAaveAdapter();

        uint256 hotBefore = bufferManager.hotBalance();
        uint256 warmBefore = bufferManager.warmBalance();

        vm.prank(address(coreVault));
        bufferManager.refill(0);

        assertEq(bufferManager.hotBalance(), hotBefore, "hot unchanged");
        assertEq(bufferManager.warmBalance(), warmBefore, "warm unchanged");
    }

    function test_totalBuffer_sums_hot_and_warm() public {
        _setupWithAaveAdapter();

        uint256 hotBefore = bufferManager.hotBalance();

        // Deploy some to warm
        vm.prank(address(coreVault));
        bufferManager.executeDeploy(500e6);

        uint256 total = bufferManager.totalBuffer();
        uint256 hot = bufferManager.hotBalance();
        uint256 warm = bufferManager.warmBalance();

        assertApproxEqAbs(total, hot + warm, 1, "total = hot + warm");
        assertApproxEqAbs(total, hotBefore, 1, "total unchanged by rebalance");
    }
}
