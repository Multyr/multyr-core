// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IWarmAdapter - Interfaccia adapter T+0 (Aave/Morpho no-borrow)
interface IWarmAdapter {
    function asset() external view returns (address);
    function coreVault() external view returns (address);
    function totalAssets() external view returns (uint256);

    /// @notice Deposita `amount` di underlying, pullando dal CoreVault.
    /// @dev Solo il controller (BufferManager) deve poter chiamare.
    ///      L'adapter fa transferFrom(coreVault, adapter, amount) internamente.
    function deposit(uint256 amount) external returns (uint256 received);

    /// @notice Ritira `amount` di underlying dal protocollo verso `to`.
    /// @dev Solo il controller (BufferManager) deve poter chiamare.
    function withdraw(uint256 amount, address to) external returns (uint256 sent);
}
