// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBufferManager } from "src/interfaces/IBufferManager.sol";
import { IStrategyRouter } from "src/interfaces/IStrategyRouter.sol";
import { CoreHarness } from "test/helpers/CoreHarness.sol";
import { MockBufferManagerForTests } from "test/helpers/MockBufferManagerForTests.sol";
import { ForceWithdrawBaseTest, IForceWithdraw } from "./ForceWithdrawBase.t.sol";

contract ForceWithdraw_Reentrancy_Test is ForceWithdrawBaseTest {
    function test_forceWithdraw_refillCallbackCannotReenter() public {
        MaliciousRefillBufferManager malBm =
            new MaliciousRefillBufferManager(address(vault), address(usdc), user, receiver);

        deal(address(usdc), address(vault), 0);
        deal(address(usdc), address(malBm), 1000e6);
        malBm.setWarmNav(1000e6, uint40(block.timestamp), true);
        CoreHarness(payable(address(vault))).setBufferManagerUnsafe(address(malBm));

        vm.prank(user);
        uint256 spent =
            IForceWithdraw(address(vault)).forceWithdraw(100e6, receiver, user, _createEmptyPlan(), type(uint256).max);

        assertTrue(malBm.reentryAttempted(), "refill callback not triggered");
        assertTrue(malBm.reentryBlocked(), "reentrancy was not blocked");
        assertEq(malBm.lastReentrySelector(), bytes4(keccak256("ReentrancyGuardLocked()")));
        assertEq(usdc.balanceOf(receiver), 100e6, "receiver payout mismatch");
        assertGt(spent, 0, "shares should be spent");
    }

    function test_forceWithdraw_routerCallbackCannotReenter() public {
        MockBufferManagerForTests zeroWarm = new MockBufferManagerForTests(address(vault));
        CoreHarness(payable(address(vault))).setBufferManagerUnsafe(address(zeroWarm));

        MaliciousRedeemRouter malRouter =
            new MaliciousRedeemRouter(address(vault), address(usdc), user, receiver);
        CoreHarness(payable(address(vault))).setStrategyRouterUnsafe(address(malRouter));

        deal(address(usdc), address(vault), 0);
        deal(address(usdc), address(malRouter), 1000e6);
        malRouter.setTotalStrategyAssets(1000e6);

        IStrategyRouter.Pull[] memory plan = _createPlan(malRouter.strategy(), 100e6);
        vm.prank(user);
        uint256 spent =
            IForceWithdraw(address(vault)).forceWithdraw(100e6, receiver, user, plan, type(uint256).max);

        assertTrue(malRouter.reentryAttempted(), "router callback not triggered");
        assertTrue(malRouter.reentryBlocked(), "reentrancy was not blocked");
        assertEq(malRouter.lastReentrySelector(), bytes4(keccak256("ReentrancyGuardLocked()")));
        assertEq(usdc.balanceOf(receiver), 100e6, "receiver payout mismatch");
        assertGt(spent, 0, "shares should be spent");
    }
}

contract MaliciousRefillBufferManager is IBufferManager {
    address public immutable vault;
    address public immutable assetToken;
    address public immutable owner_;
    address public immutable receiver_;

    uint256 internal nav;
    uint40 internal ts;
    bool internal valid = true;

    bool public reentryAttempted;
    bool public reentryBlocked;
    bytes4 public lastReentrySelector;

    constructor(address vault_, address asset_, address ownerAddr_, address receiverAddr_) {
        vault = vault_;
        assetToken = asset_;
        owner_ = ownerAddr_;
        receiver_ = receiverAddr_;
        ts = uint40(block.timestamp);
    }

    function setWarmNav(uint256 nav_, uint40 ts_, bool valid_) external {
        nav = nav_;
        ts = ts_;
        valid = valid_;
    }

    function getConfig() external view returns (BufferConfig memory cfg) {
        cfg.asset = assetToken;
    }

    function warmNavState() external view returns (uint256, uint40, bool) {
        return (nav, ts, valid);
    }

    function refill(uint256 amount) external {
        reentryAttempted = true;
        try IForceWithdraw(vault).forceWithdraw(
            1e6, receiver_, owner_, new IStrategyRouter.Pull[](0), type(uint256).max
        ) {
            revert("reentry unexpectedly succeeded");
        } catch (bytes memory reason) {
            reentryBlocked = true;
            if (reason.length >= 4) lastReentrySelector = bytes4(reason);
        }

        IERC20(assetToken).transfer(vault, amount);
        nav = nav > amount ? nav - amount : 0;
        ts = uint40(block.timestamp);
    }

    function hotBalance() external pure returns (uint256) { return 0; }
    function warmBalance() external view returns (uint256) { return nav; }
    function totalBuffer() external view returns (uint256) { return nav; }
    function plan() external pure returns (uint256, uint256) { return (0, 0); }
    function rebalance() external {}
    function canRebalance() external pure returns (bool) { return false; }
    function refreshWarmNav() external { ts = uint40(block.timestamp); }
    function forceRefill(uint256) external returns (bool, uint256) { return (false, 0); }
    function realizeForReserveAndOps(uint256) external returns (uint256) { return 0; }
    function prepareDeploy() external pure returns (uint256) { return 0; }
    function executeDeploy(uint256) external {}
    function updateConfig(BufferConfig calldata) external {}
    function setPaused(bool) external {}
    function getWarmAdapters() external pure returns (address[] memory) {
        return new address[](0);
    }
    function addWarmAdapter(address) external {}
    function removeWarmAdapter(uint256) external {}
    function setWarmAdapters(address[] calldata) external {}
}

contract MaliciousRedeemRouter {
    address public immutable vault;
    address public immutable assetToken;
    address public immutable owner_;
    address public immutable receiver_;
    address public immutable strategyAddr;

    uint256 public totalStrategyAssets;
    bool public reentryAttempted;
    bool public reentryBlocked;
    bytes4 public lastReentrySelector;

    constructor(address vault_, address asset_, address ownerAddr_, address receiverAddr_) {
        vault = vault_;
        assetToken = asset_;
        owner_ = ownerAddr_;
        receiver_ = receiverAddr_;
        strategyAddr = address(uint160(uint256(keccak256("malicious-router-strategy"))));
    }

    function strategy() external view returns (address) {
        return strategyAddr;
    }

    function setTotalStrategyAssets(uint256 assets_) external {
        totalStrategyAssets = assets_;
    }

    function isStrategyEnabled(address strat) external view returns (bool) {
        return strat == strategyAddr;
    }

    function executeRedeemBatch(IStrategyRouter.Pull[] calldata plan)
        external
        returns (uint256 got, uint256 loss)
    {
        reentryAttempted = true;
        try IForceWithdraw(vault).forceWithdraw(
            1e6, receiver_, owner_, new IStrategyRouter.Pull[](0), type(uint256).max
        ) {
            revert("reentry unexpectedly succeeded");
        } catch (bytes memory reason) {
            reentryBlocked = true;
            if (reason.length >= 4) lastReentrySelector = bytes4(reason);
        }

        for (uint256 i = 0; i < plan.length; i++) {
            IERC20(assetToken).transfer(vault, plan[i].amount);
            got += plan[i].amount;
        }
        totalStrategyAssets = totalStrategyAssets > got ? totalStrategyAssets - got : 0;
        loss = 0;
    }

    function totalStrategyAssetsSafe() external view returns (uint256) {
        return totalStrategyAssets;
    }
}
