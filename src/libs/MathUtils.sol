// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MathUtils
/// @notice General-purpose math utility functions
/// @dev Protocol-agnostic helpers for common mathematical operations
///      All functions are safe from overflow in Solidity >=0.8.0
library MathUtils {
    // ========== Min/Max Operations ==========

    /// @notice Return the minimum of two values
    /// @param a First value
    /// @param b Second value
    /// @return Minimum of a and b
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice Return the maximum of two values
    /// @param a First value
    /// @param b Second value
    /// @return Maximum of a and b
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /// @notice Return the minimum of three values
    /// @param a First value
    /// @param b Second value
    /// @param c Third value
    /// @return Minimum of a, b, and c
    function min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return min(min(a, b), c);
    }

    /// @notice Return the maximum of three values
    /// @param a First value
    /// @param b Second value
    /// @param c Third value
    /// @return Maximum of a, b, and c
    function max3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return max(max(a, b), c);
    }

    // ========== Clamping & Bounding ==========

    /// @notice Clamp value between lower and upper bounds
    /// @param value Value to clamp
    /// @param lower Lower bound (inclusive)
    /// @param upper Upper bound (inclusive)
    /// @return Clamped value
    /// @dev Returns lower if value < lower, upper if value > upper, otherwise value
    function bound(uint256 value, uint256 lower, uint256 upper) internal pure returns (uint256) {
        require(lower <= upper, "MathUtils: invalid bounds");
        return min(max(value, lower), upper);
    }

    /// @notice Check if value is within bounds
    /// @param value Value to check
    /// @param lower Lower bound (inclusive)
    /// @param upper Upper bound (inclusive)
    /// @return True if lower <= value <= upper
    function isInBounds(uint256 value, uint256 lower, uint256 upper) internal pure returns (bool) {
        return value >= lower && value <= upper;
    }

    // ========== Average Operations ==========

    /// @notice Calculate average of two values without overflow
    /// @param a First value
    /// @param b Second value
    /// @return Average, rounded down
    /// @dev Uses (a & b) + (a ^ b) / 2 to prevent overflow
    function avg(uint256 a, uint256 b) internal pure returns (uint256) {
        // Overflow-safe average: (a + b) / 2 = (a & b) + (a ^ b) / 2
        return (a & b) + (a ^ b) / 2;
    }

    /// @notice Calculate average of three values
    /// @param a First value
    /// @param b Second value
    /// @param c Third value
    /// @return Average, rounded down
    function avg3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a + b + c) / 3;
    }

    /// @notice Calculate weighted average of two values
    /// @param a First value
    /// @param b Second value
    /// @param weightA Weight for a (out of total weightA + weightB)
    /// @param weightB Weight for b (out of total weightA + weightB)
    /// @return Weighted average, rounded down
    function weightedAvg(uint256 a, uint256 b, uint256 weightA, uint256 weightB)
        internal
        pure
        returns (uint256)
    {
        uint256 total = weightA + weightB;
        require(total != 0, "MathUtils: zero weight");
        return (a * weightA + b * weightB) / total;
    }

    // ========== Absolute Difference ==========

    /// @notice Calculate absolute difference between two values
    /// @param a First value
    /// @param b Second value
    /// @return |a - b|
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @notice Calculate percentage difference between two values (in bps)
    /// @param a First value
    /// @param b Second value
    /// @return Percentage difference in basis points (10000 = 100%)
    /// @dev Returns relative to smaller value. Returns 0 if a == b.
    function percentDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == b) return 0;
        uint256 diff = absDiff(a, b);
        uint256 base = min(a, b);
        if (base == 0) return type(uint256).max; // Infinite difference
        return (diff * 10000) / base;
    }

    // ========== Comparison with Tolerance ==========

    /// @notice Check if two values are approximately equal within absolute tolerance
    /// @param a First value
    /// @param b Second value
    /// @param tolerance Maximum absolute difference allowed
    /// @return True if |a - b| <= tolerance
    function nearEq(uint256 a, uint256 b, uint256 tolerance) internal pure returns (bool) {
        return absDiff(a, b) <= tolerance;
    }

    /// @notice Check if two values are approximately equal within relative tolerance (in bps)
    /// @param a First value
    /// @param b Second value
    /// @param toleranceBps Tolerance in basis points (100 = 1%)
    /// @return True if percent difference <= toleranceBps
    function nearEqBps(uint256 a, uint256 b, uint256 toleranceBps) internal pure returns (bool) {
        return percentDiff(a, b) <= toleranceBps;
    }

    // ========== Saturating Arithmetic ==========

    /// @notice Saturating addition (caps at max uint256 instead of reverting)
    /// @param a First value
    /// @param b Second value
    /// @return Sum, capped at type(uint256).max
    /// @dev Returns type(uint256).max on overflow instead of reverting
    function saturatingAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            uint256 c = a + b;
            return c < a ? type(uint256).max : c;
        }
    }

    /// @notice Saturating subtraction (floors at 0 instead of reverting)
    /// @param a Minuend
    /// @param b Subtrahend
    /// @return Difference, floored at 0
    /// @dev Returns 0 on underflow instead of reverting
    function saturatingSub(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            return a > b ? a - b : 0;
        }
    }

    /// @notice Saturating multiplication (caps at max uint256)
    /// @param a First value
    /// @param b Second value
    /// @return Product, capped at type(uint256).max
    function saturatingMul(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            if (a == 0) return 0;
            uint256 c = a * b;
            return c / a != b ? type(uint256).max : c;
        }
    }

    // ========== Division with Rounding ==========

    /// @notice Divide and round up
    /// @param a Numerator
    /// @param b Denominator
    /// @return Quotient, rounded up
    /// @dev (a + b - 1) / b
    function divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "MathUtils: division by zero");
        return (a + b - 1) / b;
    }

    /// @notice Divide and round down (standard division)
    /// @param a Numerator
    /// @param b Denominator
    /// @return Quotient, rounded down
    function divDown(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "MathUtils: division by zero");
        return a / b;
    }

    /// @notice Divide and round to nearest (standard rounding)
    /// @param a Numerator
    /// @param b Denominator
    /// @return Quotient, rounded to nearest
    /// @dev Rounds up if remainder >= b/2
    function divRound(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "MathUtils: division by zero");
        return (a + b / 2) / b;
    }

    // ========== Modulo Operations ==========

    /// @notice Check if a is divisible by b (no remainder)
    /// @param a Dividend
    /// @param b Divisor
    /// @return True if a % b == 0
    function isDivisibleBy(uint256 a, uint256 b) internal pure returns (bool) {
        require(b != 0, "MathUtils: modulo by zero");
        return a % b == 0;
    }

    /// @notice Round value down to nearest multiple of step
    /// @param value Value to round
    /// @param step Step size
    /// @return Rounded value
    /// @dev Example: roundDownToMultiple(123, 10) = 120
    function roundDownToMultiple(uint256 value, uint256 step) internal pure returns (uint256) {
        require(step != 0, "MathUtils: step cannot be zero");
        // Division then multiplication is intentional to round down to nearest multiple
        // forge-lint: disable-next-line(divide-before-multiply)
        return (value / step) * step;
    }

    /// @notice Round value up to nearest multiple of step
    /// @param value Value to round
    /// @param step Step size
    /// @return Rounded value
    /// @dev Example: roundUpToMultiple(123, 10) = 130
    function roundUpToMultiple(uint256 value, uint256 step) internal pure returns (uint256) {
        require(step != 0, "MathUtils: step cannot be zero");
        return divUp(value, step) * step;
    }

    // ========== Power of 2 Operations ==========

    /// @notice Check if value is a power of 2
    /// @param value Value to check
    /// @return True if value is a power of 2
    function isPowerOfTwo(uint256 value) internal pure returns (bool) {
        return value != 0 && (value & (value - 1)) == 0;
    }

    /// @notice Round up to next power of 2
    /// @param value Value to round
    /// @return Next power of 2 >= value
    /// @dev Returns value if already power of 2
    function nextPowerOfTwo(uint256 value) internal pure returns (uint256) {
        if (value == 0) return 1;
        if (isPowerOfTwo(value)) return value;

        value--;
        value |= value >> 1;
        value |= value >> 2;
        value |= value >> 4;
        value |= value >> 8;
        value |= value >> 16;
        value |= value >> 32;
        value |= value >> 64;
        value |= value >> 128;
        return value + 1;
    }

    // ========== Byte Operations ==========

    /// @notice Count number of leading zeros in a uint256
    /// @param value Value to analyze
    /// @return Number of leading zero bits
    function countLeadingZeros(uint256 value) internal pure returns (uint256) {
        if (value == 0) return 256;

        uint256 n = 0;
        if (value <= type(uint128).max) {
            n += 128;
            value <<= 128;
        }
        if (value <= type(uint64).max << 128) {
            n += 64;
            value <<= 64;
        }
        if (value <= type(uint32).max << 192) {
            n += 32;
            value <<= 32;
        }
        if (value <= type(uint16).max << 224) {
            n += 16;
            value <<= 16;
        }
        if (value <= type(uint8).max << 240) {
            n += 8;
            value <<= 8;
        }
        if (value <= 0xF << 248) {
            n += 4;
            value <<= 4;
        }
        if (value <= 0x3 << 252) {
            n += 2;
            value <<= 2;
        }
        if (value <= 0x1 << 254) {
            n += 1;
        }
        return n;
    }

    /// @notice Calculate log2 of value (floor)
    /// @param value Value to calculate log2 of
    /// @return Floor of log2(value)
    /// @dev Returns 0 for value == 1, reverts for value == 0
    function log2(uint256 value) internal pure returns (uint256) {
        require(value != 0, "MathUtils: log2(0) undefined");
        return 255 - countLeadingZeros(value);
    }

    // ========== Sum & Product ==========

    /// @notice Calculate sum of array
    /// @param values Array of values
    /// @return Sum of all values
    function sum(uint256[] memory values) internal pure returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < values.length; i++) {
            total += values[i];
        }
        return total;
    }

    /// @notice Calculate product of array
    /// @param values Array of values
    /// @return Product of all values
    /// @dev Returns 0 if any value is 0
    function product(uint256[] memory values) internal pure returns (uint256) {
        if (values.length == 0) return 0;

        uint256 result = 1;
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] == 0) return 0;
            result *= values[i];
        }
        return result;
    }

    // ========== Ternary Operations ==========

    /// @notice Ternary operation: return a if condition is true, else b
    /// @param condition Boolean condition
    /// @param a Value to return if true
    /// @param b Value to return if false
    /// @return a if condition, else b
    function ternary(bool condition, uint256 a, uint256 b) internal pure returns (uint256) {
        return condition ? a : b;
    }

    /// @notice Return a if a > 0, else b (non-zero selector)
    /// @param a First value
    /// @param b Fallback value
    /// @return a if a != 0, else b
    function defaultIfZero(uint256 a, uint256 b) internal pure returns (uint256) {
        return a != 0 ? a : b;
    }

    // ========== Safe Casting (aliases to OpenZeppelin) ==========

    /// @notice Cast uint256 to uint128, reverting on overflow
    /// @param value Value to cast
    /// @return Result as uint128
    function toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "MathUtils: uint128 overflow");
        // casting to uint128 is safe because overflow is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    /// @notice Cast uint256 to uint64, reverting on overflow
    /// @param value Value to cast
    /// @return Result as uint64
    function toUint64(uint256 value) internal pure returns (uint64) {
        require(value <= type(uint64).max, "MathUtils: uint64 overflow");
        // casting to uint64 is safe because overflow is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(value);
    }

    /// @notice Cast uint256 to uint32, reverting on overflow
    /// @param value Value to cast
    /// @return Result as uint32
    function toUint32(uint256 value) internal pure returns (uint32) {
        require(value <= type(uint32).max, "MathUtils: uint32 overflow");
        // casting to uint32 is safe because overflow is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(value);
    }

    /// @notice Cast uint256 to uint16, reverting on overflow
    /// @param value Value to cast
    /// @return Result as uint16
    function toUint16(uint256 value) internal pure returns (uint16) {
        require(value <= type(uint16).max, "MathUtils: uint16 overflow");
        // casting to uint16 is safe because overflow is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(value);
    }

    /// @notice Cast uint256 to uint8, reverting on overflow
    /// @param value Value to cast
    /// @return Result as uint8
    function toUint8(uint256 value) internal pure returns (uint8) {
        require(value <= type(uint8).max, "MathUtils: uint8 overflow");
        // casting to uint8 is safe because overflow is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(value);
    }
}
