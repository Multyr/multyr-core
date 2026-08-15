// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// AUTO_HARVEST fallback bookkeeping.
//
// Two defects, both introduced by the epoch cutover and both of which brick fee
// distribution for a share token with no recovery short of a governance mode
// change:
//
//   1. distribute() refused a second queued harvest for the same token, so one
//      epoch that never funded blocked the token outright.
//   2. An instant harvest that rounded down to zero underlying was routed down
//      the fallback path, where it recorded the (0, 0) sentinel that
//      requestInstantWithdrawal returns for inline settlements as if it were a
//      real claim handle -- permanently unclaimable.
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";
import { FeeCollector } from "../../../src/core/modules/FeeCollector.sol";
import { EpochQueueStorage } from "../../../src/core/modules/EpochedQueueModule.sol";

interface IHarvestQueue {
    function requestEpochWithdrawal(uint256 shares) external returns (uint256, uint256);
    function closeCurrentEpoch() external;
    function fundEpoch(uint256 epochId) external;
    function epochData(uint256 epochId) external view returns (EpochQueueStorage.EpochData memory);
    function currentEpochId() external view returns (uint256);
}

contract FeeCollectorHarvestQueue is Test {
    CoreHarness public vault;
    ERC20Mock public usdc;
    MockParamsProvider public params;
    FeeCollector public collector;

    address public gov = address(0x600D);
    address public treasury = address(0x7EA5);
    address public ops = address(0x0B5);
    address public reserve = address(0xEE5E);
    address public alice = address(0xA001);

    uint256 internal t;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        params = new MockParamsProvider();
        params.setLockPeriod(0);
        params.setCapPerEpochBps(10000);

        collector = new FeeCollector(gov, treasury, ops, reserve, 5000, 300, 5000);

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)), "Vault", "vUSDC",
            address(this), address(collector), address(params)
        );
        vault.setBufferManagerUnsafe(address(new MockBufferManagerForTests(address(vault))));
        // Exit fee only: deposits stay clean so share maths is easy to follow.
        vault.setFeeParamsUnsafe(0, 500, address(collector));
        vault.setExitFeesUnsafe(500, 500, 150);
        vault.setEpochDurationUnsafe(7 days);
        vault.unpause();

        vm.startPrank(gov);
        collector.setShareConfig(address(vault), FeeCollector.ShareMode.AUTO_HARVEST);
        collector.setMinDistribution(address(usdc), 0);
        vm.stopPrank();

        usdc._mint(alice, 100_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        t = block.timestamp;
    }

    function _q() internal view returns (IHarvestQueue) {
        return IHarvestQueue(address(vault));
    }

    function _warp(uint256 d) internal {
        t += d;
        vm.warp(t);
    }

    /// @dev Exit fee shares reach the collector in a batch at closeCurrentEpoch,
    ///      not at request time, so a full close is needed to accrue them.
    function _accrueFeeShares(uint256 shares) internal {
        vm.prank(alice);
        _q().requestEpochWithdrawal(shares);
        _warp(7 days + 1);
        _q().closeCurrentEpoch();
    }

    function test_secondQueuedHarvest_doesNotRevertDistribute() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _accrueFeeShares(200_000e6);
        assertGt(vault.balanceOf(address(collector)), 0, "collector holds fee shares");

        // Starve the instant path so the harvest must queue.
        params.setCapPerEpochBps(1);

        collector.distribute(address(vault));
        assertEq(collector.pendingHarvestClaimCount(address(vault)), 1, "first harvest queued");

        // More fee shares, and a second distribute for the same token. This is
        // the call that used to revert "harvest already queued".
        _accrueFeeShares(200_000e6);

        collector.distribute(address(vault));
        assertEq(
            collector.pendingHarvestClaimCount(address(vault)), 2,
            "second harvest queues alongside the first instead of reverting"
        );

        // Both claim handles are distinct and preserved -- the old single-slot
        // bookkeeping would have overwritten the first with the second.
        (uint256 e0, uint256 c0) = collector.pendingHarvestClaimAt(address(vault), 0);
        (uint256 e1, uint256 c1) = collector.pendingHarvestClaimAt(address(vault), 1);
        assertTrue(e0 != e1 || c0 != c1, "the two claims are tracked separately");
    }

    function test_harvestQueued_settlesReadyClaimsAndLeavesTheRest() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _accrueFeeShares(200_000e6);
        params.setCapPerEpochBps(1);

        // First harvest queues into the currently open epoch.
        uint256 epochToFund = _q().currentEpochId();
        collector.distribute(address(vault));

        // Close and fund that epoch, so the first claim becomes claimable.
        _warp(7 days + 1);
        _q().closeCurrentEpoch();
        _q().fundEpoch(epochToFund);

        // A second harvest queues into the NEXT epoch, which is still open and
        // therefore not claimable.
        _accrueFeeShares(200_000e6);
        collector.distribute(address(vault));
        assertEq(collector.pendingHarvestClaimCount(address(vault)), 2, "two queued");

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        collector.harvestQueued(address(vault));

        assertEq(
            collector.pendingHarvestClaimCount(address(vault)), 1,
            "the ready claim settled, the unfunded one stayed queued"
        );
        assertGt(
            usdc.balanceOf(treasury), treasuryBefore,
            "underlying actually reached the treasury"
        );
    }

    /// @notice An instant harvest that rounds down to zero must not record a
    ///         pending claim against the (0, 0) inline-settlement sentinel.
    function test_dustInstantHarvest_doesNotQueueAPhantomClaim() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        // One wei of shares to the collector: the instant path settles it and
        // convertToAssets rounds the payout down to zero.
        vm.prank(alice);
        vault.transfer(address(collector), 1);
        assertEq(vault.balanceOf(address(collector)), 1, "collector holds dust");

        collector.distribute(address(vault));

        assertEq(
            collector.pendingHarvestClaimCount(address(vault)), 0,
            "no phantom claim recorded for a dust settlement"
        );
        assertEq(
            collector.pendingHarvestShares(address(vault)), 0,
            "pendingHarvestShares stays clear, so distribute() is not bricked"
        );

        // And the token is still distributable afterwards.
        vm.prank(alice);
        _q().requestEpochWithdrawal(200_000e6);
        collector.distribute(address(vault));
    }
}
