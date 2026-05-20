// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IStrategyVaultLike {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function withdrawableAssets() external view returns (uint256);
    function deposit(uint256 assets) external returns (uint256 received);
    function withdraw(uint256 assets, address receiver) external returns (uint256 withdrawn);
    function harvest(address receiver) external returns (uint256 realized);
}

contract StrategyMock is IStrategyVaultLike {
    using SafeERC20 for IERC20;
    address public immutable token;

    constructor(address _asset) {
        token = _asset;
    }

    function asset() external view returns (address) {
        return token;
    }

    function totalAssets() public view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function withdrawableAssets() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function deposit(uint256 assets) external pure returns (uint256 received) {
        // Assets are already transferred by Core directly to this contract
        // Just acknowledge the deposit (no transfer needed)
        return assets; // Return the amount as received
    }

    function withdraw(uint256 assets, address receiver) external returns (uint256 withdrawn) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        withdrawn = assets <= bal ? assets : bal;
        if (withdrawn > 0) {
            IERC20(token).safeTransfer(receiver, withdrawn);
        }
    }

    function harvest(address) external pure returns (uint256) {
        return 0;
    }
}
