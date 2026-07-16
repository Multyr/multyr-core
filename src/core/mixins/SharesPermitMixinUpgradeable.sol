// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/**
 * @title SharesPermitMixinUpgradeable
 * @notice Upgradeable version - Abilita EIP-2612 sul token shares (ERC20Permit sulle shares).
 */
abstract contract SharesPermitMixinUpgradeable is ERC20PermitUpgradeable {
    /**
     * @notice Initialize the ERC20Permit (replaces constructor)
     * @param shareName Name for the permit domain separator
     */
    function _initializeSharesPermit(string memory shareName) internal onlyInitializing {
        __ERC20Permit_init(shareName);
    }
}
