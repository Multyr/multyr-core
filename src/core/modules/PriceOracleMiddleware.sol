// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPriceOracleMiddleware } from "../../interfaces/IPriceOracleMiddleware.sol";

/**
 * @title PriceOracleMiddleware
 * @notice Price oracle middleware with Chainlink integration and freshness checks
 * @dev Normalizes prices to 18 decimals (WAD) and validates staleness
 * @dev For FASE 1, this is a simplified implementation with Chainlink stub support
 */
contract PriceOracleMiddleware is IPriceOracleMiddleware {
    /* ========== STATE VARIABLES ========== */

    /// @notice Contract owner (typically Timelock)
    address public owner;

    /// @notice Oracle feed configuration per asset
    struct FeedConfig {
        address feed; // Chainlink aggregator address
        uint256 maxStaleness; // Maximum allowed staleness (seconds)
        bool isSet; // True if feed is configured
    }

    /// @notice Mapping from asset to oracle feed config
    mapping(address => FeedConfig) public feeds;

    /* ========== CONSTANTS ========== */

    /// @notice Minimum staleness threshold (1 minute)
    uint256 public constant MIN_STALENESS = 1 minutes;

    /// @notice Maximum staleness threshold (24 hours)
    uint256 public constant MAX_STALENESS = 24 hours;

    /// @notice Default staleness for new feeds (1 hour)
    uint256 public constant DEFAULT_STALENESS = 1 hours;

    /* ========== MODIFIERS ========== */

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    /**
     * @notice Initialize the oracle middleware
     * @param owner_ Contract owner address
     */
    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /**
     * @notice Set oracle feed for an asset
     * @param asset Asset address (e.g., USDC)
     * @param feed Chainlink aggregator feed address
     * @param maxStaleness Maximum allowed staleness in seconds
     */
    function setOracleFeed(address asset, address feed, uint256 maxStaleness) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (feed == address(0)) revert ZeroAddress();
        if (maxStaleness < MIN_STALENESS || maxStaleness > MAX_STALENESS) {
            revert InvalidStaleness();
        }

        // SECURITY: Validate that feed is actually a Chainlink aggregator
        _validateOracleFeed(feed);

        feeds[asset] = FeedConfig({ feed: feed, maxStaleness: maxStaleness, isSet: true });

        emit OracleFeedSet(asset, feed, maxStaleness);
    }

    /**
     * @notice Validate that an address implements IChainlinkAggregator interface
     * @param feed Address to validate
     * @dev Attempts to call decimals() and latestRoundData() to ensure feed is valid
     */
    function _validateOracleFeed(address feed) internal view {
        try IChainlinkAggregator(feed).decimals() returns (uint8 decimals) {
            if (decimals == 0 || decimals > 18) revert InvalidPrice();
        } catch {
            revert InvalidPrice();
        }

        try IChainlinkAggregator(feed).latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // Basic sanity checks
            if (answer <= 0) revert InvalidPrice();
            if (updatedAt == 0) revert InvalidPrice();
            if (answeredInRound < roundId) revert InvalidPrice();
        } catch {
            revert InvalidPrice();
        }
    }

    /**
     * @notice Update max staleness for an asset
     * @param asset Asset address
     * @param maxStaleness New maximum staleness in seconds
     */
    function setMaxStaleness(address asset, uint256 maxStaleness) external onlyOwner {
        if (!feeds[asset].isSet) revert OracleFeedNotSet();
        if (maxStaleness < MIN_STALENESS || maxStaleness > MAX_STALENESS) {
            revert InvalidStaleness();
        }

        feeds[asset].maxStaleness = maxStaleness;
        emit MaxStalenessUpdated(asset, maxStaleness);
    }

    /**
     * @notice Transfer ownership
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Get price quote for an asset with freshness check
     * @param asset Asset address
     * @return quote Quote struct with price and metadata
     * @dev Does NOT revert on stale price, but sets quote.fresh = false
     */
    function getQuote(address asset) public view returns (Quote memory quote) {
        FeedConfig memory config = feeds[asset];
        if (!config.isSet) revert OracleFeedNotSet();

        // Get price from Chainlink feed
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(config.feed).latestRoundData();

        // Validate price
        if (answer <= 0) revert InvalidPrice();
        if (answeredInRound < roundId) revert InvalidPrice();

        // Get feed decimals
        uint8 feedDecimals = IChainlinkAggregator(config.feed).decimals();

        // Normalize price to 18 decimals (WAD)
        uint256 normalizedPrice;
        if (feedDecimals < 18) {
            normalizedPrice = uint256(answer) * (10 ** (18 - feedDecimals));
        } else if (feedDecimals > 18) {
            normalizedPrice = uint256(answer) / (10 ** (feedDecimals - 18));
        } else {
            normalizedPrice = uint256(answer);
        }

        // Check freshness
        // If updatedAt is in the future, consider it stale (shouldn't happen in production)
        bool fresh_;
        if (updatedAt > block.timestamp) {
            fresh_ = false;
        } else {
            uint256 staleness = block.timestamp - updatedAt;
            fresh_ = staleness <= config.maxStaleness;
        }

        quote = Quote({
            price: normalizedPrice,
            decimals: feedDecimals,
            lastUpdate: uint48(updatedAt),
            fresh: fresh_
        });
    }

    /**
     * @notice Get price quote and require it to be fresh
     * @param asset Asset address
     * @return quote Quote struct with fresh price
     * @dev Reverts with StalePrice if price is stale
     */
    function getQuoteFresh(address asset) external view returns (Quote memory quote) {
        quote = getQuote(asset);
        if (!quote.fresh) revert StalePrice();
    }

    /**
     * @notice Check if price for asset is fresh
     * @param asset Asset address
     * @return True if price is within staleness threshold
     */
    function isFresh(address asset) external view returns (bool) {
        if (!feeds[asset].isSet) return false;
        Quote memory quote = getQuote(asset);
        return quote.fresh;
    }

    /**
     * @notice Get oracle feed address for asset
     * @param asset Asset address
     * @return feed Chainlink feed address
     */
    function getFeed(address asset) external view returns (address feed) {
        return feeds[asset].feed;
    }

    /**
     * @notice Get max staleness for asset
     * @param asset Asset address
     * @return maxStaleness Maximum staleness in seconds
     */
    function getMaxStaleness(address asset) external view returns (uint256 maxStaleness) {
        return feeds[asset].maxStaleness;
    }
}

/**
 * @title IChainlinkAggregator
 * @notice Minimal Chainlink aggregator interface
 */
interface IChainlinkAggregator {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
