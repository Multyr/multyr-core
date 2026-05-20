// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Percentage
/// @notice Library for percentage calculations using basis points (bps)
/// @dev Uses basis points (1 bps = 0.01%, 10000 bps = 100%) for on-chain configuration
///      All functions explicitly specify rounding direction (Down/Up) for auditability
library Percentage {
    /// @dev BPS_DENOMINATOR = 10000 (100% = 10000 bps)
    uint256 internal constant BPS_DENOMINATOR = 10000;

    /// @dev Maximum bps value (100%)
    uint256 internal constant MAX_BPS = 10000;

    /// @dev WAD constant for conversions (1e18)
    uint256 private constant WAD = 1e18;

    // ========== BPS Multiplication ==========

    /// @notice Multiply value by percentage in bps, rounding down
    /// @param value Value to multiply
    /// @param bps Percentage in basis points (100 bps = 1%)
    /// @return Result = value * bps / 10000, rounded down
    /// @dev Example: mulBpsDown(1000, 250) = 1000 * 250 / 10000 = 25 (2.5%)
    function mulBpsDown(uint256 value, uint256 bps) internal pure returns (uint256) {
        return (value * bps) / BPS_DENOMINATOR;
    }

    /// @notice Multiply value by percentage in bps, rounding up
    /// @param value Value to multiply
    /// @param bps Percentage in basis points
    /// @return Result = value * bps / 10000, rounded up
    /// @dev Always rounds up to ensure no underpayment in fees
    function mulBpsUp(uint256 value, uint256 bps) internal pure returns (uint256) {
        uint256 prod = value * bps;
        return prod == 0 ? 0 : ((prod - 1) / BPS_DENOMINATOR) + 1;
    }

    /// @notice Calculate what value would result in target after applying bps fee (inverse operation)
    /// @param target Desired result after fee application
    /// @param bps Fee in basis points
    /// @return Original value needed, rounded up
    /// @dev Example: If fee is 1% (100 bps), to get 99 after fee, need 100 before
    ///      inverseMulBps(99, 100) = 99 * 10000 / (10000 - 100) = 100
    function inverseMulBpsUp(uint256 target, uint256 bps) internal pure returns (uint256) {
        require(bps < BPS_DENOMINATOR, "Percentage: bps must be < 100%");
        uint256 denominator = BPS_DENOMINATOR - bps;
        return ((target * BPS_DENOMINATOR) + denominator - 1) / denominator;
    }

    // ========== BPS Validation & Clamping ==========

    /// @notice Validate that bps is within valid range [0, MAX_BPS]
    /// @param bps Basis points to validate
    /// @return True if valid
    function isValidBps(uint256 bps) internal pure returns (bool) {
        return bps <= MAX_BPS;
    }

    /// @notice Clamp bps value between min and max
    /// @param bps Value to clamp
    /// @param minBps Minimum allowed value
    /// @param maxBps Maximum allowed value
    /// @return Clamped value
    /// @dev Reverts if minBps > maxBps
    function clampBps(uint256 bps, uint256 minBps, uint256 maxBps) internal pure returns (uint256) {
        require(minBps <= maxBps, "Percentage: invalid bounds");
        require(maxBps <= MAX_BPS, "Percentage: maxBps exceeds 100%");

        if (bps < minBps) return minBps;
        if (bps > maxBps) return maxBps;
        return bps;
    }

    /// @notice Ensure bps is within bounds, revert if not
    /// @param bps Value to check
    /// @param minBps Minimum allowed value
    /// @param maxBps Maximum allowed value
    /// @dev Reverts with descriptive message if out of bounds
    function requireBpsInBounds(uint256 bps, uint256 minBps, uint256 maxBps) internal pure {
        require(bps >= minBps, "Percentage: below minimum");
        require(bps <= maxBps, "Percentage: above maximum");
    }

    // ========== Conversion: BPS <-> WAD ==========

    /// @notice Convert basis points to WAD (18 decimals)
    /// @param bps Basis points (10000 = 100%)
    /// @return Value in WAD (1e18 = 100%)
    /// @dev Example: bpsToWad(250) = 0.025e18 (2.5%)
    function bpsToWad(uint256 bps) internal pure returns (uint256) {
        return (bps * WAD) / BPS_DENOMINATOR;
    }

    /// @notice Convert WAD to basis points, rounding down
    /// @param wad Value in WAD (1e18 = 100%)
    /// @return Basis points (10000 = 100%)
    /// @dev Example: wadToBpsDown(0.025e18) = 250 (2.5%)
    function wadToBpsDown(uint256 wad) internal pure returns (uint256) {
        return (wad * BPS_DENOMINATOR) / WAD;
    }

    /// @notice Convert WAD to basis points, rounding up
    /// @param wad Value in WAD
    /// @return Basis points, rounded up
    function wadToBpsUp(uint256 wad) internal pure returns (uint256) {
        uint256 prod = wad * BPS_DENOMINATOR;
        return prod == 0 ? 0 : ((prod - 1) / WAD) + 1;
    }

    // ========== Percentage Composition ==========

    /// @notice Add two percentages in bps
    /// @param bps1 First percentage
    /// @param bps2 Second percentage
    /// @return Sum of percentages
    /// @dev Reverts if sum exceeds 100%
    function addBps(uint256 bps1, uint256 bps2) internal pure returns (uint256) {
        uint256 sum = bps1 + bps2;
        require(sum <= MAX_BPS, "Percentage: sum exceeds 100%");
        return sum;
    }

    /// @notice Subtract bps2 from bps1
    /// @param bps1 Minuend
    /// @param bps2 Subtrahend
    /// @return Difference
    /// @dev Reverts on underflow
    function subBps(uint256 bps1, uint256 bps2) internal pure returns (uint256) {
        require(bps1 >= bps2, "Percentage: underflow");
        return bps1 - bps2;
    }

    /// @notice Calculate complementary percentage (100% - bps)
    /// @param bps Percentage in bps
    /// @return Complement (MAX_BPS - bps)
    /// @dev Example: complementBps(250) = 9750 (97.5% if input was 2.5%)
    function complementBps(uint256 bps) internal pure returns (uint256) {
        require(bps <= MAX_BPS, "Percentage: bps exceeds 100%");
        return MAX_BPS - bps;
    }

    // ========== Ratio Conversions ==========

    /// @notice Convert ratio (numerator/denominator) to bps
    /// @param numerator Numerator of ratio
    /// @param denominator Denominator of ratio
    /// @return Percentage in bps, rounded down
    /// @dev Example: ratioToBps(1, 4) = 2500 (25%)
    function ratioToBpsDown(uint256 numerator, uint256 denominator)
        internal
        pure
        returns (uint256)
    {
        require(denominator != 0, "Percentage: division by zero");
        return (numerator * BPS_DENOMINATOR) / denominator;
    }

    /// @notice Convert ratio to bps, rounding up
    /// @param numerator Numerator of ratio
    /// @param denominator Denominator of ratio
    /// @return Percentage in bps, rounded up
    function ratioToBpsUp(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        require(denominator != 0, "Percentage: division by zero");
        uint256 prod = numerator * BPS_DENOMINATOR;
        return ((prod + denominator - 1) / denominator);
    }

    // ========== Fee Calculations ==========

    /// @notice Calculate net amount after deducting fee in bps
    /// @param gross Gross amount before fee
    /// @param feeBps Fee percentage in bps
    /// @return net Net amount after fee deduction, rounded down
    /// @return fee Fee amount, rounded up (to favor protocol)
    /// @dev Ensures: gross = net + fee
    ///      Example: applyFee(1000, 250) returns (net=975, fee=25) for 2.5% fee
    function applyFeeBps(uint256 gross, uint256 feeBps)
        internal
        pure
        returns (uint256 net, uint256 fee)
    {
        require(feeBps <= MAX_BPS, "Percentage: fee exceeds 100%");
        fee = mulBpsUp(gross, feeBps); // Round up fee to favor protocol
        net = gross - fee;
    }

    /// @notice Calculate gross amount from net after fee was deducted
    /// @param net Net amount after fee
    /// @param feeBps Fee percentage in bps
    /// @return gross Gross amount before fee, rounded up
    /// @dev Inverse of applyFeeBps
    ///      Example: If 2.5% fee was taken from gross to get net=975, grossFromNet(975, 250) ≈ 1000
    function grossFromNetBps(uint256 net, uint256 feeBps) internal pure returns (uint256 gross) {
        require(feeBps < BPS_DENOMINATOR, "Percentage: fee must be < 100%");
        uint256 netBps = BPS_DENOMINATOR - feeBps;
        // gross = net * BPS_DENOMINATOR / netBps, rounded up
        gross = ((net * BPS_DENOMINATOR) + netBps - 1) / netBps;
    }

    // ========== Weighted Averages ==========

    /// @notice Calculate weighted average of two values using bps weights
    /// @param value1 First value
    /// @param weight1Bps Weight for first value in bps
    /// @param value2 Second value
    /// @param weight2Bps Weight for second value in bps
    /// @return Weighted average, rounded down
    /// @dev Weights must sum to 10000 (100%)
    ///      Result = (value1 * weight1 + value2 * weight2) / 10000
    function weightedAvgBps(uint256 value1, uint256 weight1Bps, uint256 value2, uint256 weight2Bps)
        internal
        pure
        returns (uint256)
    {
        require(weight1Bps + weight2Bps == BPS_DENOMINATOR, "Percentage: weights must sum to 100%");
        return mulBpsDown(value1, weight1Bps) + mulBpsDown(value2, weight2Bps);
    }

    // ========== Comparison Helpers ==========

    /// @notice Check if value is approximately equal to target within tolerance (in bps)
    /// @param value Value to check
    /// @param target Target value
    /// @param toleranceBps Tolerance in bps (e.g., 10 = 0.1%)
    /// @return True if |value - target| / target <= toleranceBps
    function isWithinToleranceBps(uint256 value, uint256 target, uint256 toleranceBps)
        internal
        pure
        returns (bool)
    {
        if (target == 0) return value == 0;

        uint256 diff = value > target ? value - target : target - value;
        uint256 maxDiff = mulBpsDown(target, toleranceBps);

        return diff <= maxDiff;
    }

    // ========== Utility Functions ==========

    /// @notice Calculate percentage change from old to new value
    /// @param oldValue Previous value
    /// @param newValue New value
    /// @return changeBps Change in bps (positive = increase, negative = decrease)
    /// @return isIncrease True if value increased, false if decreased
    /// @dev Returns (0, true) if oldValue == 0
    function percentageChange(uint256 oldValue, uint256 newValue)
        internal
        pure
        returns (uint256 changeBps, bool isIncrease)
    {
        if (oldValue == 0) {
            return (0, true);
        }

        if (newValue >= oldValue) {
            uint256 increase = newValue - oldValue;
            changeBps = ratioToBpsDown(increase, oldValue);
            isIncrease = true;
        } else {
            uint256 decrease = oldValue - newValue;
            changeBps = ratioToBpsDown(decrease, oldValue);
            isIncrease = false;
        }
    }

    /// @notice Split amount into multiple parts based on bps allocations
    /// @param total Total amount to split
    /// @param allocationsBps Array of allocations in bps (must sum to 10000)
    /// @return parts Array of split amounts
    /// @dev Handles rounding dust by adding remainder to first allocation
    function splitByBps(uint256 total, uint256[] memory allocationsBps)
        internal
        pure
        returns (uint256[] memory parts)
    {
        uint256 sumBps = 0;
        for (uint256 i = 0; i < allocationsBps.length; i++) {
            sumBps += allocationsBps[i];
        }
        require(sumBps == BPS_DENOMINATOR, "Percentage: allocations must sum to 100%");

        parts = new uint256[](allocationsBps.length);
        uint256 allocated = 0;

        for (uint256 i = 0; i < allocationsBps.length; i++) {
            if (i == allocationsBps.length - 1) {
                // Give remainder to last allocation to handle rounding dust
                parts[i] = total - allocated;
            } else {
                parts[i] = mulBpsDown(total, allocationsBps[i]);
                allocated += parts[i];
            }
        }
    }
}
