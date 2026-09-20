// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface WithdrawVm {
    function envOr(string calldata, address) external returns (address);
    function envOr(string calldata, uint256) external returns (uint256);
    function addr(uint256) external returns (address);
    function startBroadcast(uint256) external;
    function startBroadcast(address) external;
    function stopBroadcast() external;
}
interface CoreVaultShares {
    function balanceOf(address) external view returns (uint256);
    function requestInstantWithdrawal(uint256 shares)
        external
        returns (bool settledImmediately, uint256 epochId, uint256 claimId);
}

/// @notice Redeems the deployer's OWN CoreVault shares only. Calls the standard
///         self-service exit path (requestInstantWithdrawal), which burns
///         msg.sender's shares and pays msg.sender directly — it cannot act on
///         any other depositor's balance. Falls back to the epoch queue
///         automatically if instant settlement isn't available right now.
contract WithdrawDeployerShares {
    WithdrawVm constant vm = WithdrawVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant EXPECTED = 0x908756f36954f2853134259B8846c49F90E84ECe;
    address constant CORE_VAULT = 0x4575Ec0dD1ED08FD4F426665E5B56442594189bb;

    event SharesFound(uint256 balance);
    event WithdrawalResult(bool settledImmediately, uint256 epochId, uint256 claimId);

    function run() external {
        address sender = vm.envOr("DEPLOYER_ADDRESS", EXPECTED);
        require(sender == EXPECTED, "unexpected deployer; review sender");

        uint256 shares = CoreVaultShares(CORE_VAULT).balanceOf(sender);
        emit SharesFound(shares);
        require(shares > 0, "no shares to withdraw");

        // Forge consumes this repository's .env itself. Never source or print its secrets.
        uint256 key = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (key != 0) {
            require(vm.addr(key) == sender, "key/sender mismatch");
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast(sender);
        }
        (bool settledImmediately, uint256 epochId, uint256 claimId) =
            CoreVaultShares(CORE_VAULT).requestInstantWithdrawal(shares);
        vm.stopBroadcast();

        emit WithdrawalResult(settledImmediately, epochId, claimId);
    }
}
