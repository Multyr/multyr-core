// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CoreVault } from "../../src/core/CoreVault.sol";

/// @title ModuleSetter
/// @notice Test helper per configurare moduli batch senza modificare CoreVault
/// @dev Usa address router per massima compatibilità con tipi diversi nei test
library ModuleSetter {
    /// @notice Setta multipli selectors allo stesso module e role
    /// @param router Indirizzo del CoreVault
    /// @param selectors Array di function selectors
    /// @param module Indirizzo del modulo target
    /// @param role Ruolo richiesto (uint8 - compatibile con SelectorLib e CoreVault)
    function setModulesSame(address router, bytes4[] memory selectors, address module, uint8 role)
        internal
    {
        CoreVault vault = CoreVault(payable(router));
        for (uint256 i; i < selectors.length; i++) {
            vault.setModule(selectors[i], module, role);
        }
    }
}
