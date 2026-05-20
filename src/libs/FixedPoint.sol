// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FixedPoint
/// @notice Library for fixed-point arithmetic with explicit rounding direction
/// @dev Uses WAD (1e18) for 18-decimal precision
///      All functions explicitly specify rounding direction (Down/Up) for auditability
library FixedPoint {
    /// @dev WAD = 1e18 (18 decimals precision)
    uint256 internal constant WAD = 1e18;

    /// @dev RAY = 1e27 (27 decimals precision, for high-precision calculations)
    uint256 internal constant RAY = 1e27;

    /// @dev Half WAD for rounding (0.5 in WAD precision)
    uint256 private constant HALF_WAD = 5e17;

    /// @dev Half RAY for rounding
    uint256 private constant HALF_RAY = 5e26;

    // ========== WAD Multiplication ==========

    /// @notice Multiply two WAD values, rounding down
    /// @param x First operand in WAD
    /// @param y Second operand in WAD
    /// @return Result in WAD, rounded down
    /// @dev Result = (x * y) / WAD, rounded down
    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / WAD;
    }

    /// @notice Multiply two WAD values (alias for mulWadDown for compatibility)
    /// @param x First operand in WAD
    /// @param y Second operand in WAD
    /// @return Result in WAD, rounded down
    function mulWad(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulWadDown(x, y);
    }

    /// @notice Multiply two WAD values, rounding up
    /// @param x First operand in WAD
    /// @param y Second operand in WAD
    /// @return Result in WAD, rounded up
    /// @dev Result = (x * y + WAD - 1) / WAD
    function mulWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 prod = x * y;
        return prod == 0 ? 0 : ((prod - 1) / WAD) + 1;
    }

    // ========== WAD Division ==========

    /// @notice Divide x by y in WAD precision, rounding down
    /// @param x Numerator in WAD
    /// @param y Denominator in WAD
    /// @return Result in WAD, rounded down
    /// @dev Result = (x * WAD) / y, rounded down
    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        require(y != 0, "FixedPoint: division by zero");
        return (x * WAD) / y;
    }

    /// @notice Divide x by y in WAD precision (alias for divWadDown for compatibility)
    /// @param x Numerator in WAD
    /// @param y Denominator in WAD
    /// @return Result in WAD, rounded down
    function divWad(uint256 x, uint256 y) internal pure returns (uint256) {
        return divWadDown(x, y);
    }

    /// @notice Divide x by y in WAD precision, rounding up
    /// @param x Numerator in WAD
    /// @param y Denominator in WAD
    /// @return Result in WAD, rounded up
    /// @dev Result = (x * WAD + y - 1) / y, using overflow-safe formula
    function divWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        require(y != 0, "FixedPoint: division by zero");
        uint256 prod = x * WAD;
        // Overflow-safe rounding up: prod/y + (prod%y == 0 ? 0 : 1)
        uint256 result = prod / y;
        if (prod % y != 0) {
            result += 1;
        }
        return result;
    }

    // ========== General Multiply-Divide ==========

    /// @notice Multiply x by y and divide by denominator, rounding down
    /// @param x Numerator
    /// @param y Multiplier
    /// @param denominator Divisor
    /// @return Result = (x * y) / denominator, rounded down
    /// @dev Uses full-precision intermediate multiplication to avoid overflow
    function mulDivDown(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        require(denominator != 0, "FixedPoint: division by zero");

        // Full precision multiply-divide using Solady's approach
        uint256 prod0; // Least significant 256 bits of the product
        uint256 prod1; // Most significant 256 bits of the product

        assembly {
            let mm := mulmod(x, y, not(0))
            prod0 := mul(x, y)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        // Handle overflow
        if (prod1 == 0) {
            return prod0 / denominator;
        }

        require(prod1 < denominator, "FixedPoint: mulDivDown overflow");

        ///////////////////////////////////////////////
        // 512 by 256 division
        ///////////////////////////////////////////////

        // Make division exact by subtracting the remainder from [prod1 prod0]
        uint256 remainder;
        assembly {
            remainder := mulmod(x, y, denominator)
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        // Factor powers of two out of denominator
        uint256 twos = denominator & (~denominator + 1);
        assembly {
            denominator := div(denominator, twos)
            prod0 := div(prod0, twos)
            twos := add(div(sub(0, twos), twos), 1)
        }

        // Shift in bits from prod1 into prod0
        prod0 |= prod1 * twos;

        // Invert denominator mod 2^256
        uint256 inverse = (3 * denominator) ^ 2;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;

        // Multiply by inverse to get result
        return prod0 * inverse;
    }

    /// @notice Multiply x by y and divide by denominator, rounding up
    /// @param x Numerator
    /// @param y Multiplier
    /// @param denominator Divisor
    /// @return Result = (x * y + denominator - 1) / denominator
    /// @dev Optimized for common case where intermediate doesn't overflow
    function mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        require(denominator != 0, "FixedPoint: division by zero");

        uint256 result = mulDivDown(x, y, denominator);
        if (mulmod(x, y, denominator) != 0) {
            result += 1;
        }
        return result;
    }

    // ========== RAY Operations (27 decimals) ==========

    /// @notice Multiply two RAY values, rounding down
    /// @param x First operand in RAY
    /// @param y Second operand in RAY
    /// @return Result in RAY, rounded down
    function mulRayDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / RAY;
    }

    /// @notice Multiply two RAY values, rounding up
    /// @param x First operand in RAY
    /// @param y Second operand in RAY
    /// @return Result in RAY, rounded up
    function mulRayUp(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 prod = x * y;
        return prod == 0 ? 0 : ((prod - 1) / RAY) + 1;
    }

    /// @notice Divide x by y in RAY precision, rounding down
    /// @param x Numerator in RAY
    /// @param y Denominator in RAY
    /// @return Result in RAY, rounded down
    function divRayDown(uint256 x, uint256 y) internal pure returns (uint256) {
        require(y != 0, "FixedPoint: division by zero");
        return (x * RAY) / y;
    }

    /// @notice Divide x by y in RAY precision, rounding up
    /// @param x Numerator in RAY
    /// @param y Denominator in RAY
    /// @return Result in RAY, rounded up
    function divRayUp(uint256 x, uint256 y) internal pure returns (uint256) {
        require(y != 0, "FixedPoint: division by zero");
        uint256 prod = x * RAY;
        return ((prod + y - 1) / y);
    }

    // ========== Conversion Helpers ==========

    /// @notice Convert RAY to WAD (27 decimals to 18 decimals), rounding down
    /// @param ray Value in RAY precision
    /// @return Value in WAD precision, rounded down
    function rayToWadDown(uint256 ray) internal pure returns (uint256) {
        return ray / 1e9;
    }

    /// @notice Convert RAY to WAD, rounding up
    /// @param ray Value in RAY precision
    /// @return Value in WAD precision, rounded up
    function rayToWadUp(uint256 ray) internal pure returns (uint256) {
        return (ray + 1e9 - 1) / 1e9;
    }

    /// @notice Convert WAD to RAY (18 decimals to 27 decimals)
    /// @param wad Value in WAD precision
    /// @return Value in RAY precision
    function wadToRay(uint256 wad) internal pure returns (uint256) {
        return wad * 1e9;
    }

    // ========== Utility Functions ==========

    /// @notice Calculate average of two WAD values
    /// @param x First value in WAD
    /// @param y Second value in WAD
    /// @return Average in WAD, rounded down
    function avgWad(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x + y) / 2;
    }

    /// @notice Calculate weighted average: (x * weightX + y * weightY) / (weightX + weightY)
    /// @param x First value
    /// @param y Second value
    /// @param weightX Weight for x (in WAD)
    /// @param weightY Weight for y (in WAD)
    /// @return Weighted average, rounded down
    function weightedAvg(uint256 x, uint256 y, uint256 weightX, uint256 weightY)
        internal
        pure
        returns (uint256)
    {
        uint256 totalWeight = weightX + weightY;
        require(totalWeight != 0, "FixedPoint: zero weight");
        return mulDivDown(x, weightX, totalWeight) + mulDivDown(y, weightY, totalWeight);
    }

    /// @notice Calculate power using binary exponentiation (x^n in WAD)
    /// @param x Base in WAD
    /// @param n Exponent (integer)
    /// @return Result in WAD
    /// @dev Uses unchecked for gas optimization since overflow is intentionally handled
    function powWad(uint256 x, uint256 n) internal pure returns (uint256) {
        if (n == 0) return WAD;
        if (x == 0) return 0;

        uint256 result = WAD;
        uint256 base = x;

        unchecked {
            while (n > 0) {
                if (n & 1 != 0) {
                    result = mulWadDown(result, base);
                }
                base = mulWadDown(base, base);
                n >>= 1;
            }
        }

        return result;
    }

    /// @notice Square root in WAD precision (Babylonian method)
    /// @param x Value in WAD
    /// @return Square root in WAD
    function sqrtWad(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;

        // Start with a reasonable initial guess
        uint256 z = (x + WAD) / 2;
        uint256 y = x;

        // Iterate until convergence (max 10 iterations is enough for 256-bit)
        unchecked {
            while (z < y) {
                y = z;
                z = (divWadDown(x, z) + z) / 2;
            }
        }

        return y;
    }

    // ========== Comparison Helpers ==========

    /// @notice Check if two WAD values are approximately equal within tolerance
    /// @param x First value in WAD
    /// @param y Second value in WAD
    /// @param tolerance Maximum difference allowed (in WAD)
    /// @return True if |x - y| <= tolerance
    function nearEqWad(uint256 x, uint256 y, uint256 tolerance) internal pure returns (bool) {
        uint256 diff = x > y ? x - y : y - x;
        return diff <= tolerance;
    }
}
