// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IPriceOracleMiddleware
 * @notice Interface for price oracle middleware with freshness checks
 * @dev Provides normalized price quotes with staleness validation
 */
interface IPriceOracleMiddleware {
    /* ========== STRUCTS ========== */

    /**
     * @notice Price quote with freshness metadata
     * @param price Price in WAD (1e18) normalized format
     * @param decimals Original decimals of the oracle feed
     * @param lastUpdate Timestamp of last oracle update
     * @param fresh True if price is within staleness threshold
     */
    struct Quote {
        uint256 price; // Normalized to 18 decimals (WAD)
        uint8 decimals; // Original feed decimals
        uint48 lastUpdate; // Last update timestamp
        bool fresh; // True if within maxStaleness
    }

    /* ========== EVENTS ========== */

    /**
     * @notice Emitted when oracle feed is registered for an asset
     * @param asset Asset address
     * @param feed Chainlink feed address
     * @param maxStaleness Maximum allowed staleness in seconds
     */
    event OracleFeedSet(address indexed asset, address indexed feed, uint256 maxStaleness);

    /**
     * @notice Emitted when max staleness is updated for an asset
     * @param asset Asset address
     * @param maxStaleness New maximum staleness in seconds
     */
    event MaxStalenessUpdated(address indexed asset, uint256 maxStaleness);

    /**
     * @notice Emitted when a stale price is detected
     * @param asset Asset address
     * @param lastUpdate Last update timestamp
     * @param staleness Age of the price in seconds
     */
    event StalePriceDetected(address indexed asset, uint256 lastUpdate, uint256 staleness);

    /* ========== ERRORS ========== */

    /// @notice Thrown when asset address is zero
    error ZeroAddress();

    /// @notice Thrown when oracle feed is not configured for asset
    error OracleFeedNotSet();

    /// @notice Thrown when oracle returns invalid price (≤ 0)
    error InvalidPrice();

    /// @notice Thrown when price data is stale
    error StalePrice();

    /// @notice Thrown when only owner can call
    error OnlyOwner();

    /// @notice Thrown when staleness parameter is invalid
    error InvalidStaleness();

    /* ========== ADMIN FUNCTIONS ========== */

    /**
     * @notice Set oracle feed for an asset
     * @param asset Asset address (e.g., USDC)
     * @param feed Chainlink aggregator feed address
     * @param maxStaleness Maximum allowed staleness in seconds
     */
    function setOracleFeed(address asset, address feed, uint256 maxStaleness) external;

    /**
     * @notice Update max staleness for an asset
     * @param asset Asset address
     * @param maxStaleness New maximum staleness in seconds
     */
    function setMaxStaleness(address asset, uint256 maxStaleness) external;

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Get price quote for an asset with freshness check
     * @param asset Asset address
     * @return quote Quote struct with price and metadata
     * @dev Reverts if feed not set or price invalid
     * @dev Does NOT revert on stale price, but sets quote.fresh = false
     */
    function getQuote(address asset) external view returns (Quote memory quote);

    /**
     * @notice Get price quote and require it to be fresh
     * @param asset Asset address
     * @return quote Quote struct with fresh price
     * @dev Reverts with StalePrice if price is stale
     */
    function getQuoteFresh(address asset) external view returns (Quote memory quote);

    /**
     * @notice Check if price for asset is fresh
     * @param asset Asset address
     * @return True if price is within staleness threshold
     */
    function isFresh(address asset) external view returns (bool);

    /**
     * @notice Get oracle feed address for asset
     * @param asset Asset address
     * @return feed Chainlink feed address
     */
    function getFeed(address asset) external view returns (address feed);

    /**
     * @notice Get max staleness for asset
     * @param asset Asset address
     * @return maxStaleness Maximum staleness in seconds
     */
    function getMaxStaleness(address asset) external view returns (uint256 maxStaleness);

    /**
     * @notice Get owner address
     * @return Owner address
     */
    function owner() external view returns (address);
}
