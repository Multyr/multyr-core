// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICoreAggregatorVaultV1 {
    // views
    function totalAssets() external view returns (uint256);
    function previewTotalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function canSettle() external view returns (bool);
    function canCrystallize() external view returns (bool);
    function canRealize() external view returns (bool);
    function queueLength() external view returns (uint256);
    function epochStart() external view returns (uint64);

    // params (read)
    function capPerEpochBps() external view returns (uint16);
    function epochWithdrawn() external view returns (uint256);

    // ops
    function processQueuedRedemptions(uint256 maxClaims) external;
    function settleFeesAndProcessQueue(uint256 maxClaims) external;
    function endEpochCrystallize() external;
    function realizeForReserveAndOps(uint256 maxAmount) external;

    // claim path (user)
    function requestClaim(bool isImmediate, uint256 shares) external;

    // deposit/mint
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function mint(uint256 shares, address receiver) external returns (uint256);
    // ERC4626 previews
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);

    // token
    function balanceOf(address) external view returns (uint256);
}

interface IVaultUpkeep {
    function checkUpkeep(bytes calldata)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}
