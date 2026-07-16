// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title SharesPermitMixin
 * @notice Abilita EIP-2612 sul token shares (ERC20Permit sulle shares).
 */
abstract contract SharesPermitMixin is ERC20Permit {
    constructor(string memory shareName) ERC20Permit(shareName) { }
}
