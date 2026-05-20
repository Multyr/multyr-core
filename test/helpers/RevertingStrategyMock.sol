// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RevertingStrategyMock — IStrategy-compatible mock with toggleable revert
/// @notice Used for multi-strategy hardening tests. Implements the IStrategy interface
///         expected by StrategyRouter. Can be toggled to revert on withdraw.
contract RevertingStrategyMock {
    using SafeERC20 for IERC20;

    address public immutable underlyingAsset;
    bool public shouldRevertOnWithdraw;
    bool public shouldRevertOnDeposit;

    string public constant name = "RevertingStrategyMock";

    constructor(address _asset) {
        underlyingAsset = _asset;
    }

    function asset() external view returns (address) {
        return underlyingAsset;
    }

    function totalAssets() public view returns (uint256) {
        return IERC20(underlyingAsset).balanceOf(address(this));
    }

    function deposit(uint256 amount) external returns (uint256 received) {
        if (shouldRevertOnDeposit) revert("RevertingStrategyMock: deposit reverted");
        return amount;
    }

    function withdraw(uint256 amount, address to) external returns (uint256 withdrawn) {
        if (shouldRevertOnWithdraw) revert("RevertingStrategyMock: withdraw reverted");
        uint256 bal = IERC20(underlyingAsset).balanceOf(address(this));
        withdrawn = amount <= bal ? amount : bal;
        if (withdrawn > 0) {
            IERC20(underlyingAsset).safeTransfer(to, withdrawn);
        }
    }

    function withdrawAll(address to) external returns (uint256 withdrawn) {
        if (shouldRevertOnWithdraw) revert("RevertingStrategyMock: withdrawAll reverted");
        withdrawn = IERC20(underlyingAsset).balanceOf(address(this));
        if (withdrawn > 0) {
            IERC20(underlyingAsset).safeTransfer(to, withdrawn);
        }
    }

    function harvest() external pure returns (int256 pnl, uint256 realized) {
        return (0, 0);
    }

    function setActive(bool) external pure {}

    function isActive() external pure returns (bool) {
        return true;
    }

    // ---- Toggle functions ----

    function setRevertOnWithdraw(bool _revert) external {
        shouldRevertOnWithdraw = _revert;
    }

    function setRevertOnDeposit(bool _revert) external {
        shouldRevertOnDeposit = _revert;
    }
}
