// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { BufferManager } from "../../../src/core/modules/BufferManager.sol";
import { IBufferManager } from "../../../src/interfaces/IBufferManager.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";

/// @notice Proves BufferManager.minRebalanceAmount scales with the deployed vault's
///         actual asset decimals instead of assuming 6dp/USDC.
contract BufferManager_Decimals_Test is Test {
    function _deployVaultAndBuffer(uint8 decimals) internal returns (BufferManager bm) {
        ERC20Mock asset_ = new ERC20Mock("TOK", "TOK", decimals);
        MockParamsProvider params = new MockParamsProvider();
        CoreHarness vault = new CoreHarness(
            IERC20Metadata(address(asset_)), "Vault", "vTOK", address(this), address(0xFEE), address(params)
        );

        IBufferManager.BufferConfig memory cfg;
        cfg.targetHotBps = 1000;
        cfg.minHotBps = 800;
        cfg.targetWarmBps = 9000;
        cfg.maxWarmBps = 10000;
        cfg.asset = address(asset_);
        cfg.warmAdapter = address(0);
        cfg.paused = true;
        bm = new BufferManager(address(this), address(vault), cfg);
    }

    function test_minRebalanceAmount_scales_6dp() public {
        BufferManager bm = _deployVaultAndBuffer(6);
        assertEq(bm.minRebalanceAmount(), 5_000e6, "5k USDC-equivalent at 6dp");
    }

    function test_minRebalanceAmount_scales_18dp() public {
        BufferManager bm = _deployVaultAndBuffer(18);
        assertEq(bm.minRebalanceAmount(), 5_000e18, "5k WETH-equivalent at 18dp, not 5_000e6");
    }

    function test_minRebalanceAmount_scales_8dp() public {
        BufferManager bm = _deployVaultAndBuffer(8);
        assertEq(bm.minRebalanceAmount(), 5_000e8);
    }
}
