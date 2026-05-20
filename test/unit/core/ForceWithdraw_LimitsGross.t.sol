// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ForceWithdrawBaseTest, IForceWithdraw } from "./ForceWithdrawBase.t.sol";
import { IStrategyRouter } from "src/interfaces/IStrategyRouter.sol";
import { ERC4626Module } from "src/core/modules/ERC4626Module.sol";

/**
 * @title ForceWithdraw_LimitsGross_Test
 * @notice FIX #2: Verifies withdrawal limits use gross (assets + feeAssetsEq)
 */
contract ForceWithdraw_LimitsGross_Test is ForceWithdrawBaseTest {
    function test_limitsUseGross_notNet() public {
        // Setup: witBps=25, forceExitPenaltyBps=150
        uint256 assets = 100e6;
        uint256 baseShares = vault.previewWithdraw(assets);
        uint256 witFeeShares = (baseShares * DEFAULT_WIT_BPS) / 10000;
        uint256 penaltyShares = (baseShares * DEFAULT_FORCE_EXIT_BPS) / 10000;
        uint256 totalFeeShares = witFeeShares + penaltyShares;
        uint256 feeAssetsEq = vault.convertToAssets(totalFeeShares);
        uint256 gross = assets + feeAssetsEq;

        // Set per-tx limit BETWEEN assets and gross
        // This should cause a revert because gross > limit
        params.setMaxWithdrawalPerTx(gross - 1);

        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // Should revert because gross > limit
        vm.prank(user);
        vm.expectRevert(ERC4626Module.WithdrawalLimitExceeded.selector);
        IForceWithdraw(address(vault))
            .forceWithdraw(assets, receiver, user, plan, type(uint256).max);
    }

    function test_limitsAtGross_succeeds() public {
        uint256 assets = 100e6;
        uint256 baseShares = vault.previewWithdraw(assets);
        uint256 witFeeShares = (baseShares * DEFAULT_WIT_BPS) / 10000;
        uint256 penaltyShares = (baseShares * DEFAULT_FORCE_EXIT_BPS) / 10000;
        uint256 totalFeeShares = witFeeShares + penaltyShares;
        uint256 feeAssetsEq = vault.convertToAssets(totalFeeShares);
        uint256 gross = assets + feeAssetsEq;

        // Set per-tx limit exactly at gross
        params.setMaxWithdrawalPerTx(gross);

        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // Should succeed because gross <= limit
        vm.prank(user);
        IForceWithdraw(address(vault))
            .forceWithdraw(assets, receiver, user, plan, type(uint256).max);

        assertEq(usdc.balanceOf(receiver), assets, "Receiver should get assets");
    }

    function test_perBlockLimit_usesGross() public {
        uint256 assets = 100e6;
        uint256 baseShares = vault.previewWithdraw(assets);
        uint256 witFeeShares = (baseShares * DEFAULT_WIT_BPS) / 10000;
        uint256 penaltyShares = (baseShares * DEFAULT_FORCE_EXIT_BPS) / 10000;
        uint256 totalFeeShares = witFeeShares + penaltyShares;
        uint256 feeAssetsEq = vault.convertToAssets(totalFeeShares);
        uint256 gross = assets + feeAssetsEq;

        // Set per-block limit BETWEEN assets and gross
        params.setMaxWithdrawalPerBlock(gross - 1);

        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // Should revert because gross > limit
        vm.prank(user);
        vm.expectRevert(ERC4626Module.WithdrawalLimitExceeded.selector);
        IForceWithdraw(address(vault))
            .forceWithdraw(assets, receiver, user, plan, type(uint256).max);
    }

    function test_perBlockLimit_cumulative() public {
        uint256 assets = 50e6; // Half of deposit

        // Get gross for first withdrawal
        uint256 baseShares = vault.previewWithdraw(assets);
        uint256 totalFeeShares = (baseShares * (DEFAULT_WIT_BPS + DEFAULT_FORCE_EXIT_BPS)) / 10000;
        uint256 feeAssetsEq = vault.convertToAssets(totalFeeShares);
        uint256 gross = assets + feeAssetsEq;

        // Set per-block limit to allow first but not second
        params.setMaxWithdrawalPerBlock(gross + gross / 2); // 1.5x gross

        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // First withdrawal should succeed
        vm.prank(user);
        IForceWithdraw(address(vault))
            .forceWithdraw(assets, receiver, user, plan, type(uint256).max);

        // Second withdrawal in same block should fail (cumulative)
        vm.prank(user);
        vm.expectRevert(ERC4626Module.WithdrawalLimitExceeded.selector);
        IForceWithdraw(address(vault))
            .forceWithdraw(assets, receiver, user, plan, type(uint256).max);
    }

    function test_perBlockLimit_resetsNextBlock() public {
        uint256 assets = 50e6;

        uint256 baseShares = vault.previewWithdraw(assets);
        uint256 totalFeeShares = (baseShares * (DEFAULT_WIT_BPS + DEFAULT_FORCE_EXIT_BPS)) / 10000;
        uint256 feeAssetsEq = vault.convertToAssets(totalFeeShares);
        uint256 gross = assets + feeAssetsEq;

        // Set per-block limit to allow one withdrawal
        params.setMaxWithdrawalPerBlock(gross);

        IStrategyRouter.Pull[] memory plan = _createEmptyPlan();

        // First withdrawal
        vm.prank(user);
        IForceWithdraw(address(vault))
            .forceWithdraw(assets, receiver, user, plan, type(uint256).max);

        // Move to next block
        vm.roll(block.number + 1);

        // Second withdrawal in new block should succeed
        vm.prank(user);
        IForceWithdraw(address(vault)).forceWithdraw(assets, user, user, plan, type(uint256).max);
    }
}
