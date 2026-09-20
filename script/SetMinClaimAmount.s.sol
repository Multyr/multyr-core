// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface SetMinClaimVm {
    function envOr(string calldata, address) external returns (address);
    function envOr(string calldata, uint256) external returns (uint256);
    function envUint(string calldata) external returns (uint256);
    function addr(uint256) external returns (address);
    function startBroadcast(uint256) external;
    function startBroadcast(address) external;
    function stopBroadcast() external;
}

/// @notice Schedules + executes (in one run, since this timelock's minDelay is 0)
///         a GlobalConfig.setVaultWithdrawalOverride() call that changes ONLY
///         minClaimAmount for the CoreVault, preserving every other field at
///         its current on-chain value (capPerEpochBps, maxWithdrawalPerBlock,
///         maxWithdrawalPerTx, lockPeriod) so no other anti-spam/rate-limit
///         protection is touched. Target value passed via TARGET_MIN_CLAIM env var.
interface IGlobalConfigView {
    struct WithdrawalConfig {
        uint16 capPerEpochBps;
        uint256 maxWithdrawalPerBlock;
        uint256 maxWithdrawalPerTx;
        uint256 minClaimAmount;
        uint64 lockPeriod;
    }
}
interface IGlobalConfig {
    function setVaultWithdrawalOverride(address vault, IGlobalConfigView.WithdrawalConfig calldata cfg) external;
}
interface ICoreVaultParams {
    function params() external view returns (address);
}
interface IParamsProviderView {
    function getWithdrawalParams(address vault) external view returns (IGlobalConfigView.WithdrawalConfig memory);
}
interface ITimelock {
    function schedule(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt, uint256 delay) external;
    function execute(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt) external payable;
}

contract SetMinClaimAmount {
    SetMinClaimVm constant vm = SetMinClaimVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant EXPECTED = 0x908756f36954f2853134259B8846c49F90E84ECe;
    address constant TIMELOCK = 0xE2812E869F8005397130CCDF1aaabd75447844df;
    address constant GLOBAL_CONFIG = 0x8fE1cbc7fC2A469B5b5904EA5e5C4D09c583eDD6;
    address constant CORE_VAULT = 0x4575Ec0dD1ED08FD4F426665E5B56442594189bb;

    function run() external {
        address sender = vm.envOr("DEPLOYER_ADDRESS", EXPECTED);
        require(sender == EXPECTED, "unexpected deployer; review sender");

        uint256 targetMinClaim = vm.envUint("TARGET_MIN_CLAIM");

        IGlobalConfigView.WithdrawalConfig memory current =
            IParamsProviderView(GLOBAL_CONFIG).getWithdrawalParams(CORE_VAULT);

        IGlobalConfigView.WithdrawalConfig memory cfg = IGlobalConfigView.WithdrawalConfig({
            capPerEpochBps: current.capPerEpochBps,
            maxWithdrawalPerBlock: current.maxWithdrawalPerBlock,
            maxWithdrawalPerTx: current.maxWithdrawalPerTx,
            minClaimAmount: targetMinClaim,
            lockPeriod: current.lockPeriod
        });

        bytes memory data = abi.encodeWithSelector(
            IGlobalConfig.setVaultWithdrawalOverride.selector, CORE_VAULT, cfg
        );
        bytes32 salt = keccak256(abi.encode("minClaimAmount", targetMinClaim, block.timestamp));

        // Forge consumes this repository's .env itself. Never source or print its secrets.
        uint256 key = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (key != 0) {
            require(vm.addr(key) == sender, "key/sender mismatch");
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast(sender);
        }
        ITimelock(TIMELOCK).schedule(GLOBAL_CONFIG, 0, data, bytes32(0), salt, 0);
        ITimelock(TIMELOCK).execute(GLOBAL_CONFIG, 0, data, bytes32(0), salt);
        vm.stopBroadcast();
    }
}
