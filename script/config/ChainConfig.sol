// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ChainConfig -- parametrized per-chain deploy config (Arbitrum / Base / Ethereum)
/// @notice Single source of truth for chain-specific addresses/params consumed by script/Deploy*.s.sol.
///         Replaces the old pattern of each deploy script independently hardcoding
///         `ARBITRUM_ONE_CHAIN_ID = 42161` plus Arbitrum-only USDC/Aave/Morpho/oracle addresses.
/// @dev Addresses cross-checked against bgd-labs/aave-address-book, Circle's official USDC docs,
///      and Chainlink's reference-data-directory feed listing as of 2026-08-21.
///      MUST be independently re-verified before any real mainnet deployment -- a wrong address
///      here is a fund-loss bug, not a cosmetic one.
library ChainConfig {
    uint256 internal constant ARBITRUM_ONE = 42161;
    uint256 internal constant BASE_MAINNET = 8453;
    uint256 internal constant ETHEREUM_MAINNET = 1;

    error UnsupportedChain(uint256 chainId);

    struct Config {
        uint256 chainId;
        string chainName;
        address usdc;
        address chainlinkUsdcUsdFeed;
        uint256 oracleStaleness; // Chainlink feed heartbeat, seconds
        address aavePool;
        address aaveDataProvider;
        // address(0) = no vetted default for this chain; deploy scripts must require
        // an explicit MORPHO_VAULT env var instead of silently picking one.
        address morphoVaultDefault;
        uint16 morphoSlippageBps;
    }

    /// @notice Resolve config for `block.chainid`. Reverts on any unsupported chain.
    function current() internal view returns (Config memory) {
        return get(block.chainid);
    }

    /// @notice Resolve config for an explicit chain id. Reverts on any unsupported chain.
    function get(uint256 chainId) internal pure returns (Config memory) {
        if (chainId == ARBITRUM_ONE) return _arbitrum();
        if (chainId == BASE_MAINNET) return _base();
        if (chainId == ETHEREUM_MAINNET) return _ethereum();
        revert UnsupportedChain(chainId);
    }

    function _arbitrum() private pure returns (Config memory) {
        return Config({
            chainId: ARBITRUM_ONE,
            chainName: "Arbitrum One",
            usdc: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            chainlinkUsdcUsdFeed: 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3,
            oracleStaleness: 86400,
            aavePool: 0x794a61358D6845594F94dc1DB02A252b5b4814aD,
            aaveDataProvider: 0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654,
            morphoVaultDefault: 0x7e97fa6893871A2751B5fE961978DCCb2c201E65, // Gauntlet USDC Core
            morphoSlippageBps: 5
        });
    }

    function _base() private pure returns (Config memory) {
        return Config({
            chainId: BASE_MAINNET,
            chainName: "Base",
            usdc: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            chainlinkUsdcUsdFeed: 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B,
            oracleStaleness: 86400,
            aavePool: 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5,
            aaveDataProvider: 0x0F43731EB8d45A581f4a36DD74F5f358bc90C73A,
            morphoVaultDefault: address(0), // no vetted default -- MORPHO_VAULT env var required
            morphoSlippageBps: 5
        });
    }

    function _ethereum() private pure returns (Config memory) {
        return Config({
            chainId: ETHEREUM_MAINNET,
            chainName: "Ethereum Mainnet",
            usdc: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            chainlinkUsdcUsdFeed: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6,
            oracleStaleness: 86400,
            aavePool: 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2,
            aaveDataProvider: 0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD,
            morphoVaultDefault: address(0), // no vetted default -- MORPHO_VAULT env var required
            morphoSlippageBps: 5
        });
    }
}
