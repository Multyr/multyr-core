// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";

/**
 * @title FuzzDeposit_FeeInvariant
 * @notice Audit-grade fuzz: deposit(assets) conserves USDC + mints correct shares
 * @dev Fuzz dimensions: assets (1..10M), depBps (0..500), supply state (seed 0..5M)
 *
 * Invariants:
 * 1. totalAssets increases by exactly `assets` (unit env, no routing)
 * 2. shares == convertToShares(net)  (1 wei tolerance for rounding)
 * 3. treasury receives fee shares when depBps > 0
 */
contract FuzzDeposit_FeeInvariant is Test {
    CoreHarness internal vault;
    ERC20Mock internal usdc;

    address internal user = address(0xBEEF);
    address internal treasury = address(0xFEE);

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        MockParamsProvider params = new MockParamsProvider();

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "CoreVault",
            "vUSDC",
            address(this),
            treasury,
            address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(vault));
        vault.setBufferManagerUnsafe(address(mockBM));

        // Seed PPS state: 10M USDC deposit by this contract
        uint256 seed = 10_000_000e6;
        usdc._mint(address(this), seed);
        usdc.approve(address(vault), seed);
        vault.deposit(seed, address(this));
    }

    function testFuzz_deposit_feeInvariant(uint256 assets, uint16 depBps, uint256 seedExtra)
        public
    {
        depBps = uint16(bound(uint256(depBps), 0, 500));
        seedExtra = bound(seedExtra, 0, 5_000_000e6);
        assets = bound(assets, 1e6, 10_000_000e6); // 1 USDC .. 10M

        vault.setFeeParamsUnsafe(depBps, 0, treasury);

        if (seedExtra > 0) {
            usdc._mint(address(this), seedExtra);
            usdc.approve(address(vault), seedExtra);
            vault.deposit(seedExtra, address(this));
        }

        usdc._mint(user, assets);

        vm.startPrank(user);
        usdc.approve(address(vault), assets);

        uint256 taBefore = vault.totalAssets();
        uint256 treasurySharesBefore = vault.balanceOf(treasury);

        uint256 shares = vault.deposit(assets, user);
        vm.stopPrank();

        uint256 taAfter = vault.totalAssets();

        // INVARIANT 1: In unit env, all USDC stays in vault accounting
        assertEq(taAfter, taBefore + assets, "deposit: totalAssets += assets");

        // INVARIANT 2: User shares == convertToShares(net)
        uint256 expectedFee = (assets * uint256(depBps)) / 10_000;
        uint256 expectedNet = assets - expectedFee;
        uint256 expectedShares = vault.convertToShares(expectedNet);

        assertApproxEqAbs(shares, expectedShares, 1, "deposit: shares ~= convertToShares(net)");

        // INVARIANT 3: Treasury receives fee shares (if any)
        if (depBps > 0 && expectedFee > 0) {
            uint256 treasurySharesAfter = vault.balanceOf(treasury);
            assertGt(treasurySharesAfter, treasurySharesBefore, "deposit: treasury gets fee shares");
        }
    }
}
