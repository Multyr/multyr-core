// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// Every consumer of the vault's hot balance must respect reservedForClaims.
//
// The first reservation pass guarded three consumers (fundEpoch, _canInstant,
// the strategy deploy path) and missed two more: the force-exit pair in
// ERC4626Module, and the warm-buffer deploy, which pulls straight out of the
// vault under the standing allowance from CoreVault.approveWarmAdapters() and
// therefore never touches a module-level check at all.
//
// The force-exit cases below are the reviewer's proof-of-concept with the
// assertions inverted: what used to demonstrate an unpayable claimant now
// asserts that the claimant is paid in full.
//
// Also covers the release half of the reservation lifecycle, which the first
// pass never asserted: reserve without release is the mirror-image failure
// (capital locked up forever) and no test written against the original bug
// would catch it.
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";
import { StrategyMock } from "../../helpers/StrategyMock.sol";
import { ERC4626Module } from "../../../src/core/modules/ERC4626Module.sol";
import { EpochedQueueModule, EpochQueueStorage } from "../../../src/core/modules/EpochedQueueModule.sol";
import { IStrategyRouter } from "../../../src/interfaces/IStrategyRouter.sol";
import { BufferManager } from "../../../src/core/modules/BufferManager.sol";
import { IBufferManager } from "../../../src/interfaces/IBufferManager.sol";

interface IReservationQueue {
    function requestInstantWithdrawal(uint256 shares)
        external returns (bool settledImmediately, uint256 epochId, uint256 claimId);
    function requestEpochWithdrawal(uint256 shares) external returns (uint256 epochId, uint256 claimId);
    function cancelEpochWithdrawal(uint256 epochId, uint256 claimId) external;
    function closeCurrentEpoch() external;
    function fundEpoch(uint256 epochId) external;
    function claimEpochAssets(uint256 epochId, uint256 claimId) external returns (uint256 assets);
    function batchClaimEpochAssets(uint256 epochId, uint256[] calldata claimIds)
        external returns (uint256 totalAssets);
    function currentEpochId() external view returns (uint256);
    function outstandingClaimCount() external view returns (uint256);
    function totalEscrowedShares() external view returns (uint256);
    function reservedForClaims() external view returns (uint256);
    function closedPendingAssets() external view returns (uint256);
    function epochData(uint256 epochId) external view returns (EpochQueueStorage.EpochData memory);
}

interface IForceExit {
    function forceWithdrawAll(address receiver, uint256 minAssetsOut)
        external returns (uint256 assetsReceived);
}

interface ICanDeployView {
    function canDeploy() external view returns (bool);
}

contract ReservationConsumers is Test {
    CoreHarness public vault;
    ERC20Mock public usdc;
    MockParamsProvider public params;
    MockBufferManagerForTests public bufferManager;

    address public feeCollector = address(0xFEE);
    address public alice = address(0xA001);
    address public bob = address(0xB002);

    uint256 internal t;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        params = new MockParamsProvider();
        params.setLockPeriod(0);
        params.setCapPerEpochBps(10000);

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)), "Vault", "vUSDC",
            address(this), feeCollector, address(params)
        );
        bufferManager = new MockBufferManagerForTests(address(vault));
        vault.setBufferManagerUnsafe(address(bufferManager));
        vault.setFeeParamsUnsafe(0, 25, feeCollector);
        vault.setExitFeesUnsafe(25, 50, 150);
        vault.setEpochDurationUnsafe(7 days);
        vault.unpause();

        usdc._mint(alice, 100_000_000e6);
        usdc._mint(bob, 100_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);

        t = block.timestamp;
    }

    function _q() internal view returns (IReservationQueue) {
        return IReservationQueue(address(vault));
    }

    function _dep(address who, uint256 a) internal returns (uint256) {
        vm.prank(who);
        return vault.deposit(a, who);
    }

    function _hot() internal view returns (uint256) {
        return usdc.balanceOf(address(vault));
    }

    function _warp(uint256 d) internal {
        t += d;
        vm.warp(t);
    }

    /// @dev Queue alice's whole position, close, fund. Returns her claim handle.
    function _fundAliceEpoch(uint256 shares) internal returns (uint256 epochId, uint256 claimId) {
        vm.prank(alice);
        (epochId, claimId) = _q().requestEpochWithdrawal(shares);
        _warp(7 days + 1);
        _q().closeCurrentEpoch();
        _q().fundEpoch(epochId);
        assertTrue(
            _q().epochData(epochId).state == EpochQueueStorage.EpochState.Funded,
            "setup: epoch must be funded"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FORCE EXIT — the two consumers the first reservation pass missed
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Regression: forceWithdrawAll after a NAV drop used to spend past
    ///         the reservation and leave the funded claimant unpayable.
    function test_forceWithdrawAll_cannotSpendPastTheReservation() public {
        uint256 aliceShares = _dep(alice, 1_000_000e6);
        _dep(bob, 1_000_000e6);

        (uint256 e0, uint256 c0) = _fundAliceEpoch(aliceShares);
        uint256 reserved = _q().reservedForClaims();
        assertGt(reserved, 0, "alice's payout is reserved");

        // 50% NAV loss AFTER epoch 0 was funded: alice's ppsAtClose is already
        // locked at the pre-loss price, so her liability now exceeds her
        // proportional share of what is left.
        uint256 loss = _hot() / 2;
        vm.prank(address(vault));
        usdc.transfer(makeAddr("blackhole"), loss);

        vm.prank(bob);
        IForceExit(address(vault)).forceWithdrawAll(bob, 0);

        assertGe(
            _hot(), _q().reservedForClaims(),
            "hot must still cover the reservation after a force exit"
        );

        // The whole point: alice is paid, in full, at her locked price.
        vm.prank(alice);
        uint256 paid = _q().claimEpochAssets(e0, c0);
        assertEq(paid, reserved, "funded claimant paid in full at ppsAtClose");
        assertEq(_q().reservedForClaims(), 0, "reservation released on payout");
    }

    /// @notice A force exit with zero free liquidity is a no-op fill, not a
    ///         raid on the reservation.
    function test_forceWithdrawAll_withZeroFreeLiquidity_deliversNothing() public {
        uint256 aliceShares = _dep(alice, 1_000_000e6);
        _dep(bob, 1_000_000e6);

        (uint256 e0, uint256 c0) = _fundAliceEpoch(aliceShares);

        // Drain hot down to exactly the reservation.
        uint256 drain = _hot() - _q().reservedForClaims();
        vm.prank(address(vault));
        usdc.transfer(makeAddr("elsewhere"), drain);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 got = IForceExit(address(vault)).forceWithdrawAll(bob, 0);

        assertEq(got, 0, "nothing free to hand out");
        assertEq(usdc.balanceOf(bob), bobBefore, "bob received nothing");
        assertEq(vault.balanceOf(bob), 1_000_000e6, "bob keeps his shares for later");

        vm.prank(alice);
        _q().claimEpochAssets(e0, c0);
    }

    /// @notice forceWithdraw asks for an exact amount, so a shortfall against
    ///         free liquidity is an explicit revert rather than a silent raid.
    function test_forceWithdraw_revertsWhenItWouldDipIntoTheReservation() public {
        uint256 aliceShares = _dep(alice, 1_000_000e6);
        _dep(bob, 1_000_000e6);

        (uint256 e0, uint256 c0) = _fundAliceEpoch(aliceShares);

        uint256 drain = _hot() - _q().reservedForClaims();
        vm.prank(address(vault));
        usdc.transfer(makeAddr("elsewhere"), drain);

        // forceWithdraw is not wired by CoreHarness, so route it explicitly.
        vault.setModule(
            ERC4626Module.forceWithdraw.selector, address(vault.erc4626Module()), vault.ROLE_PUBLIC()
        );

        IStrategyRouter.Pull[] memory emptyPlan = new IStrategyRouter.Pull[](0);
        vm.prank(bob);
        vm.expectRevert(ERC4626Module.InsufficientFreeLiquidity.selector);
        ERC4626Module(address(vault)).forceWithdraw(
            100e6, bob, bob, emptyPlan, type(uint256).max
        );

        vm.prank(alice);
        _q().claimEpochAssets(e0, c0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // WARM BUFFER — reserved cash is not deployable warm either
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice BufferManager.plan() sizes needDeploy off FREE liquidity. Warm
    ///         adapters pull directly from the vault under a standing
    ///         allowance, so a raw-hot plan would move reserved cash out with
    ///         no module-level check able to see it.
    function test_bufferPlan_excludesReservedCashFromNeedDeploy() public {
        // The real BufferManager, not the test mock: plan() is the function
        // under test and the mock stubs it out.
        BufferManager real = new BufferManager(
            address(this),
            address(vault),
            IBufferManager.BufferConfig({
                targetHotBps: 300,
                minHotBps: 200,
                targetWarmBps: 700,
                maxWarmBps: 1000,
                opsReserveTargetBps: 100,
                maxWarmSlippageBps: 50,
                asset: address(usdc),
                warmAdapter: address(0),
                twapWindowSec: 0,
                paused: false
            })
        );

        uint256 aliceShares = _dep(alice, 1_000_000e6);
        _dep(bob, 1_000_000e6);

        (, uint256 deployBefore) = real.plan();
        assertGt(deployBefore, 0, "baseline: surplus is deployable to warm");

        _fundAliceEpoch(aliceShares);

        // Drain hot to exactly the reservation: zero free liquidity remains.
        uint256 drain = _hot() - _q().reservedForClaims();
        vm.prank(address(vault));
        usdc.transfer(makeAddr("elsewhere"), drain);

        (, uint256 deployAfter) = real.plan();
        assertEq(deployAfter, 0, "nothing deployable once all hot cash is reserved");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FIXED MATURITY — the mode switch may not strand a funded claimant
    // ═════════════════════════════════════════════════════════════════════════

    function test_setVaultModeFixedMaturity_blockedWhileClaimsOutstanding() public {
        _dep(alice, 1_000_000e6);
        vm.prank(alice);
        _q().requestEpochWithdrawal(100_000e6);

        vm.expectRevert();
        IFixedMaturityMode(address(vault)).setVaultModeFixedMaturity();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // RELEASE — the half the first pass never asserted
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Ten full request/close/fund/claim cycles with a moving price.
    ///         Everything must drain back, bar the documented truncation dust.
    function test_reservationReleases_overTenFullCycles() public {
        _dep(alice, 10_000_000e6);
        _dep(bob, 10_000_000e6);

        for (uint256 i = 0; i < 10; i++) {
            // Push pps off an exact 1.0 so the reserve/release rounding is
            // genuinely exercised (mulWadDown is exact at pps == 1e18).
            usdc._mint(address(vault), 137_777e6 + i * 911e6);

            vm.prank(alice);
            (uint256 e, uint256 cA) = _q().requestEpochWithdrawal(100_000e6);
            vm.prank(bob);
            (, uint256 cB) = _q().requestEpochWithdrawal(70_000e6);

            _warp(7 days + 1);
            _q().closeCurrentEpoch();
            _q().fundEpoch(e);

            uint256 aliceBefore = usdc.balanceOf(alice);
            vm.prank(alice);
            uint256 paidA = _q().claimEpochAssets(e, cA);
            assertEq(usdc.balanceOf(alice) - aliceBefore, paidA, "alice received what she was owed");

            uint256 bobBefore = usdc.balanceOf(bob);
            vm.prank(bob);
            uint256 paidB = _q().claimEpochAssets(e, cB);
            assertEq(usdc.balanceOf(bob) - bobBefore, paidB, "bob received what he was owed");
        }

        assertEq(_q().outstandingClaimCount(), 0, "no claims outstanding");
        assertEq(_q().totalEscrowedShares(), 0, "escrow drained");
        assertEq(_q().closedPendingAssets(), 0, "closed-pending liability cleared");
        assertLe(
            _q().reservedForClaims(), 10,
            "reservation drains back to at most the documented per-epoch truncation dust"
        );
    }

    /// @notice Same, with cancellations interleaved and an empty epoch closed
    ///         and funded in the middle.
    function test_reservationReleases_withCancellationsAndEmptyEpochs() public {
        _dep(alice, 10_000_000e6);
        _dep(bob, 10_000_000e6);

        for (uint256 i = 0; i < 5; i++) {
            usdc._mint(address(vault), 91_313e6 + i * 707e6);

            vm.prank(alice);
            (uint256 e, uint256 cA) = _q().requestEpochWithdrawal(100_000e6);
            vm.prank(bob);
            (, uint256 cB) = _q().requestEpochWithdrawal(60_000e6);
            vm.prank(bob);
            _q().cancelEpochWithdrawal(e, cB);

            _warp(7 days + 1);
            _q().closeCurrentEpoch();
            _q().fundEpoch(e);

            uint256 before = usdc.balanceOf(alice);
            vm.prank(alice);
            uint256 paid = _q().claimEpochAssets(e, cA);
            assertEq(usdc.balanceOf(alice) - before, paid, "alice paid the claimed amount");

            uint256 empty = _q().currentEpochId();
            _warp(7 days + 1);
            _q().closeCurrentEpoch();
            _q().fundEpoch(empty);
        }

        assertEq(_q().outstandingClaimCount(), 0, "no claims outstanding");
        assertEq(_q().totalEscrowedShares(), 0, "escrow drained");
        assertEq(_q().reservedForClaims(), 0, "single-claim epochs release exactly");
        assertEq(_q().closedPendingAssets(), 0, "empty epochs add no liability");
    }

    /// @notice The batch path must release exactly what the single path does.
    function test_reservationReleases_viaBatchClaim() public {
        _dep(alice, 10_000_000e6);
        usdc._mint(address(vault), 333_333e6);

        vm.prank(alice);
        (uint256 e, uint256 c1) = _q().requestEpochWithdrawal(100_000e6);
        vm.prank(alice);
        (, uint256 c2) = _q().requestEpochWithdrawal(70_000e6);
        vm.prank(alice);
        (, uint256 c3) = _q().requestEpochWithdrawal(33_333e6);

        _warp(7 days + 1);
        _q().closeCurrentEpoch();
        _q().fundEpoch(e);

        uint256[] memory ids = new uint256[](3);
        ids[0] = c1;
        ids[1] = c2;
        ids[2] = c3;

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 total = _q().batchClaimEpochAssets(e, ids);

        assertEq(usdc.balanceOf(alice) - before, total, "alice received the batch total");
        assertEq(_q().outstandingClaimCount(), 0, "all three claims settled");
        assertLe(_q().reservedForClaims(), 10, "batch release matches the single path");
    }

    /// @notice After a clean run the vault must still be operable: deployable
    ///         surplus and instant exits must not be permanently suppressed.
    function test_vaultRemainsOperableAfterCycles() public {
        StrategyMock strat = new StrategyMock(address(usdc));
        vault.addStrategyUnsafe(address(strat));
        t = block.timestamp; // addStrategyUnsafe warps and restores; resync

        _dep(alice, 10_000_000e6);
        _dep(bob, 10_000_000e6);

        for (uint256 i = 0; i < 10; i++) {
            usdc._mint(address(vault), 137_777e6 + i * 911e6);
            vm.prank(alice);
            (uint256 e, uint256 cA) = _q().requestEpochWithdrawal(100_000e6);
            _warp(7 days + 1);
            _q().closeCurrentEpoch();
            _q().fundEpoch(e);
            vm.prank(alice);
            _q().claimEpochAssets(e, cA);
        }

        assertTrue(ICanDeployView(address(vault)).canDeploy(), "surplus still deployable");

        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        (bool settled,,) = _q().requestInstantWithdrawal(1_000e6);
        assertTrue(settled, "instant exit still available");
        assertGt(usdc.balanceOf(bob), before, "and it actually delivered assets");
    }
}

interface IFixedMaturityMode {
    function setVaultModeFixedMaturity() external;
}
