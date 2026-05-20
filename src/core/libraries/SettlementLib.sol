// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IBufferManager } from "../../interfaces/IBufferManager.sol";
import { IStrategyRouter } from "../../interfaces/IStrategyRouter.sol";
import { Percentage } from "../../libs/Percentage.sol";

/// @title SettlementLib
/// @notice Library for claim settlement logic - reduces CoreVault bytecode
library SettlementLib {
    using SafeERC20 for IERC20;

    struct SettleContext {
        address asset;
        address bufferManager;
        address router;
        uint16 witFeeBps;
        uint64 lockPeriod;
    }

    struct ClaimData {
        address user;
        uint256 shares;
        uint64 ts;
        bool immediate;
    }

    /// @notice Check if a claim is ready to be settled
    function isClaimReady(
        ClaimData memory claim,
        uint256 gross,
        uint256 capRemaining,
        uint64 lockPeriod
    ) internal view returns (bool) {
        if (claim.immediate) {
            return gross <= capRemaining;
        } else {
            return lockPeriod == 0 || block.timestamp >= uint256(claim.ts) + lockPeriod;
        }
    }

    /// @notice Try to get liquidity for a claim
    /// @return available The amount of liquidity available
    function ensureLiquidity(SettleContext memory ctx, uint256 needed)
        internal
        returns (uint256 available)
    {
        IERC20 token = IERC20(ctx.asset);
        available = token.balanceOf(address(this));

        if (available >= needed) return available;

        // Try buffer first
        if (ctx.bufferManager != address(0)) {
            IBufferManager(ctx.bufferManager).refill(needed - available);
            available = token.balanceOf(address(this));
            if (available >= needed) return available;
        }

        // Try strategies
        if (ctx.router != address(0)) {
            IStrategyRouter r = IStrategyRouter(ctx.router);
            r.executeRedeemBatch(r.planRedeem(needed - available));
            available = token.balanceOf(address(this));
        }

        return available;
    }

    /// @notice Calculate fee and net amounts
    function calculateFeeAndNet(uint256 gross, uint16 feeBps)
        internal
        pure
        returns (uint256 feeAmount, uint256 netAmount)
    {
        feeAmount = Percentage.mulBpsDown(gross, feeBps);
        netAmount = gross - feeAmount;
    }
}
