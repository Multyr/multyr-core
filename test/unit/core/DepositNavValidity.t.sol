// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "lib/forge-std/src/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {CoreHarness} from "../../helpers/CoreHarness.sol";
import {MockUSDC} from "../../helpers/MockUSDC.sol";
import {MockBufferManagerForTests} from "../../helpers/MockBufferManagerForTests.sol";
import {ERC4626Module} from "../../../src/core/modules/ERC4626Module.sol";
import {EpochedQueueModule} from "../../../src/core/modules/EpochedQueueModule.sol";
import {
    MockQueueEpochParamsProvider
} from "../../sprint-test/QueueEpochModule_WithdrawFlow_POC.t.sol";
import {MockNavRouter} from "./EconomicExit_Spec.t.sol";

contract RevertingNavRouter {
    uint256 public assets;

    constructor(uint256 a) {
        assets = a;
    }

    function totalStrategyAssetsSafe() external view returns (uint256) {
        return assets;
    }

    function navValidity() external pure returns (uint256, uint8) {
        revert("valuation failed");
    }
}

contract DepositNavValidity_Test is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 constant STRATEGY_ASSETS = 1_500e6;
    uint256 constant DEPOSIT = 100e6;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address strategy = makeAddr("strategy");

    CoreHarness core;
    MockBufferManagerForTests bm;

    struct Snapshot {
        uint256 carolUsdc;
        uint256 carolShares;
        uint256 aliceShares;
        uint256 totalSupply;
        uint256 vaultUsdc;
        uint256 totalAssets;
    }

    function setUp() public {
        vm.etch(USDC, address(new MockUSDC()).code);
        MockQueueEpochParamsProvider params = new MockQueueEpochParamsProvider();
        core = new CoreHarness(
            IERC20Metadata(USDC),
            "USDC Agg",
            "agUSDC",
            address(this),
            address(this),
            address(params)
        );
        core.setEpochDurationUnsafe(7 days);
        bm = MockBufferManagerForTests(address(core.bufferManager()));
        address[3] memory us = [alice, bob, carol];
        for (uint256 i; i < us.length; i++) {
            MockUSDC(USDC).mint(us[i], 10_000_000e6);
            vm.prank(us[i]);
            IERC20(USDC).approve(address(core), type(uint256).max);
        }
        _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        vm.prank(address(core));
        IERC20(USDC).transfer(strategy, STRATEGY_ASSETS);
        core.setStrategyRouterUnsafe(address(new MockNavRouter(STRATEGY_ASSETS, 0)));
    }

    function _vault() internal view returns (ERC4626Module) {
        return ERC4626Module(address(core));
    }

    function _deposit(address who, uint256 a) internal returns (uint256 s) {
        vm.prank(who);
        s = ERC4626Module(address(core)).deposit(a, who);
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.carolUsdc = IERC20(USDC).balanceOf(carol);
        s.carolShares = core.balanceOf(carol);
        s.aliceShares = core.balanceOf(alice);
        s.totalSupply = core.totalSupply();
        s.vaultUsdc = IERC20(USDC).balanceOf(address(core));
        s.totalAssets = core.totalAssets();
    }

    function _assertUnchanged(Snapshot memory before) internal view {
        Snapshot memory afterwards = _snapshot();
        assertEq(afterwards.carolUsdc, before.carolUsdc, "depositor assets moved");
        assertEq(afterwards.carolShares, before.carolShares, "depositor shares minted");
        assertEq(afterwards.aliceShares, before.aliceShares, "holder shares changed");
        assertEq(afterwards.totalSupply, before.totalSupply, "supply changed");
        assertEq(afterwards.vaultUsdc, before.vaultUsdc, "vault assets moved");
        assertEq(afterwards.totalAssets, before.totalAssets, "NAV changed");
    }

    function _expectEveryEntryPathReverts(bytes memory err) internal {
        uint256 shares = core.previewDeposit(DEPOSIT);
        Snapshot memory before = _snapshot();

        vm.prank(carol);
        vm.expectRevert(err);
        _vault().deposit(DEPOSIT, carol);

        vm.prank(carol);
        vm.expectRevert(err);
        _vault().deposit(DEPOSIT, carol, 0);

        vm.prank(carol);
        vm.expectRevert(err);
        _vault().depositFor(DEPOSIT, carol);

        vm.prank(carol);
        vm.expectRevert(err);
        _vault().mint(shares, carol);

        vm.prank(carol);
        vm.expectRevert(err);
        _vault().mint(shares, carol, type(uint256).max);

        _assertUnchanged(before);
    }

    function test_r5_strategyValuedAtZero_wouldMintAtWrongPrice_depositsRejected() public {
        uint256 fairShares = core.previewDeposit(DEPOSIT);
        core.setStrategyRouterUnsafe(address(new MockNavRouter(0, 4)));

        assertGt(
            core.previewDeposit(DEPOSIT), fairShares * 3, "the failed valuation inflates shares"
        );
        (bool valid, uint8 reason) = core.navStatus();
        assertFalse(valid);
        assertEq(reason, 4);

        _expectEveryEntryPathReverts(
            abi.encodeWithSelector(ERC4626Module.NavInputInvalid.selector, uint8(4))
        );
    }

    function test_navValid_everyEntryPathMintsAtTheFairPrice() public {
        (bool valid,) = core.navStatus();
        assertTrue(valid);
        uint256 fairShares = core.previewDeposit(DEPOSIT);
        uint256 supplyBefore = core.totalSupply();

        assertEq(_deposit(carol, DEPOSIT), fairShares);
        vm.prank(carol);
        _vault().deposit(DEPOSIT, carol, fairShares);
        vm.prank(carol);
        _vault().depositFor(DEPOSIT, carol);
        vm.prank(carol);
        _vault().mint(fairShares, carol);
        vm.prank(carol);
        _vault().mint(fairShares, carol, type(uint256).max);

        assertEq(core.balanceOf(carol), fairShares * 5);
        assertEq(core.totalSupply(), supplyBefore + fairShares * 5);
    }

    function test_navStale_refreshFails_depositsRejected() public {
        vm.warp(block.timestamp + 1 hours);
        bm.setWarmNav(0, uint40(block.timestamp - 1 hours), true);
        bm.setRefreshShouldRevert(true);
        (bool valid, uint8 reason) = core.navStatus();
        assertFalse(valid);
        assertEq(reason, 3);

        _expectEveryEntryPathReverts(abi.encodeWithSelector(ERC4626Module.NavStale.selector));
    }

    function test_warmNavFailed_depositsRejected() public {
        bm.setWarmNav(0, uint40(block.timestamp), false);
        bm.setRefreshShouldRevert(true);

        _expectEveryEntryPathReverts(abi.encodeWithSelector(ERC4626Module.NavInvalid.selector));
    }

    function test_strategyValuationReverts_depositsRejected() public {
        core.setStrategyRouterUnsafe(address(new RevertingNavRouter(0)));

        _expectEveryEntryPathReverts(
            abi.encodeWithSelector(ERC4626Module.NavInputInvalid.selector, uint8(4))
        );
    }

    function test_strategyUnhealthy_depositsRejected() public {
        core.setStrategyRouterUnsafe(address(new MockNavRouter(STRATEGY_ASSETS, 5)));

        _expectEveryEntryPathReverts(
            abi.encodeWithSelector(ERC4626Module.NavInputInvalid.selector, uint8(5))
        );
    }

    function test_oracleInvalid_depositsRejected() public {
        core.setStrategyRouterUnsafe(address(new MockNavRouter(STRATEGY_ASSETS, 6)));

        _expectEveryEntryPathReverts(
            abi.encodeWithSelector(ERC4626Module.NavInputInvalid.selector, uint8(6))
        );
    }

    function test_depositsReopenOnceTheNavIsValidAgain() public {
        uint256 fairShares = core.previewDeposit(DEPOSIT);
        core.setStrategyRouterUnsafe(address(new MockNavRouter(0, 4)));
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Module.NavInputInvalid.selector, uint8(4)));
        _vault().deposit(DEPOSIT, carol);

        core.setStrategyRouterUnsafe(address(new MockNavRouter(STRATEGY_ASSETS, 0)));
        assertEq(_deposit(carol, DEPOSIT), fairShares);
    }

    function test_invalidNav_forceExitStillPays_andRequestsKeepTheirOwnGate() public {
        uint256 aliceShares = core.balanceOf(alice);
        vm.prank(alice);
        core.transfer(bob, aliceShares * 9 / 10);
        core.setStrategyRouterUnsafe(address(new MockNavRouter(STRATEGY_ASSETS, 4)));
        uint256 bobRequest = core.balanceOf(bob) / 2;

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(EpochedQueueModule.NavInputInvalid.selector, uint8(4))
        );
        EpochedQueueModule(address(core)).requestEpochWithdrawal(bobRequest);

        uint256 before = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 paid = _vault().forceWithdrawAll(alice, 0);
        assertGt(paid, 0, "force exit pays");
        assertEq(IERC20(USDC).balanceOf(alice) - before, paid);
        assertEq(core.balanceOf(alice), 0, "force exit burns the position");
    }

    function testFuzz_anyRouterIssue_rejectsDepositAndMint_withoutStateChange(
        uint8 issue,
        uint256 reportedAssets,
        uint256 amount
    ) public {
        issue = uint8(bound(issue, 1, type(uint8).max));
        reportedAssets = bound(reportedAssets, 0, 10 * STRATEGY_ASSETS);
        amount = bound(amount, 1, 1_000_000e6);
        uint256 shares = core.previewDeposit(amount);
        core.setStrategyRouterUnsafe(address(new MockNavRouter(reportedAssets, issue)));
        Snapshot memory before = _snapshot();

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Module.NavInputInvalid.selector, issue));
        _vault().deposit(amount, carol);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Module.NavInputInvalid.selector, issue));
        _vault().mint(shares + 1, carol);

        _assertUnchanged(before);
    }
}
