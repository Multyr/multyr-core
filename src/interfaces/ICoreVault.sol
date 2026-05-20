// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICoreVault
/// @notice Minimal interface for CoreVault-specific functions (not in ERC4626/ERC20)
/// @dev Does NOT include:
///      - ERC4626 functions (use IERC4626)
///      - ERC20 functions (use IERC20)
///      - Module routed functions (use IQueueModule, IAdminModule, LiquidityOpsModule)
///      - canDeploy / deployToStrategies / deployToStrategiesWithPlan are routed to
///        LiquidityOpsModule via Diamond-lite fallback (not declared here to avoid
///        CoreVault being marked abstract). VaultUpkeep uses its own local interface.
interface ICoreVault {
    // ═══════════════════════════════════════════════════════════════════════════════
    // ERC4626 EXTENSIONS (unique to CoreVault)
    // ═══════════════════════════════════════════════════════════════════════════════

    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);

    /// @notice Returns breakdown of total assets for gas-efficient external queries
    /// @return nav Total assets (hot + strat + warm)
    /// @return hot Idle assets in vault
    /// @return warm Assets in warm buffer adapters
    function totalAssetsBreakdown() external view returns (uint256 nav, uint256 hot, uint256 warm);

    // ═══════════════════════════════════════════════════════════════════════════════
    // OPS HINTS (for keeper bots)
    // ═══════════════════════════════════════════════════════════════════════════════

    function canRealize() external view returns (bool);

    // ═══════════════════════════════════════════════════════════════════════════════
    // OPS (native, not routed)
    // ═══════════════════════════════════════════════════════════════════════════════

    function realizeForReserveAndOps(uint256 maxAmount) external;

    // ═══════════════════════════════════════════════════════════════════════════════
    // MODULE PROCESSOR FUNCTIONS (AUDIT-GRADE)
    // Called by authorized modules (via delegatecall or direct call if authorized)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Mint shares (callable by authorized modules only)
    function processorMint(address to, uint256 amount) external;

    /// @notice Burn shares (callable by authorized modules only)
    function processorBurn(address from, uint256 amount) external;

    /// @notice Transfer shares internally (callable by authorized modules only)
    function processorTransfer(address from, address to, uint256 amount) external;

    /// @notice Spend allowance (callable by authorized modules only)
    function processorSpendAllowance(address owner_, address spender, uint256 amount) external;

    // NOTE: ERC4626 view functions (previewDeposit, previewMint, previewWithdraw,
    // previewRedeem, convertToAssets, convertToShares) are inherited from IERC4626.
    // balanceOf is inherited from IERC20.
    // Do NOT duplicate them here to avoid override conflicts.
}
