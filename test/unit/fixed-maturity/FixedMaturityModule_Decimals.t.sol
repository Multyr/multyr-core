// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { FixedMaturityHarness } from "./FixedMaturityHarness.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { FixedMaturityModule } from "../../../src/core/modules/FixedMaturityModule.sol";
import { InvalidVaultState } from "../../../src/core/libraries/Errors.sol";

/// @notice Proves configureFixedMaturity's funding-target overflow guard scales with the
///         vault asset's actual decimals, including 18dp funding targets such as 500e18.
contract FixedMaturityModule_Decimals_Test is Test {
    function _deployHarness(uint8 decimals) internal returns (FixedMaturityHarness h) {
        ERC20Mock asset_ = new ERC20Mock("TOK", "TOK", decimals);
        MockParamsProvider params = new MockParamsProvider();
        h = new FixedMaturityHarness(
            IERC20Metadata(address(asset_)), "FM Vault", "vFM", address(this), address(0xFEE), address(params)
        );
        FixedMaturityModule(address(h)).setVaultModeFixedMaturity();
    }

    function test_18dp_realisticFundingTarget_noLongerRejected() public {
        FixedMaturityHarness h = _deployHarness(18);
        uint256 target = 500e18; // 500 whole tokens at 18 decimals

        FixedMaturityModule(address(h)).configureFixedMaturity(
            uint64(block.timestamp + 30 days),
            100e18,
            target,
            uint64(block.timestamp + 7 days),
            true,
            true,
            2000,
            makeAddr("strategy")
        );
        // No revert = success. Confirm it was actually recorded.
        assertEq(FixedMaturityModule(address(h)).minFundingAssets(), 100e18);
    }

    function test_18dp_stillRejectsAboveNewCap() public {
        FixedMaturityHarness h = _deployHarness(18);
        uint256 aboveCap = 1_000_000_001e18;

        vm.expectRevert(InvalidVaultState.selector);
        FixedMaturityModule(address(h)).configureFixedMaturity(
            uint64(block.timestamp + 30 days),
            100e18,
            aboveCap,
            uint64(block.timestamp + 7 days),
            true,
            true,
            2000,
            makeAddr("strategy")
        );
    }

    function test_6dp_capUnchanged() public {
        FixedMaturityHarness h = _deployHarness(6);

        vm.expectRevert(InvalidVaultState.selector);
        FixedMaturityModule(address(h)).configureFixedMaturity(
            uint64(block.timestamp + 30 days),
            100e6,
            1_000_000_001e6, // just above the original 1B-USDC cap
            uint64(block.timestamp + 7 days),
            true,
            true,
            2000,
            makeAddr("strategy")
        );
    }
}
