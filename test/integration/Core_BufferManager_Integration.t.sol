// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CoreHarness } from "../helpers/CoreHarness.sol";
import { MockUSDC } from "../helpers/MockUSDC.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";
import { MockAToken } from "../helpers/MockAToken.sol";
import { MockAavePool, MockAaveDataProvider } from "../helpers/MockAave.sol";
import { AaveV3WarmAdapter_USDC } from "../../src/adapters/warm/AaveV3WarmAdapter_USDC.sol";
import { BufferManager } from "../../src/core/modules/BufferManager.sol";
import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";

contract Core_BufferManager_Integration is Test {
    address constant USDC_UNDERLYING = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    CoreHarness internal core;
    BufferManager internal bm;
    AaveV3WarmAdapter_USDC internal warm;

    MockUSDC internal mock;
    MockParamsProvider internal params;
    MockAToken internal aToken;
    MockAavePool internal pool;
    MockAaveDataProvider internal data;

    function setUp() public {
        mock = new MockUSDC();
        vm.etch(USDC_UNDERLYING, address(mock).code);

        aToken = new MockAToken();
        pool = new MockAavePool(USDC_UNDERLYING, address(aToken));
        data = new MockAaveDataProvider(address(aToken));

        params = new MockParamsProvider();
        core = new CoreHarness(
            IERC20Metadata(USDC_UNDERLYING),
            "USDC Agg",
            "agUSDC",
            address(this),
            address(this),
            address(params)
        );

        // Init BM without adapter, then complete config after warm deploy
        IBufferManager.BufferConfig memory cfg;
        cfg.targetHotBps = 1000; // 10%
        cfg.minHotBps = 800; // 8%
        cfg.targetWarmBps = 9000;
        cfg.maxWarmBps = 10000;
        cfg.asset = USDC_UNDERLYING;
        cfg.warmAdapter = address(0);
        cfg.twapWindowSec = 0;
        cfg.paused = false;
        bm = new BufferManager(address(this), address(core), cfg);

        // Deploy warm adapter with controller=bm, coreVault=core
        warm = new AaveV3WarmAdapter_USDC(address(bm), address(core), address(pool), address(data));
        cfg.warmAdapter = address(warm);
        bm.updateConfig(cfg);

        core.setBufferManagerUnsafe(address(bm));

        // Approve adapter to pull from core (new pull pattern)
        vm.prank(address(core));
        MockUSDC(USDC_UNDERLYING).approve(address(warm), type(uint256).max);
    }

    function _mintTo(address to, uint256 amt) internal {
        MockUSDC(USDC_UNDERLYING).mint(to, amt);
    }

    function test_prepareDeploy_and_executeDeploy_via_core() public {
        // Fund Core directly
        _mintTo(address(this), 500_000e6);
        require(IERC20(USDC_UNDERLYING).transfer(address(core), 500_000e6), "transfer fail");

        // plan: expect deploy = hot - targetHot
        (, uint256 needDeploy) = bm.plan();
        uint256 hot = IERC20(USDC_UNDERLYING).balanceOf(address(core));
        uint256 targetHot = ((hot) * 1000) / 1e4; // 10% of NAV (warm=0 so NAV=hot)
        uint256 expected = hot > targetHot ? (hot - targetHot) : 0;
        assertEq(needDeploy, expected, "prepareDeploy mismatch");

        // Approve BM and execute as core
        vm.prank(address(core));
        IERC20(USDC_UNDERLYING).approve(address(bm), type(uint256).max);
        vm.prank(address(core));
        bm.executeDeploy(needDeploy);

        uint256 hotAfter = IERC20(USDC_UNDERLYING).balanceOf(address(core));
        uint256 warmBal = aToken.balanceOf(address(warm));
        uint256 nav = hotAfter + warmBal;
        uint256 targetAfter = (nav * 1000) / 1e4;
        assertApproxEqAbs(hotAfter, targetAfter, 2, "hot not near target after executeDeploy");
        assertEq(nav, 500_000e6, "NAV conservation");
    }

    function test_refill_via_core_when_hot_below_min() public {
        // First deploy to target
        _mintTo(address(this), 400_000e6);
        require(IERC20(USDC_UNDERLYING).transfer(address(core), 400_000e6), "transfer fail");
        vm.prank(address(core));
        IERC20(USDC_UNDERLYING).approve(address(bm), type(uint256).max);
        vm.prank(address(core));
        bm.rebalance();

        // Increase thresholds to force refill
        IBufferManager.BufferConfig memory cfg = bm.getConfig();
        cfg.minHotBps = 1500; // 15%
        cfg.targetHotBps = 2000; // 20%
        bm.updateConfig(cfg);

        (uint256 needRefill,) = bm.plan();
        assertGt(needRefill, 0, "needRefill should be > 0");
        uint256 hotBefore = IERC20(USDC_UNDERLYING).balanceOf(address(core));
        vm.prank(address(core));
        bm.refill(needRefill);
        uint256 hotAfter = IERC20(USDC_UNDERLYING).balanceOf(address(core));
        assertGt(hotAfter, hotBefore, "hot should increase after refill");
    }

    /// @notice Test that warm adapter needs allowance from CoreVault
    /// @dev With pull pattern, adapter does transferFrom(coreVault, ...)
    function test_executeDeploy_requires_adapter_allowance() public {
        // Create a fresh BufferManager with a new adapter that has no CoreVault approval
        IBufferManager.BufferConfig memory cfg;
        cfg.targetHotBps = 1000;
        cfg.minHotBps = 800;
        cfg.targetWarmBps = 9000;
        cfg.maxWarmBps = 10000;
        cfg.asset = USDC_UNDERLYING;
        cfg.warmAdapter = address(0);
        cfg.twapWindowSec = 0;
        cfg.paused = false;

        BufferManager freshBm = new BufferManager(address(this), address(core), cfg);

        // Deploy a new adapter with controller=freshBm (no approval from core yet)
        AaveV3WarmAdapter_USDC newWarm = new AaveV3WarmAdapter_USDC(
            address(freshBm), address(core), address(pool), address(data)
        );
        cfg.warmAdapter = address(newWarm);
        freshBm.updateConfig(cfg);

        // Wire into core (temporarily)
        core.setBufferManagerUnsafe(address(freshBm));

        // Fund core and try to deploy - should fail because newWarm has no approval
        // With try/catch fallback, deploy failure just emits WarmDeployAllFailed
        _mintTo(address(core), 100_000e6);
        vm.prank(address(core));
        freshBm.executeDeploy(1000e6);
        // Check warm balance is still 0 (deploy failed silently)
        assertEq(newWarm.totalAssets(), 0, "should not have deployed without approval");

        // Now approve and deploy should succeed
        vm.prank(address(core));
        IERC20(USDC_UNDERLYING).approve(address(newWarm), type(uint256).max);
        vm.prank(address(core));
        freshBm.executeDeploy(1000e6);
        assertGt(newWarm.totalAssets(), 0, "should have deployed after approval");

        // Restore original BM
        core.setBufferManagerUnsafe(address(bm));
    }
}
