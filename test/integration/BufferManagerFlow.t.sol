// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreHarness } from "../helpers/CoreHarness.sol";
import { MockUSDC } from "../helpers/MockUSDC.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";
import { MockAToken } from "../helpers/MockAToken.sol";
import { MockAavePool, MockAaveDataProvider } from "../helpers/MockAave.sol";
import { AaveV3WarmAdapter_USDC } from "../../src/adapters/warm/AaveV3WarmAdapter_USDC.sol";
import { BufferManager } from "../../src/core/modules/BufferManager.sol";
import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";
import { IQueueModule } from "../../src/interfaces/IQueueModule.sol";

contract BufferManagerFlowTest is Test {
    address constant USDC_UNDERLYING = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // same as adapter

    CoreHarness vault;
    BufferManager bm;
    AaveV3WarmAdapter_USDC warm;

    MockUSDC mock;
    MockParamsProvider params;
    MockAToken aToken;
    MockAavePool pool;
    MockAaveDataProvider data;

    address user = address(0xBEEF);
    address treasury = address(0xFEE);

    function setUp() public {
        // Deploy a MockUSDC and etch its runtime code into the adapter's UNDERLYING address
        mock = new MockUSDC();
        bytes memory code = address(mock).code;
        vm.etch(USDC_UNDERLYING, code);

        // Sanity: decimals() is constant 6 in code, so Core reads 6
        // Deploy mock aToken + pool + dataProvider
        aToken = new MockAToken();
        pool = new MockAavePool(USDC_UNDERLYING, address(aToken));
        data = new MockAaveDataProvider(address(aToken));

        // Deploy params provider
        params = new MockParamsProvider();

        // Deploy Core with USDC_UNDERLYING as asset
        vault = new CoreHarness(
            IERC20Metadata(USDC_UNDERLYING),
            "Vault",
            "vUSDC",
            address(this),
            treasury,
            address(params)
        );

        // Deploy warm adapter placeholder address (controller will be set to bm after deployment)
        // First, create a temporary BufferManager to satisfy constructor, then update with real adapter
        IBufferManager.BufferConfig memory cfg;
        cfg.targetHotBps = 1000; // 10% hot
        cfg.minHotBps = 800; // 8% min
        cfg.targetWarmBps = 9000;
        cfg.maxWarmBps = 10000;
        cfg.asset = USDC_UNDERLYING;
        cfg.warmAdapter = address(0);
        cfg.twapWindowSec = 0;
        cfg.paused = false;
        bm = new BufferManager(address(this), address(vault), cfg);

        // Deploy warm adapter with controller = buffer manager, coreVault = vault (now that bm exists)
        warm = new AaveV3WarmAdapter_USDC(address(bm), address(vault), address(pool), address(data));

        // Wire buffer manager into core
        vault.setBufferManagerUnsafe(address(bm));

        // Configure buffer manager with the actual warm adapter
        cfg = IBufferManager.BufferConfig({
            targetHotBps: 1000, // 10%
            minHotBps: 800, // 8%
            targetWarmBps: 9000,
            maxWarmBps: 10000, // up to 100% buffer allowed
            opsReserveTargetBps: 100, // 1%
            maxWarmSlippageBps: 50, // 0.5%
            asset: USDC_UNDERLYING,
            warmAdapter: address(warm),
            twapWindowSec: 0,
            paused: false
        });
        bm.updateConfig(cfg);

        // Approve warm adapter to pull from vault (new pull pattern)
        vm.prank(address(vault));
        MockUSDC(USDC_UNDERLYING).approve(address(warm), type(uint256).max);

        // Fund user with USDC at the etched address
        MockUSDC(USDC_UNDERLYING).mint(user, 1_000_000e6); // 1,000,000 USDC
    }

    function test_Deposit_Deploy_and_Withdraw_Refill() public {
        uint256 amount = 100_000e6; // 100k USDC deposit

        vm.startPrank(user);
        MockUSDC(USDC_UNDERLYING).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();

        // FIX A: After deposit, all funds stay in HOT (no automatic warm deploy)
        uint256 hotAfterDeposit = MockUSDC(USDC_UNDERLYING).balanceOf(address(vault));
        uint256 warmAfterDeposit = aToken.balanceOf(address(warm));
        assertEq(hotAfterDeposit, amount, "All funds should be in hot after deposit");
        assertEq(warmAfterDeposit, 0, "Warm should be empty after deposit");

        // FIX A: Call rebalance via keeper to trigger warm deploy
        bm.setKeeper(address(this));
        bm.rebalance();

        // After rebalance, bufferManager deploys to warm (~90% of NAV)
        uint256 hot = MockUSDC(USDC_UNDERLYING).balanceOf(address(vault));
        uint256 warmBal = aToken.balanceOf(address(warm));

        // Target hot ~10% (within rounding tolerance)
        assertApproxEqAbs(hot, amount / 10, 2);
        assertApproxEqAbs(warmBal, amount - (amount / 10), 2);

        // Now withdraw an amount larger than current hot to trigger refill from warm.
        // Async vault: requestClaim (hot insufficient → queues), then keeper settles
        // with bm.refill() pulling the shortfall from warm.
        uint256 withdrawAssets = 50_000e6; // 50k USDC
        uint256 sharesToClaim = vault.previewWithdraw(withdrawAssets);
        vm.startPrank(user);
        IQueueModule(address(vault)).requestClaim(false, sharesToClaim);
        vm.stopPrank();
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);

        // User should have received 50k
        assertEq(MockUSDC(USDC_UNDERLYING).balanceOf(user), 1_000_000e6 - amount + withdrawAssets);

        // Warm position should have decreased by ~ (withdrawAssets - initial hot shortfall rounded)
        uint256 hotAfter = MockUSDC(USDC_UNDERLYING).balanceOf(address(vault));
        uint256 warmAfter = aToken.balanceOf(address(warm));

        // Some small tolerance to account for integer division
        assertLt(warmAfter, warmBal);
        assertGe(hotAfter, 0);

        // Shares decreased appropriately
        assertEq(vault.balanceOf(user), shares - vault.previewWithdraw(withdrawAssets));
    }
}
