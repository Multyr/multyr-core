// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// An adapter returns LESS than was asked for. No hack: withdrawal slippage, share rounding, a market
// paying out a little short. On the Arbitrum fork the live Fluid/Venus/Euler stack answered a
// 1,218,285-unit realise with 1,213,315.
//
// What has to hold, with real numbers (Alice and Bob 500 each, Alice exits all 500, the cash is in the
// strategy, the strategy pays out `shortfall` less than asked):
//   * Alice's claim is a fixed 500. The slippage is a loss of the VAULT, so it is borne by Bob.
//   * If the shortfall is within the router's loss cap, funding pulls what it can and simply RETRIES:
//     each call recognises the slippage and pulls the remaining deficit, so it converges.
//   * If the shortfall is beyond the router's loss cap the router refuses the withdrawal outright (it
//     reverts, nothing moves). Funding stays blocked and SAFE until governance raises the cap or uses
//     the emergency redeem -- documented and tested here, because it is the one place a claim can wait.
//   * If it happens while the vault is insolvent the index simply drops with each recognised shortfall
//     and funding converges at the new, lower, recovery ratio.
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockUSDC } from "../../helpers/MockUSDC.sol";
import { IStrategyVaultLike } from "../../helpers/StrategyMock.sol";
import { ERC4626Module } from "../../../src/core/modules/ERC4626Module.sol";
import { EpochedQueueModule, EpochQueueStorage } from "../../../src/core/modules/EpochedQueueModule.sol";
import { StrategyRouter } from "../../../src/core/modules/StrategyRouter.sol";
import { CoreStorage } from "../../../src/core/storage/CoreStorage.sol";
import { IStrategyRouter } from "../../../src/interfaces/IStrategyRouter.sol";
import { MockQueueEpochParamsProvider } from "../../sprint-test/QueueEpochModule_WithdrawFlow_POC.t.sol";

/// @dev Pays out `shortBps` less than it is asked for; the difference is gone (slippage / rounding).
contract ShortPayStrategy is IStrategyVaultLike {
    using SafeERC20 for IERC20;

    address public immutable token;
    uint256 public shortBps;

    constructor(address a) {
        token = a;
    }

    function setShortBps(uint256 b) external {
        shortBps = b;
    }

    function asset() external view returns (address) {
        return token;
    }

    function totalAssets() public view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function withdrawableAssets() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function deposit(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function withdraw(uint256 assets, address receiver) external returns (uint256 sent) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 ask = assets <= bal ? assets : bal;
        sent = ask * (10_000 - shortBps) / 10_000;
        if (sent > 0) IERC20(token).safeTransfer(receiver, sent);
        uint256 lost = ask - sent;
        if (lost > 0) IERC20(token).safeTransfer(address(0xdead), lost); // the shortfall is really gone
    }

    function harvest(address) external pure returns (uint256) {
        return 0;
    }
}

contract AdapterShortfall_Test is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ORACLE = address(0x0BAC1E);
    uint256 constant WAD = 1e18;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    CoreHarness core;
    ShortPayStrategy strat;
    MockQueueEpochParamsProvider params;
    uint256 t;

    function setUp() public {
        vm.etch(USDC, address(new MockUSDC()).code);
        params = new MockQueueEpochParamsProvider();
        core = new CoreHarness(
            IERC20Metadata(USDC), "USDC Agg", "agUSDC", address(this), address(this), address(params)
        );
        core.setEpochDurationUnsafe(7 days);
        strat = new ShortPayStrategy(USDC);
        core.addStrategyUnsafe(address(strat));
        t = block.timestamp;
        _liveOracle();

        address[3] memory us = [alice, bob, carol];
        for (uint256 i; i < us.length; i++) {
            MockUSDC(USDC).mint(us[i], 1_000_000e6);
            vm.prank(us[i]);
            IERC20(USDC).approve(address(core), type(uint256).max);
        }
    }

    // The router's redeem guards need a configured, fresh oracle. Give them one so the REAL realise path runs.
    function _liveOracle() internal {
        vm.mockCall(
            address(params),
            abi.encodeWithSignature("oracleConfigFor(address,address)"),
            abi.encode(ORACLE, uint256(1 days))
        );
        vm.mockCall(
            ORACLE,
            abi.encodeWithSignature("getQuote(address)", USDC),
            abi.encode(uint256(1e18), uint8(8), uint48(block.timestamp), true)
        );
    }

    function _q() internal view returns (EpochedQueueModule) {
        return EpochedQueueModule(address(core));
    }

    function _router() internal view returns (StrategyRouter) {
        return StrategyRouter(address(core.router()));
    }

    function _deposit(address who, uint256 a) internal returns (uint256 s) {
        vm.prank(who);
        s = ERC4626Module(address(core)).deposit(a, who);
    }

    function _request(address who, uint256 shares) internal returns (uint256 e, uint256 c) {
        vm.prank(who);
        (e, c) = _q().requestEpochWithdrawal(shares);
    }

    function _hot() internal view returns (uint256) {
        return IERC20(USDC).balanceOf(address(core));
    }

    function _close() internal {
        t += 7 days + 1;
        vm.warp(t);
        _liveOracle();
        _q().closeCurrentEpoch();
    }

    function _claim(address who, uint256 e, uint256 c) internal returns (uint256) {
        vm.prank(who);
        return _q().claimEpochAssets(e, c);
    }

    function _state(uint256 e) internal view returns (EpochQueueStorage.EpochState) {
        return _q().epochData(e).state;
    }

    /// @dev Alice 500 + Bob 500; 460 of the cash is sitting in the strategy, 540 hot. Alice exits all 500.
    function _setup() internal returns (uint256 e, uint256 c, uint256 sb) {
        uint256 sa = _deposit(alice, 500e6);
        sb = _deposit(bob, 500e6);
        vm.prank(address(core));
        IERC20(USDC).transfer(address(strat), 960e6); // hot 40, strategy 960
        (e, c) = _request(alice, sa);
    }

    function _fundUntilFunded(uint256 e, uint256 maxCalls) internal returns (uint256 calls) {
        while (_state(e) != EpochQueueStorage.EpochState.Funded && calls < maxCalls) {
            _q().fundEpoch(e);
            calls++;
        }
    }

    // ═════ within the router's loss cap: retry converges, Alice untouched, Bob bears the slippage ═════

    function test_shortfallWithinLossCap_fundsInOneCall_aliceUntouched_bobBearsIt() public {
        (uint256 e, uint256 c, uint256 sb) = _setup();
        uint256 bobBefore = core.convertToAssets(sb);
        strat.setShortBps(30); // pays 0.30% short (the router's cap is 0.50%)
        _close();

        _q().fundEpoch(e);
        assertTrue(
            _state(e) == EpochQueueStorage.EpochState.Funded,
            "the redeem asks for a little more than the deficit, so normal slippage is absorbed in one call"
        );

        assertEq(_claim(alice, e, c), 500e6, "Alice is paid exactly the fixed 500");
        assertLt(core.convertToAssets(sb), bobBefore, "the slippage is the vault's loss: Bob carries it");
        assertApproxEqAbs(core.convertToAssets(sb), bobBefore - 1.5e6, 1.5e6, "and it is small (~0.3% of the pull)");
        assertEq(core.totalOwed(), 0);
    }

    /// @notice A shortfall bigger than the buffer (governance has widened the cap to 3%, the adapter pays 2%
    ///         short) is recovered by RETRIES: each call recognises the slippage and pulls the remaining
    ///         deficit, and the +1 keeps it from stalling on the last unit.
    function test_shortfallBiggerThanBuffer_retriesConverge_evenToTheLastUnit() public {
        (uint256 e, uint256 c,) = _setup();
        StrategyRouter r = _router();
        vm.prank(address(core));
        r.setLossCapBps(300);
        strat.setShortBps(200);
        _close();

        _q().fundEpoch(e);
        assertTrue(_state(e) == EpochQueueStorage.EpochState.Closed, "first call is short by ~1.5%");
        uint256 calls = _fundUntilFunded(e, 12);
        assertTrue(_state(e) == EpochQueueStorage.EpochState.Funded, "converges, no stall at a unit or two");
        assertLe(calls, 6);
        assertEq(_claim(alice, e, c), 500e6);
    }

    function test_shortfallWithinLossCap_solvencyIsNeverAffected() public {
        (uint256 e,,) = _setup();
        strat.setShortBps(45);
        _close();
        _fundUntilFunded(e, 12);
        assertFalse(core.isInsolvent(), "a small shortfall does not tip a solvent vault over");
    }

    // ═════ beyond the router's loss cap: funding is blocked and SAFE; governance unblocks it ═════

    function test_shortfallBeyondLossCap_routerRefuses_fundingStaysSafe_thenGovernanceUnblocks() public {
        (uint256 e, uint256 c,) = _setup();
        strat.setShortBps(200); // pays 2% short, cap is 0.5%
        _close();

        _q().fundEpoch(e);
        _q().fundEpoch(e);
        assertTrue(_state(e) == EpochQueueStorage.EpochState.Closed, "the router refuses a >cap withdrawal");
        assertEq(IERC20(USDC).balanceOf(address(strat)), 960e6, "and NOTHING moved: the refusal is atomic");
        assertEq(_q().reservedForClaims(), 0);
        vm.prank(alice);
        vm.expectRevert(EpochedQueueModule.EpochNotFunded.selector);
        _q().claimEpochAssets(e, c);
        assertEq(core.totalOwed(), 500e6, "the liability is intact: nobody was paid short or repriced");

        // governance accepts the slippage explicitly (owner of the router = the vault owner in this harness)
        StrategyRouter r = _router();
        vm.prank(address(core)); // the harness deploys the router with itself as owner
        r.setLossCapBps(300);
        _liveOracle();
        _fundUntilFunded(e, 12);
        assertTrue(_state(e) == EpochQueueStorage.EpochState.Funded, "unblocked");
        assertEq(_claim(alice, e, c), 500e6, "Alice is still paid the fixed amount");
    }

    function test_shortfallBeyondLossCap_emergencyRedeemBypassesTheCap() public {
        (uint256 e, uint256 c,) = _setup();
        strat.setShortBps(200);
        _close();
        _q().fundEpoch(e);
        assertTrue(_state(e) == EpochQueueStorage.EpochState.Closed);

        // owner pulls the cash with the emergency path (no loss cap), into the vault
        IStrategyRouter.Pull[] memory plan = new IStrategyRouter.Pull[](1);
        plan[0] = IStrategyRouter.Pull({ strat: address(strat), amount: 500e6 });
        StrategyRouter r = _router();
        vm.prank(address(core));
        uint256 got = r.emergencyRedeemBatch(plan);
        assertEq(got, 490e6, "2% short of 500");

        _q().fundEpoch(e);
        assertTrue(_state(e) == EpochQueueStorage.EpochState.Funded);
        assertEq(_claim(alice, e, c), 500e6);
    }

    // ═════ insolvent AND the adapter pays short ═════

    function test_insolvent_andAdapterPaysShort_indexDropsWithEachRecognisedShortfall_fundingConverges() public {
        (uint256 e, uint256 c,) = _setup();
        // a real loss first: hot cash disappears until gross < owed
        vm.prank(address(core));
        IERC20(USDC).transfer(address(0xdead), 40e6);
        vm.prank(address(strat));
        IERC20(USDC).transfer(address(0xdead), 560e6); // gross 400 (strategy) vs 500 owed
        assertTrue(core.isInsolvent());
        uint256 idx0 = core.liabilityIndex();
        assertApproxEqRel(idx0, 0.8e18, 1e12);

        strat.setShortBps(30); // and what is left comes back 0.3% short
        _close();
        uint256 calls = _fundUntilFunded(e, 12);
        assertTrue(_state(e) == EpochQueueStorage.EpochState.Funded, "funds at the (lower) recovery ratio");
        assertLe(calls, 8);

        uint256 idxNow = core.liabilityIndex();
        assertLe(idxNow, idx0 + 1e12, "the recognised shortfall can only lower the ratio (or leave it)");
        uint256 paid = _claim(alice, e, c);
        assertApproxEqRel(paid, 500e6 * idxNow / WAD, 0.002e18, "paid at the index that actually exists");
        assertLt(paid, 500e6);
        assertLe(paid, 400e6, "never more than the cash that was really left");
    }

    // ═════ every claimant sees the same shortfall ═════

    function test_shortfall_twoClaimants_bothPaidNominal_whileSolvent() public {
        uint256 sa = _deposit(alice, 300e6);
        uint256 sc = _deposit(carol, 200e6);
        _deposit(bob, 500e6);
        vm.prank(address(core));
        IERC20(USDC).transfer(address(strat), 950e6);
        (uint256 e, uint256 ca) = _request(alice, sa);
        (, uint256 cc) = _request(carol, sc);
        strat.setShortBps(25);
        _close();
        _fundUntilFunded(e, 12);
        assertTrue(_state(e) == EpochQueueStorage.EpochState.Funded);
        assertEq(_claim(carol, e, cc), 200e6);
        assertEq(_claim(alice, e, ca), 300e6);
    }
}
