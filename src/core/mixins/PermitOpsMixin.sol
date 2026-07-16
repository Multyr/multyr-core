// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title PermitOpsMixin
 * @notice Convenience entrypoints to deposit/withdraw with an underlying EIP-2612 permit in a single tx.
 * @dev Does not add storage. It expects ERC4626-like functions to be present in the final contract.
 */
interface IERC20PermitLike {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

abstract contract PermitOpsMixin {
    // ---- Functions expected from ERC4626 ----
    function asset() public view virtual returns (address);
    function deposit(uint256 assets, address receiver) public virtual returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        returns (uint256);
    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        returns (uint256);

    /**
     * @notice Approve underlying via EIP-2612 signature and deposit in a single call.
     */
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 shares) {
        IERC20PermitLike(asset()).permit(msg.sender, address(this), assets, deadline, v, r, s);
        shares = deposit(assets, receiver);
    }

    /**
     * @notice Withdraw using the standard ERC4626 flow. Included for symmetry; shares permits are handled by SharesPermitMixin.
     */
    function withdrawWithPermit(uint256 assets, address receiver)
        external
        returns (uint256 assetsOut)
    {
        assetsOut = withdraw(assets, receiver, msg.sender);
    }

    /**
     * @notice Redeem using the standard ERC4626 flow. Included for symmetry.
     */
    function redeemWithPermit(uint256 shares, address receiver)
        external
        returns (uint256 assetsOut)
    {
        require(msg.sender == receiver, "ONLY_RECEIVER");
        assetsOut = redeem(shares, receiver, msg.sender);
    }

    /**
     * @notice Withdraw with an EIP-2612 permit on vault shares authorizing msg.sender to spend owner's shares.
     *         The permit is issued for the exact number of shares previewed for the withdrawal.
     */
    function withdrawWithPermit(
        uint256 assets,
        address receiver,
        address owner_,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 shares) {
        uint256 neededShares = IERC4626(address(this)).previewWithdraw(assets);
        IERC20PermitLike(address(this)).permit(owner_, msg.sender, neededShares, deadline, v, r, s);
        shares = withdraw(assets, receiver, owner_);
    }
}
