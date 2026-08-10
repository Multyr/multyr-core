// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { GlobalConfig } from "../../../src/core/config/GlobalConfig.sol";
import { IParamsProvider } from "../../../src/interfaces/IParamsProvider.sol";

/// @notice Proves the two previously-dead per-vault override paths now work: withdrawal
///         config (minClaimAmount) and the GOV_CAPS family (minDeployAmount, among others).
///         Both are asset-unit denominated and needed per-vault for non-USDC deployments
///         since GlobalConfig is shared across vaults with potentially different decimals.
contract GlobalConfig_VaultOverrides_Decimals_Test is Test {
    GlobalConfig internal cfg;
    address internal governor;
    address internal vault;

    function setUp() public {
        governor = makeAddr("governor");
        vault = makeAddr("vault");
        vm.prank(governor);
        cfg = new GlobalConfig(governor, 50, 100, 2000, 86400, 10, 500, 3600, 3600);
    }

    // ═══════════════════════════════════════════════════════════════════
    // setVaultWithdrawalOverride
    // ═══════════════════════════════════════════════════════════════════

    function test_withdrawalOverride_defaultsTo6dpGlobal_beforeOverride() public view {
        IParamsProvider.WithdrawalParams memory p = cfg.getWithdrawalParams(vault);
        assertEq(p.minClaimAmount, 100e6, "global default is 100 USDC (6dp)");
    }

    function test_setVaultWithdrawalOverride_appliesPerVault_18dp() public {
        GlobalConfig.WithdrawalConfig memory wethCfg = GlobalConfig.WithdrawalConfig({
            capPerEpochBps: 1000,
            maxWithdrawalPerBlock: 0,
            maxWithdrawalPerTx: 0,
            minClaimAmount: 0.05e18, // 0.05 WETH anti-spam floor, not 100e6
            lockPeriod: 0
        });

        vm.prank(governor);
        cfg.setVaultWithdrawalOverride(vault, wethCfg);

        IParamsProvider.WithdrawalParams memory p = cfg.getWithdrawalParams(vault);
        assertEq(p.minClaimAmount, 0.05e18);

        // A different, unconfigured vault must still see the untouched global default.
        address otherVault = makeAddr("otherVault");
        assertEq(cfg.getWithdrawalParams(otherVault).minClaimAmount, 100e6);
    }

    function test_setVaultWithdrawalOverride_onlyGovernor() public {
        GlobalConfig.WithdrawalConfig memory wethCfg;
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(GlobalConfig.NotGovernor.selector);
        cfg.setVaultWithdrawalOverride(vault, wethCfg);
    }

    // ═══════════════════════════════════════════════════════════════════
    // setVaultGovCaps
    // ═══════════════════════════════════════════════════════════════════

    function test_govCaps_defaultsToGlobal_beforeOverride() public view {
        assertEq(cfg.minDeployAmount(vault), 10e6, "global default is 10 USDC (6dp)");
    }

    function test_setVaultGovCaps_appliesPerVault_18dp_andPreservesOtherFields() public {
        vm.prank(governor);
        cfg.setVaultGovCaps(
            vault,
            2 days, // minParamDelay
            5e17, // maxPerfRate
            500, // maxFeeBps
            200, // maxImmExitBps
            200, // maxForceExitBps
            7 days, // guardianPauseCooldown
            0.01e18, // minDeployAmount: 0.01 WETH, not 10e6
            1_000_000, // stratTaGas
            3000 // opsMaxBps
        );

        assertEq(cfg.minDeployAmount(vault), 0.01e18);
        // Every other GOV_CAPS field for this vault must also read back correctly —
        // setting the shared hasOverride flag without populating all nine fields would
        // otherwise silently zero these out.
        assertEq(cfg.maxFeeBps(vault), 500);
        assertEq(cfg.maxPerfRate(vault), 5e17);
        assertEq(cfg.guardianPauseCooldown(vault), 7 days);
        assertEq(cfg.stratTaGas(vault), 1_000_000);
        assertEq(cfg.opsMaxBps(vault), 3000);

        address otherVault = makeAddr("otherVault");
        assertEq(cfg.minDeployAmount(otherVault), 10e6, "unrelated vault unaffected");
    }

    function test_setVaultGovCaps_onlyGovernor() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(GlobalConfig.NotGovernor.selector);
        cfg.setVaultGovCaps(vault, 2 days, 5e17, 500, 200, 200, 7 days, 0.01e18, 1_000_000, 3000);
    }

    function test_setVaultGovCaps_rejectsInvalidBps() public {
        vm.prank(governor);
        vm.expectRevert(GlobalConfig.InvalidBps.selector);
        cfg.setVaultGovCaps(vault, 2 days, 5e17, 10_001, 200, 200, 7 days, 0.01e18, 1_000_000, 3000);
    }
}
