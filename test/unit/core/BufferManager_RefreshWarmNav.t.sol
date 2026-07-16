// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockUSDC } from "../../helpers/MockUSDC.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockAToken } from "../../helpers/MockAToken.sol";
import { MockAavePool, MockAaveDataProvider } from "../../helpers/MockAave.sol";
import { AaveV3WarmAdapter_USDC } from "../../../src/adapters/warm/AaveV3WarmAdapter_USDC.sol";
import { BufferManager } from "../../../src/core/modules/BufferManager.sol";
import { IBufferManager } from "../../../src/interfaces/IBufferManager.sol";
import { IWarmAdapter } from "../../../src/interfaces/IWarmAdapter.sol";

contract BufferManager_RefreshWarmNav_Test is Test {
    address constant USDC_UNDERLYING = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    CoreHarness vault;
    BufferManager bm;
    AaveV3WarmAdapter_USDC warm;

    MockUSDC mock;
    MockParamsProvider params;
    MockAToken aToken;
    MockAavePool pool;
    MockAaveDataProvider data;

    address treasury = address(0xFEE);

    function setUp() public {
        // Deploy MockUSDC and etch code to the adapter's UNDERLYING address
        mock = new MockUSDC();
        vm.etch(USDC_UNDERLYING, address(mock).code);

        // Mock aToken + pool + dataProvider
        aToken = new MockAToken();
        pool = new MockAavePool(USDC_UNDERLYING, address(aToken));
        data = new MockAaveDataProvider(address(aToken));

        // Deploy params provider
        params = new MockParamsProvider();

        // Core vault with USDC asset
        vault = new CoreHarness(
            IERC20Metadata(USDC_UNDERLYING),
            "Vault",
            "vUSDC",
            address(this),
            treasury,
            address(params)
        );

        // Init BufferManager without warm adapter, then set
        IBufferManager.BufferConfig memory cfg;
        cfg.targetHotBps = 1000; // 10%
        cfg.minHotBps = 800; // 8%
        cfg.targetWarmBps = 9000;
        cfg.maxWarmBps = 10000;
        cfg.asset = USDC_UNDERLYING;
        cfg.warmAdapter = address(0);
        cfg.twapWindowSec = 0;
        cfg.paused = false;
        bm = new BufferManager(address(this), address(vault), cfg);

        // Warm adapter controlled by BufferManager, pulls from vault
        warm = new AaveV3WarmAdapter_USDC(address(bm), address(vault), address(pool), address(data));

        // Complete config and wire into core
        cfg.warmAdapter = address(warm);
        bm.updateConfig(cfg);
        vault.setBufferManagerUnsafe(address(bm));

        // Approve adapter to pull from vault (new pull pattern)
        vm.prank(address(vault));
        MockUSDC(USDC_UNDERLYING).approve(address(warm), type(uint256).max);
    }

    function _mintTo(address to, uint256 amt) internal {
        MockUSDC(USDC_UNDERLYING).mint(to, amt);
    }

    /// @dev Setup: fund vault, approve BM, rebalance to deploy warm
    function _fundAndRebalance(uint256 amount) internal {
        _mintTo(address(vault), amount);
        vm.prank(address(vault));
        MockUSDC(USDC_UNDERLYING).approve(address(bm), type(uint256).max);
        bm.setKeeper(address(this));
        bm.rebalance();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 5a-1: refreshWarmNav updates cache when valid
    // ═══════════════════════════════════════════════════════════════════════

    function test_refreshWarmNav_updates_cache_when_valid() public {
        _fundAndRebalance(1_000_000e6);

        // Warp forward so timestamp changes
        vm.warp(block.timestamp + 5 minutes);

        // Call refreshWarmNav
        bm.refreshWarmNav();

        (uint256 nav, uint40 ts, bool valid) = bm.warmNavState();

        assertTrue(valid, "warmNavValid should be true");
        assertEq(ts, uint40(block.timestamp), "timestamp should be current block.timestamp");
        assertGt(nav, 0, "cached warm NAV should be > 0 after deploy");

        // Nav should match the actual warm balance
        uint256 actualWarm = bm.warmBalance();
        assertEq(nav, actualWarm, "cached NAV must equal actual warmBalance");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 5a-2: refreshWarmNav is permissionless
    // ═══════════════════════════════════════════════════════════════════════

    function test_refreshWarmNav_permissionless() public {
        _fundAndRebalance(1_000_000e6);

        // Call from a random EOA that is NOT keeper, NOT owner, NOT core
        address randomEOA = address(0xCAFE);
        vm.prank(randomEOA);
        bm.refreshWarmNav(); // must not revert

        (,, bool valid) = bm.warmNavState();
        assertTrue(valid, "cache should be valid after permissionless refresh");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 5a-3: refreshWarmNav does not move funds
    // ═══════════════════════════════════════════════════════════════════════

    function test_refreshWarmNav_does_not_move_funds() public {
        _fundAndRebalance(1_000_000e6);

        // Snapshot balances before
        uint256 vaultBefore = IERC20(USDC_UNDERLYING).balanceOf(address(vault));
        uint256 warmBefore = aToken.balanceOf(address(warm));
        uint256 bmBefore = IERC20(USDC_UNDERLYING).balanceOf(address(bm));

        // Call refreshWarmNav
        bm.refreshWarmNav();

        // Verify no balances changed
        uint256 vaultAfter = IERC20(USDC_UNDERLYING).balanceOf(address(vault));
        uint256 warmAfter = aToken.balanceOf(address(warm));
        uint256 bmAfter = IERC20(USDC_UNDERLYING).balanceOf(address(bm));

        assertEq(vaultAfter, vaultBefore, "vault balance must not change");
        assertEq(warmAfter, warmBefore, "warm adapter balance must not change");
        assertEq(bmAfter, bmBefore, "BM balance must not change (should be 0)");
        assertEq(bmAfter, 0, "BM must never hold idle assets");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 5a-4: refreshWarmNav when adapter fails keeps invalid state
    // ═══════════════════════════════════════════════════════════════════════

    function test_refreshWarmNav_when_adapter_fails_keeps_invalid_state() public {
        // Create a controllable failing adapter
        FailingWarmAdapter failingAdapter = new FailingWarmAdapter();

        IBufferManager.BufferConfig memory cfg;
        cfg.targetHotBps = 10000; // 100% hot
        cfg.minHotBps = 10000;
        cfg.asset = USDC_UNDERLYING;
        cfg.warmAdapter = address(failingAdapter);
        cfg.paused = false;

        BufferManager bmFailing = new BufferManager(address(this), address(vault), cfg);

        // Adapter starts working - do initial refresh to get valid state
        failingAdapter.setShouldFail(false);
        bmFailing.refreshWarmNav();
        (,, bool valid1) = bmFailing.warmNavState();
        assertTrue(valid1, "should be valid when adapter works");

        // Now make adapter fail
        failingAdapter.setShouldFail(true);
        bmFailing.refreshWarmNav();

        (,, bool valid2) = bmFailing.warmNavState();
        assertFalse(valid2, "warmNavValid must be false when adapter reverts");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 5g-1: refreshWarmNav emits WarmNavCacheUpdated
    // ═══════════════════════════════════════════════════════════════════════

    function test_refreshWarmNav_emits_WarmNavCacheUpdated() public {
        _fundAndRebalance(1_000_000e6);

        // Warp forward
        vm.warp(block.timestamp + 5 minutes);

        uint256 expectedNav = bm.warmBalance();

        vm.expectEmit(true, true, true, true);
        emit BufferManager.WarmNavCacheUpdated(expectedNav, uint40(block.timestamp), true);

        bm.refreshWarmNav();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 5g-2: refreshWarmNav updates views consistently without fund movement
    // ═══════════════════════════════════════════════════════════════════════

    function test_refreshWarmNav_updates_views_consistently_without_fund_movement() public {
        // Deposit through the vault so shares exist (need supply > 0 for convertToShares)
        uint256 seedAmount = 1_000_000e6;
        _mintTo(address(this), seedAmount);
        MockUSDC(USDC_UNDERLYING).approve(address(vault), seedAmount);
        vault.deposit(seedAmount, address(this));

        // Rebalance to deploy to warm
        vm.prank(address(vault));
        MockUSDC(USDC_UNDERLYING).approve(address(bm), type(uint256).max);
        bm.setKeeper(address(this));
        bm.rebalance();

        // Warp forward so cache is stale
        vm.warp(block.timestamp + 15 minutes);

        // Snapshot balances before refresh
        uint256 vaultBefore = IERC20(USDC_UNDERLYING).balanceOf(address(vault));
        uint256 warmBefore = aToken.balanceOf(address(warm));

        // Refresh
        bm.refreshWarmNav();

        // No funds moved
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(address(vault)), vaultBefore, "vault unchanged");
        assertEq(aToken.balanceOf(address(warm)), warmBefore, "warm unchanged");

        // totalAssets, convertToShares, previewDeposit should be internally consistent
        uint256 ta = vault.totalAssets();
        assertGt(ta, 0, "totalAssets should be > 0");

        uint256 depositAmt = 100e6;
        uint256 shares = vault.convertToShares(depositAmt);
        uint256 previewShares = vault.previewDeposit(depositAmt);

        // convertToShares and previewDeposit should be consistent
        // previewDeposit may account for fees, so it can return <= convertToShares
        assertGt(shares, 0, "convertToShares should return > 0");
        assertGt(previewShares, 0, "previewDeposit should return > 0");
        assertLe(previewShares, shares, "previewDeposit <= convertToShares (fee-adjusted)");

        // Cache must match actual warm balance
        uint256 cachedNav = bm.cachedWarmNav();
        uint256 actualWarm = bm.warmBalance();
        assertEq(cachedNav, actualWarm, "cached NAV must equal actual warmBalance after refresh");
    }
}

/// @notice Mock warm adapter that can be configured to fail
contract FailingWarmAdapter is IWarmAdapter {
    bool private _shouldFail;

    function setShouldFail(bool shouldFail) external {
        _shouldFail = shouldFail;
    }

    function asset() external pure returns (address) {
        return 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    }

    function coreVault() external pure returns (address) {
        return address(0);
    }

    function totalAssets() external view returns (uint256) {
        if (_shouldFail) {
            revert("Adapter failed");
        }
        return 0;
    }

    function deposit(uint256) external pure returns (uint256) {
        return 0;
    }

    function withdraw(uint256, address) external pure returns (uint256) {
        return 0;
    }
}
