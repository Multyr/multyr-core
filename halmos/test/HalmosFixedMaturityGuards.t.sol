// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {
    FixedMaturityStorage,
    VaultMode,
    VaultState,
    _checkDepositsAllowed,
    _checkStandardExitAllowed,
    _checkSettlementAllowed,
    _checkForceExitAllowed
} from "core/storage/FixedMaturityStorage.sol";
import { FixedMaturityLogicLib } from "core/libraries/FixedMaturityLogicLib.sol";

contract FixedMaturityGuardHarness {
    function setModeState(VaultMode mode, VaultState state, bool instantEnabled) external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        fm.vaultMode = mode;
        fm.vaultState = state;
        fm.instantEnabledAfterMaturity = instantEnabled;
    }

    function setFundingParams(uint64 deadline, uint256 minFunding, uint256 targetFunding) external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        fm.fundingDeadlineTs = deadline;
        fm.minFundingAssets = minFunding;
        fm.targetFundingAssets = targetFunding;
    }

    function checkDeposits() external view {
        _checkDepositsAllowed(FixedMaturityStorage.layout());
    }

    function checkStandardExit(bool instant) external view {
        _checkStandardExitAllowed(FixedMaturityStorage.layout(), instant);
    }

    function checkSettlement() external view {
        _checkSettlementAllowed(FixedMaturityStorage.layout());
    }

    function checkForceExit() external view {
        _checkForceExitAllowed(FixedMaturityStorage.layout());
    }

    function shouldFundingFail(uint256 netAssets) external view returns (bool) {
        return FixedMaturityLogicLib.shouldFundingFail(FixedMaturityStorage.layout(), netAssets);
    }
}

contract HalmosFixedMaturityGuards is Test {
    FixedMaturityGuardHarness internal harness;

    function setUp() public {
        harness = new FixedMaturityGuardHarness();
    }

    function check_deposits_gate_matches_state_machine(VaultMode mode, VaultState state) public {
        harness.setModeState(mode, state, false);

        bool shouldPass = mode == VaultMode.OpenEnded || state == VaultState.Funding;
        if (shouldPass) {
            harness.checkDeposits();
            return;
        }

        try harness.checkDeposits() {
            assert(false);
        } catch {}
    }

    function check_force_exit_gate_matches_state_machine(VaultMode mode, VaultState state) public {
        harness.setModeState(mode, state, false);

        bool shouldPass = mode == VaultMode.OpenEnded || state == VaultState.Active;
        if (shouldPass) {
            harness.checkForceExit();
            return;
        }

        try harness.checkForceExit() {
            assert(false);
        } catch {}
    }

    function check_settlement_gate_matches_state_machine(VaultMode mode, VaultState state) public {
        harness.setModeState(mode, state, false);

        bool shouldPass = mode == VaultMode.OpenEnded || state == VaultState.Matured;
        if (shouldPass) {
            harness.checkSettlement();
            return;
        }

        try harness.checkSettlement() {
            assert(false);
        } catch {}
    }

    function check_standard_exit_gate_matches_state_machine(
        VaultMode mode,
        VaultState state,
        bool instant,
        bool instantEnabled
    ) public {
        harness.setModeState(mode, state, instantEnabled);

        bool shouldPass = mode == VaultMode.OpenEnded
            || (state == VaultState.Matured && (!instant || instantEnabled));
        if (shouldPass) {
            harness.checkStandardExit(instant);
            return;
        }

        try harness.checkStandardExit(instant) {
            assert(false);
        } catch {}
    }

    function check_shouldFundingFail_matches_spec(
        VaultMode mode,
        VaultState state,
        uint64 deadline,
        uint256 minFunding,
        uint256 targetFunding,
        uint256 netAssets
    ) public {
        harness.setModeState(mode, state, false);
        harness.setFundingParams(deadline, minFunding, targetFunding);

        bool expected = mode == VaultMode.FixedMaturity
            && state == VaultState.Funding
            && block.timestamp >= deadline
            && netAssets < minFunding;

        assert(harness.shouldFundingFail(netAssets) == expected);
    }
}
