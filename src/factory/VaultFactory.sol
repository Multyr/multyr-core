// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ICoreVault } from "../interfaces/ICoreVault.sol";
import { Events } from "../core/libraries/Events.sol";
import { DeployTypes } from "../libs/DeployTypes.sol";

/// @title VaultFactory
/// @notice On-chain registry for deployed CoreVaults. Deployment is performed off-chain via script.
contract VaultFactory {
    error UseOffchainDeployer();
    error NotOwner();
    error ZeroAddress();
    error AssetMismatch();
    error VaultNotFound();

    address public immutable owner;
    address[] public deployedVaults;

    event VaultDeployed(
        address indexed vault,
        address indexed asset,
        address indexed owner,
        address feeCollector,
        string name,
        string symbol
    );

    constructor() {
        owner = msg.sender;
    }

    /// @notice Legacy entrypoint now disabled to enforce off-chain deployment
    function createVault(bytes calldata) external pure {
        revert UseOffchainDeployer();
    }

    function createVaultDeterministic(bytes calldata, bytes32) external pure {
        revert UseOffchainDeployer();
    }

    /// @notice Register a vault that was deployed off-chain
    function registerVault(address vault, bytes calldata initData) external {
        if (msg.sender != owner) revert NotOwner();
        if (vault == address(0)) revert ZeroAddress();

        DeployTypes.DeployConfig memory cfg = abi.decode(initData, (DeployTypes.DeployConfig));

        // Minimal consistency check
        if (ICoreVault(vault).asset() != address(cfg.asset)) revert AssetMismatch();

        deployedVaults.push(vault);

        emit VaultDeployed(
            vault, address(cfg.asset), cfg.owner, cfg.feeCollector, cfg.name, cfg.symbol
        );
        emit Events.VaultCreated(
            vault, address(cfg.asset), cfg.owner, cfg.feeCollector, cfg.name, cfg.symbol
        );
        emit Events.VaultProductionReady(vault);
    }

    /// @notice Get count of deployed vaults
    function deployedVaultsCount() external view returns (uint256) {
        return deployedVaults.length;
    }

    /// @notice Get all deployed vault addresses
    function getDeployedVaults() external view returns (address[] memory) {
        return deployedVaults;
    }

    /// @notice Check if a vault was deployed by this factory
    function isDeployedVault(address vault) external view returns (bool) {
        for (uint256 i = 0; i < deployedVaults.length;) {
            if (deployedVaults[i] == vault) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @notice Mark a vault as deprecated (emits event for subgraph indexing)
    function deprecateVault(address vault) external {
        if (msg.sender != owner) revert NotOwner();
        if (vault == address(0)) revert ZeroAddress();
        emit Events.VaultDeprecated(vault);
    }

    /// @notice Remove a vault from the registry (swap-and-pop)
    function removeVault(address vault) external {
        if (msg.sender != owner) revert NotOwner();
        if (vault == address(0)) revert ZeroAddress();

        uint256 len = deployedVaults.length;
        for (uint256 i = 0; i < len;) {
            if (deployedVaults[i] == vault) {
                deployedVaults[i] = deployedVaults[len - 1];
                deployedVaults.pop();
                emit Events.VaultRemoved(vault);
                return;
            }
            unchecked { ++i; }
        }
        revert VaultNotFound();
    }

    /// @notice Set a custom status on a vault (free-form, for subgraph/frontend display)
    /// @param vault The vault address
    /// @param status Short status label (e.g. "WITHDRAW_ONLY", "HOLD", "MIGRATING", "DEPRECATED")
    /// @param note Human-readable explanation (e.g. "Vault v3 retired — migrate to v4")
    function setVaultStatus(address vault, string calldata status, string calldata note) external {
        if (msg.sender != owner) revert NotOwner();
        if (vault == address(0)) revert ZeroAddress();
        emit Events.VaultStatusChanged(vault, status, note);
    }
}
