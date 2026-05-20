// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IWarmAdapter } from "../../interfaces/IWarmAdapter.sol";

// ---------- Minimal ----------
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC4626 {
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);
}

/// @title MorphoVaultWarmAdapter_USDC
/// @notice Adapter T+0 su Morpho **Vault ERC-4626** (loan token = USDC nativo).
/// @dev L'adapter pulla USDC dal CoreVault via transferFrom. Per uscire, withdraw(amount,to).
contract MorphoVaultWarmAdapter_USDC is IWarmAdapter {
    // -------- Costanti --------
    address public constant UNDERLYING_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // -------- Immutable --------
    address public immutable controller; // BufferManager
    address public immutable coreVault; // CoreVault (source of funds)
    IERC20 public immutable USDC;
    IERC4626 public immutable VAULT;

    // slippage shares per prelievi (bps); es. 5 = 0.05%
    uint16 public immutable withdrawSlippageBps;

    // -------- Eventi --------
    event Deposited(uint256 assetsIn, uint256 sharesOut);
    event Withdrawn(uint256 assetsOut, uint256 sharesIn, address to);
    event IdleAssetSwept(uint256 amount);

    // -------- Errori --------
    error NotController();
    error ZeroAmount();
    error ZeroCoreVault();
    error WrongAsset();
    error ApproveFailed();
    error TransferFromFailed();

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    constructor(
        address _controller,
        address _coreVault,
        address _vault,
        uint16 _withdrawSlippageBps
    ) {
        if (_coreVault == address(0)) revert ZeroCoreVault();
        controller = _controller;
        coreVault = _coreVault;
        VAULT = IERC4626(_vault);
        USDC = IERC20(UNDERLYING_USDC);
        withdrawSlippageBps = _withdrawSlippageBps;

        if (VAULT.asset() != UNDERLYING_USDC) revert WrongAsset();
        if (!USDC.approve(_vault, type(uint256).max)) revert ApproveFailed();
    }

    // -------- IWarmAdapter --------
    function asset() external pure returns (address) {
        return UNDERLYING_USDC;
    }

    function totalAssets() external view returns (uint256) {
        return investedAssets() + idleAssetBalance();
    }

    function investedAssets() public view returns (uint256) {
        uint256 shares = _sharesBalance();
        if (shares == 0) return 0;
        return VAULT.convertToAssets(shares);
    }

    function idleAssetBalance() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    function sweepIdleAssetToVault() external onlyController {
        uint256 bal = USDC.balanceOf(address(this));
        if (bal > 0) {
            require(USDC.transfer(coreVault, bal), "sweep failed");
            emit IdleAssetSwept(bal);
        }
    }

    /// @notice Deposita `amount` di USDC, pullando dal CoreVault.
    /// @dev Richiede che CoreVault abbia approvato questo adapter.
    function deposit(uint256 amount) external onlyController returns (uint256 received) {
        if (amount == 0) revert ZeroAmount();

        // Pull USDC from CoreVault
        if (!USDC.transferFrom(coreVault, address(this), amount)) revert TransferFromFailed();

        received = VAULT.deposit(amount, address(this));
        emit Deposited(amount, received);
    }

    /// @notice Ritira `amount` di USDC e li invia a `to`.
    function withdraw(uint256 amount, address to) external onlyController returns (uint256 sent) {
        if (amount == 0) revert ZeroAmount();
        uint256 sharesNeeded = VAULT.previewWithdraw(amount);
        if (withdrawSlippageBps > 0) {
            sharesNeeded = sharesNeeded + (sharesNeeded * withdrawSlippageBps) / 1e4;
        }
        uint256 sharesBal = _sharesBalance();
        if (sharesNeeded > sharesBal) sharesNeeded = sharesBal;
        if (sharesNeeded == 0) return 0;

        sent = VAULT.redeem(sharesNeeded, to, address(this));
        emit Withdrawn(sent, sharesNeeded, to);
    }

    // -------- Internals --------
    function _sharesBalance() internal view returns (uint256) {
        (bool ok, bytes memory data) =
            address(VAULT).staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
