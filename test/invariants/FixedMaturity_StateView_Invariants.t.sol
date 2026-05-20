// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC20Mock } from "src/mocks/ERC20Mock.sol";
import { VaultMode, VaultState } from "src/core/storage/FixedMaturityStorage.sol";
import { FixedMaturityHarness } from "test/unit/fixed-maturity/FixedMaturityHarness.sol";
import { MockParamsProvider } from "test/helpers/MockParamsProvider.sol";

interface IFixedMaturityViews {
    function currentVaultModeAndState() external view returns (VaultMode, VaultState);
    function isDepositOpen() external view returns (bool);
    function isSettlementOpen() external view returns (bool);
    function isInstantExitOpen() external view returns (bool);
}

contract FixedMaturityStateHandler {
    FixedMaturityHarness internal immutable vault;
    bool internal instantEnabled;

    constructor(FixedMaturityHarness vault_) {
        vault = vault_;
        _applyConfig(false);
    }

    function setMode(uint8 rawMode) external {
        vault.setFMModeUnsafe(VaultMode(rawMode % 2));
    }

    function setState(uint8 rawState) external {
        vault.setFMStateUnsafe(VaultState(rawState % 6));
    }

    function setInstantEnabled(bool enabled) external {
        instantEnabled = enabled;
        _applyConfig(enabled);
    }

    function expectedInstantEnabled() external view returns (bool) {
        return instantEnabled;
    }

    function _applyConfig(bool enabled) internal {
        vault.setFMConfigUnsafe(
            uint64(block.timestamp + 30 days),
            100_000e6,
            200_000e6,
            uint64(block.timestamp + 7 days),
            false,
            enabled,
            0,
            address(0xBEEF)
        );
    }
}

contract FixedMaturity_StateView_Invariants is StdInvariant, Test {
    FixedMaturityHarness internal vault;
    FixedMaturityStateHandler internal handler;
    IFixedMaturityViews internal fmViews;

    function setUp() public {
        ERC20Mock usdc = new ERC20Mock("USDC", "USDC", 6);
        MockParamsProvider params = new MockParamsProvider();

        vault = new FixedMaturityHarness(
            IERC20Metadata(address(usdc)),
            "FM Invariant Vault",
            "fmINV",
            address(this),
            address(this),
            address(params)
        );
        handler = new FixedMaturityStateHandler(vault);
        fmViews = IFixedMaturityViews(address(vault));

        targetContract(address(handler));
    }

    function invariant_current_mode_state_roundtrip() public view {
        (VaultMode routedMode, VaultState routedState) = fmViews.currentVaultModeAndState();
        assertEq(uint256(routedMode), uint256(vault.getFMVaultMode()), "mode mismatch");
        assertEq(uint256(routedState), uint256(vault.getFMVaultState()), "state mismatch");
    }

    function invariant_deposit_open_matches_mode_and_state() public view {
        (VaultMode mode, VaultState state) = fmViews.currentVaultModeAndState();
        bool expected = mode == VaultMode.OpenEnded || state == VaultState.Funding;
        assertEq(fmViews.isDepositOpen(), expected, "deposit gate mismatch");
    }

    function invariant_settlement_open_matches_mode_and_state() public view {
        (VaultMode mode, VaultState state) = fmViews.currentVaultModeAndState();
        bool expected = mode == VaultMode.OpenEnded || state == VaultState.Matured;
        assertEq(fmViews.isSettlementOpen(), expected, "settlement gate mismatch");
    }

    function invariant_instant_exit_open_matches_mode_state_and_flag() public view {
        (VaultMode mode, VaultState state) = fmViews.currentVaultModeAndState();
        bool expected = mode == VaultMode.OpenEnded
            || (state == VaultState.Matured && handler.expectedInstantEnabled());
        assertEq(fmViews.isInstantExitOpen(), expected, "instant exit gate mismatch");
    }
}
