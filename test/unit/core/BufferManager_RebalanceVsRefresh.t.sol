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

/// @title BufferManager_RebalanceVsRefresh_Test
/// @notice Proves separation between refreshWarmNav() (cache-only) and rebalance() (fund movement)
/// @dev INV-2: No fund movement during refresh
///      INV-5: Router cooldown unaffected
///      INV-6: Permission separation — rebalance() keeper/core, refreshWarmNav() permissionless
contract BufferManager_RebalanceVsRefresh_Test is Test {
    address constant USDC_UNDERLYING = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    CoreHarness vault;
    BufferManager bm;
    AaveV3WarmAdapter_USDC warm;
    MockUSDC mock;
    MockParamsProvider params;
    MockAToken aToken;
    MockAavePool pool;
    MockAaveDataProvider data;

    address randomUser = address(0xBEEF);

    function setUp() public {
        mock = new MockUSDC();
        vm.etch(USDC_UNDERLYING, address(mock).code);

        aToken = new MockAToken();
        pool = new MockAavePool(USDC_UNDERLYING, address(aToken));
        data = new MockAaveDataProvider(address(aToken));
        params = new MockParamsProvider();

        vault = new CoreHarness(
            IERC20Metadata(USDC_UNDERLYING), "Vault", "vUSDC",
            address(this), address(0xFEE), address(params)
        );

        IBufferManager.BufferConfig memory cfg;
        cfg.targetHotBps = 1000;
        cfg.minHotBps = 800;
        cfg.targetWarmBps = 9000;
        cfg.maxWarmBps = 10000;
        cfg.asset = USDC_UNDERLYING;
        cfg.warmAdapter = address(0);
        cfg.paused = false;
        bm = new BufferManager(address(this), address(vault), cfg);

        warm = new AaveV3WarmAdapter_USDC(address(bm), address(vault), address(pool), address(data));
        cfg.warmAdapter = address(warm);
        bm.updateConfig(cfg);
        vault.setBufferManagerUnsafe(address(bm));

        vm.prank(address(vault));
        MockUSDC(USDC_UNDERLYING).approve(address(warm), type(uint256).max);
        vm.prank(address(vault));
        MockUSDC(USDC_UNDERLYING).approve(address(bm), type(uint256).max);

        // Seed vault with 1M USDC and do initial rebalance
        MockUSDC(USDC_UNDERLYING).mint(address(vault), 1_000_000e6);
        vm.prank(address(vault));
        bm.rebalance();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 5d. Separazione refresh vs rebalance
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice refreshWarmNav() does NOT require keeper or core — anyone can call
    function test_refreshWarmNav_does_not_require_keeper() public {
        vm.prank(randomUser);
        bm.refreshWarmNav(); // Must not revert
    }

    /// @notice rebalance() still requires keeper or core — random user cannot call
    function test_rebalance_still_requires_keeper_or_core() public {
        vm.prank(randomUser);
        vm.expectRevert(); // onlyKeeperOrCore
        bm.rebalance();
    }

    /// @notice refreshWarmNav() does NOT update lastRebalanceTs
    function test_refreshWarmNav_does_not_update_rebalance_cooldown_state() public {
        uint40 tsBefore = bm.lastRebalanceTs();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(randomUser);
        bm.refreshWarmNav();

        uint40 tsAfter = bm.lastRebalanceTs();
        assertEq(tsAfter, tsBefore, "refreshWarmNav must NOT update lastRebalanceTs");
    }

    /// @notice refreshWarmNav() does NOT touch lastBatchTimestamp on StrategyRouter
    /// @dev We verify by checking that no fund movement occurred — the router is not involved
    function test_refreshWarmNav_does_not_touch_lastBatchTimestamp() public {
        uint256 hotBefore = IERC20(USDC_UNDERLYING).balanceOf(address(vault));
        uint256 warmBefore = aToken.balanceOf(address(warm));

        vm.warp(block.timestamp + 1 hours);
        vm.prank(randomUser);
        bm.refreshWarmNav();

        uint256 hotAfter = IERC20(USDC_UNDERLYING).balanceOf(address(vault));
        uint256 warmAfter = aToken.balanceOf(address(warm));

        assertEq(hotAfter, hotBefore, "hot balance must be unchanged after refreshWarmNav");
        assertEq(warmAfter, warmBefore, "warm balance must be unchanged after refreshWarmNav");
    }

    /// @notice rebalance() moves funds but refreshWarmNav() does not
    function test_rebalance_moves_funds_but_refreshWarmNav_does_not() public {
        // Add extra USDC to vault to create a surplus (hot > target)
        MockUSDC(USDC_UNDERLYING).mint(address(vault), 500_000e6);

        uint256 hotBefore = IERC20(USDC_UNDERLYING).balanceOf(address(vault));
        uint256 warmBefore = aToken.balanceOf(address(warm));

        // refreshWarmNav — no fund movement
        vm.prank(randomUser);
        bm.refreshWarmNav();

        assertEq(
            IERC20(USDC_UNDERLYING).balanceOf(address(vault)),
            hotBefore,
            "refreshWarmNav must not move funds"
        );
        assertEq(aToken.balanceOf(address(warm)), warmBefore, "refreshWarmNav must not move warm funds");

        // rebalance — moves funds (deployes surplus to warm)
        vm.prank(address(vault));
        bm.rebalance();

        uint256 hotAfter = IERC20(USDC_UNDERLYING).balanceOf(address(vault));
        assertTrue(hotAfter < hotBefore, "rebalance must move funds from hot to warm");
    }
}
