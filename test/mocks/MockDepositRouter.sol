// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockReferralBinding } from "./MockReferralBinding.sol";

interface IVaultDeposit {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

/// @dev Drop-in test double for DepositRouter. Bypasses Permit2 entirely.
///      Users must approve this contract for the asset token (not Permit2).
///      Constructor signature matches DepositRouter for transparent swap in setUp.
contract MockDepositRouter {
    IERC20 public immutable asset;
    address public immutable vault;
    MockReferralBinding public immutable referralBinding;

    constructor(address _vault, address _asset, address /* permit2 */, address _referralBinding) {
        vault = _vault;
        asset = IERC20(_asset);
        referralBinding = MockReferralBinding(_referralBinding);
        IERC20(_asset).approve(_vault, type(uint256).max);
    }

    function depositWithPermit2Transfer(
        uint256 amount,
        address referrer,
        uint256, /* nonce */
        uint256, /* deadline */
        bytes calldata /* sig */
    ) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), amount);
        shares = IVaultDeposit(vault).deposit(amount, msg.sender);
        if (referrer != address(0)) referralBinding.bind(msg.sender, referrer);
    }

    function depositWithPermit2Allowance(
        uint256 amount,
        address referrer,
        uint160, /* allowanceAmount */
        uint48, /* expiry */
        uint48, /* nonce */
        uint256, /* deadline */
        bytes calldata /* sig */
    ) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), amount);
        shares = IVaultDeposit(vault).deposit(amount, msg.sender);
        if (referrer != address(0)) referralBinding.bind(msg.sender, referrer);
    }
}
