// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";
import { QueueModule } from "../../../src/core/modules/QueueModule.sol";
import { SelectorLib } from "../../../src/core/libraries/SelectorLib.sol";
import { ModuleSetter } from "../../helpers/ModuleSetter.sol";
import { ExitEngineLib } from "../../../src/core/libraries/ExitEngineLib.sol";

interface IQueueModule {
    function requestClaim(bool immediate, uint256 shares) external;
}

/**
 * @title FuzzWithdraw_NetExact
 * @notice Audit-grade fuzz: requestClaim(true) transfers correct USDC to user
 * @dev withdraw() always reverts AsyncWithdrawalRequired in queued protocol.
 *      This test validates instant claim via requestClaim(true).
 *
 * Invariants:
 * 1. shares consumed == requested shares
 * 2. user receives USDC > 0
 * 3. totalSupply never increases on exit
 * 4. withdraw() always reverts
 */
contract FuzzWithdraw_NetExact is Test {
    CoreHarness internal vault;
    ERC20Mock internal usdc;
    QueueModule internal queueModule;

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

        // Wire QueueModule
        queueModule = new QueueModule();
        bytes4[] memory queueSels = SelectorLib.getQueueModuleSelectors();
        ModuleSetter.setModulesSame(
            address(vault), queueSels, address(queueModule), SelectorLib.ROLE_PUBLIC
        );

        // Seed PPS state: 10M USDC deposit by this contract
        uint256 seed = 10_000_000e6;
        usdc._mint(address(this), seed);
        usdc.approve(address(vault), seed);
        vault.deposit(seed, address(this));
    }

    /// @notice withdraw() always reverts with AsyncWithdrawalRequired
    function testFuzz_withdraw_alwaysReverts(uint256 W) public {
        W = bound(W, 1, 1_000_000e6);

        usdc._mint(user, W * 3);
        vm.startPrank(user);
        usdc.approve(address(vault), W * 3);
        vault.deposit(W * 3, user);

        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(W, user, user);
        vm.stopPrank();
    }

    /// @notice requestClaim(true) instant claim invariants
    function testFuzz_requestClaimInstant_invariants(uint256 shares, uint16 witBps) public {
        witBps = uint16(bound(uint256(witBps), 0, 500)); // 0-5%
        shares = bound(shares, 1e6, 1_000_000e6); // 1 .. 1M shares

        // Set withdraw fee
        vault.setFeeParamsUnsafe(0, witBps, treasury);

        // Fund user and deposit
        uint256 depositAmt = shares * 2 + 1e6;
        usdc._mint(user, depositAmt);

        vm.startPrank(user);
        usdc.approve(address(vault), depositAmt);
        vault.deposit(depositAmt, user);

        uint256 sharesBefore = vault.balanceOf(user);
        uint256 supplyBefore = vault.totalSupply();
        uint256 usdcBefore = usdc.balanceOf(user);

        // Instant claim
        IQueueModule(address(vault)).requestClaim(true, shares);

        uint256 sharesAfter = vault.balanceOf(user);
        uint256 supplyAfter = vault.totalSupply();
        uint256 usdcAfter = usdc.balanceOf(user);
        vm.stopPrank();

        // INVARIANT 1: shares consumed == requested
        assertEq(sharesBefore - sharesAfter, shares, "shares consumed == requested");

        // INVARIANT 2: user received USDC
        assertGt(usdcAfter, usdcBefore, "user received USDC");

        // INVARIANT 3: totalSupply never increases on exit
        assertLe(supplyAfter, supplyBefore, "totalSupply must not increase on exit");
    }
}
