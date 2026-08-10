// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { OracleValuationLib } from "../../../src/core/libraries/OracleValuationLib.sol";
import { IParamsProvider } from "../../../src/interfaces/IParamsProvider.sol";
import { MockPriceOracleMiddleware } from "../../helpers/MockPriceOracleMiddleware.sol";
import { GlobalConfig } from "../../../src/core/config/GlobalConfig.sol";

/// @notice Exercises OracleValuationLib.usdToAssetUnits pure math and getFreshPriceWad's
///         fail-closed behavior in isolation from RouterRebalanceGuard's gate logic.
contract OracleValuationLibHarness {
    function usdToAssetUnits(uint256 usdWad, uint256 priceWad, uint8 assetDecimals)
        external
        pure
        returns (uint256)
    {
        return OracleValuationLib.usdToAssetUnits(usdWad, priceWad, assetDecimals);
    }

    function getFreshPriceWad(IParamsProvider params, address asset, address vault)
        external
        view
        returns (uint256)
    {
        return OracleValuationLib.getFreshPriceWad(params, asset, vault);
    }
}

contract OracleValuationLib_Test is Test {
    OracleValuationLibHarness internal lib_;
    GlobalConfig internal params;
    MockPriceOracleMiddleware internal oracle;

    address internal governor;
    address internal usdc;
    address internal vault;

    function setUp() public {
        governor = makeAddr("governor");
        usdc = makeAddr("usdc");
        vault = makeAddr("vault");
        lib_ = new OracleValuationLibHarness();
        oracle = new MockPriceOracleMiddleware();
        vm.prank(governor);
        params = new GlobalConfig(governor, 50, 100, 2000, 86400, 10, 500, 3600, 3600);
    }

    // ═══════════════════════════════════════════════════════════════════
    // usdToAssetUnits — pure math parity across decimals
    // ═══════════════════════════════════════════════════════════════════

    function test_usdToAssetUnits_usdcAt6dp_oneDollarPrice() public {
        // $1000 WAD, USDC at $1.00, 6dp -> 1000 USDC
        uint256 out = lib_.usdToAssetUnits(1000e18, 1e18, 6);
        assertEq(out, 1000e6, "1000 USD at $1 = 1000 USDC");
    }

    function test_usdToAssetUnits_wethAt18dp_3500DollarPrice() public {
        // $1000 WAD, WETH at $3500, 18dp -> 1000/3500 WETH
        uint256 out = lib_.usdToAssetUnits(1000e18, 3500e18, 18);
        uint256 usdWad = 1000e18;
        uint256 oneWad = 1e18;
        uint256 priceWad = 3500e18;
        uint256 expected = (usdWad * oneWad) / priceWad;
        assertEq(out, expected, "matches direct mulDiv");
        // Sanity: ~0.2857 WETH
        assertApproxEqAbs(out, 0.285714285714285714e18, 1e12);
    }

    function test_usdToAssetUnits_zeroUsd_isZero() public {
        assertEq(lib_.usdToAssetUnits(0, 1e18, 18), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // getFreshPriceWad — fail-closed behavior
    // ═══════════════════════════════════════════════════════════════════

    function test_getFreshPriceWad_revertsWhenOracleNotConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(OracleValuationLib.OracleNotConfigured.selector, usdc));
        lib_.getFreshPriceWad(params, usdc, vault);
    }

    function test_getFreshPriceWad_returnsPrice_whenFresh() public {
        vm.prank(governor);
        params.setAssetOracleConfig(usdc, address(oracle), 3600);
        oracle.setPrice(usdc, 1e18);

        uint256 price = lib_.getFreshPriceWad(params, usdc, vault);
        assertEq(price, 1e18);
    }

    function test_getFreshPriceWad_revertsWhenStale() public {
        vm.prank(governor);
        params.setAssetOracleConfig(usdc, address(oracle), 3600);
        oracle.setPrice(usdc, 1e18);
        oracle.setStale(usdc);

        vm.expectRevert();
        lib_.getFreshPriceWad(params, usdc, vault);
    }

    function test_getFreshPriceWad_revertsWhenTooOld() public {
        vm.prank(governor);
        params.setAssetOracleConfig(usdc, address(oracle), 3600);
        oracle.setPrice(usdc, 1e18);

        vm.warp(block.timestamp + 3601);
        vm.expectRevert();
        lib_.getFreshPriceWad(params, usdc, vault);
    }
}
