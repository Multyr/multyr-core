// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SkimMixin
 * @notice Recover non-underlying tokens accidentally sent to the vault.
 * @dev Access control is delegated to the final contract via _assertSkimRole().
 */
abstract contract SkimMixin {
    error SkimDenied();
    error NoBalance();
    error TransferFailed();

    event Skimmed(address indexed token, address indexed to, uint256 amount);

    function _assertSkimRole() internal view virtual;

    function _canSkim(address token) internal view virtual returns (bool) {
        // default allow; overridden in final contract to restrict
        return true;
    }

    function skim(address token, address to) external {
        _assertSkimRole();
        if (!_canSkim(token)) revert SkimDenied();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert NoBalance();
        if (!IERC20(token).transfer(to, bal)) revert TransferFailed();
        emit Skimmed(token, to, bal);
    }
}
