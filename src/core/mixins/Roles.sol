// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract Roles {
    error NotGovernor();
    error ZeroAddress();

    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);

    address public governor;
    bool public rolesFrozen;

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    // Inizializzazione (da chiamare nel costruttore del CoreVault)
    function __rolesInit(address _governor) internal {
        if (_governor == address(0)) revert ZeroAddress();
        governor = _governor;
    }

    function setGovernor(address n) external onlyGovernor {
        require(!rolesFrozen, "FROZEN");
        if (n == address(0)) revert ZeroAddress();
        address oldGovernor = governor;
        governor = n;
        emit GovernorUpdated(oldGovernor, n);
    }

    function freezeRoles() external onlyGovernor {
        rolesFrozen = true;
    }

    // Se servono transition API stile ownership per ruoli, aggiungerle qui (es. transferGovernance)
}
