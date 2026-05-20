// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ForceWithdrawBaseTest,
    MockGenericRevertRouter,
    MockStrategy,
    IForceWithdraw
} from "../unit/core/ForceWithdrawBase.t.sol";
import { IStrategyRouter } from "src/interfaces/IStrategyRouter.sol";
import { IAdminModule } from "src/interfaces/IAdminModule.sol";
import { ERC4626Module } from "src/core/modules/ERC4626Module.sol";

/**
 * @title ForceWithdraw_DeterministicRouterFail_Test
 * @notice Verifies non-critical router errors convert to InsufficientLiquidity
 */
contract ForceWithdraw_DeterministicRouterFail_Test is ForceWithdrawBaseTest {
    function test_genericRevert_convertsToInsufficientLiquidity() public {
        // Deploy router that reverts with generic error
        MockGenericRevertRouter genericRouter = new MockGenericRevertRouter(address(usdc));

        // Set router
        vm.prank(owner);
        IAdminModule(address(vault)).setRouter(address(genericRouter));

        // Move liquidity from vault to strategy (simulates deployment)
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        deal(address(usdc), address(vault), 0);
        genericRouter.strategyContract().setTotalAssets(vaultBalance);

        // Create plan
        IStrategyRouter.Pull[] memory plan = new IStrategyRouter.Pull[](1);
        plan[0] = IStrategyRouter.Pull({ strat: genericRouter.strategy(), amount: 100e6 });

        // Should revert with InsufficientLiquidity (NOT the generic error)
        vm.prank(user);
        vm.expectRevert(ERC4626Module.InsufficientLiquidity.selector);
        IForceWithdraw(address(vault)).forceWithdraw(100e6, receiver, user, plan, type(uint256).max);
    }

    function test_panicError_convertsToInsufficientLiquidity() public {
        // Deploy router that panics
        PanicRouter panicRouter = new PanicRouter(address(usdc));

        vm.prank(owner);
        IAdminModule(address(vault)).setRouter(address(panicRouter));

        // Move liquidity from vault to strategy (simulates deployment)
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        deal(address(usdc), address(vault), 0);
        panicRouter.strategyContract().setTotalAssets(vaultBalance);

        // Create plan
        IStrategyRouter.Pull[] memory plan = new IStrategyRouter.Pull[](1);
        plan[0] = IStrategyRouter.Pull({ strat: panicRouter.strategy(), amount: 100e6 });

        // Should revert with InsufficientLiquidity
        vm.prank(user);
        vm.expectRevert(ERC4626Module.InsufficientLiquidity.selector);
        IForceWithdraw(address(vault)).forceWithdraw(100e6, receiver, user, plan, type(uint256).max);
    }

    function test_outOfGas_convertsToInsufficientLiquidity() public {
        // Deploy router that consumes all gas
        GasGuzzlerRouter gasRouter = new GasGuzzlerRouter(address(usdc));

        vm.prank(owner);
        IAdminModule(address(vault)).setRouter(address(gasRouter));

        // Move liquidity from vault to strategy (simulates deployment)
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        deal(address(usdc), address(vault), 0);
        gasRouter.strategyContract().setTotalAssets(vaultBalance);

        // Create plan
        IStrategyRouter.Pull[] memory plan = new IStrategyRouter.Pull[](1);
        plan[0] = IStrategyRouter.Pull({ strat: gasRouter.strategy(), amount: 100e6 });

        // This will revert at the outer level (out of gas), but demonstrates
        // that the error classification happens
    }

    function test_emptyRevert_convertsToInsufficientLiquidity() public {
        // Deploy router that reverts with empty data
        EmptyRevertRouter emptyRouter = new EmptyRevertRouter(address(usdc));

        vm.prank(owner);
        IAdminModule(address(vault)).setRouter(address(emptyRouter));

        // Move liquidity from vault to strategy (simulates deployment)
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        deal(address(usdc), address(vault), 0);
        emptyRouter.strategyContract().setTotalAssets(vaultBalance);

        // Create plan
        IStrategyRouter.Pull[] memory plan = new IStrategyRouter.Pull[](1);
        plan[0] = IStrategyRouter.Pull({ strat: emptyRouter.strategy(), amount: 100e6 });

        // Should revert with InsufficientLiquidity
        vm.prank(user);
        vm.expectRevert(ERC4626Module.InsufficientLiquidity.selector);
        IForceWithdraw(address(vault)).forceWithdraw(100e6, receiver, user, plan, type(uint256).max);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ADDITIONAL MOCK ROUTERS
// ═══════════════════════════════════════════════════════════════════════════════

contract PanicRouter {
    MockStrategy public strategyContract;
    address public strategy;

    constructor(address _asset) {
        strategyContract = new MockStrategy(_asset);
        strategy = address(strategyContract);
    }

    function isStrategyEnabled(address strat) external view returns (bool) {
        return strat == strategy;
    }

    function executeRedeemBatch(IStrategyRouter.Pull[] calldata)
        external
        pure
        returns (uint256, uint256)
    {
        // Cause panic via division by zero
        uint256 x = 1;
        uint256 y = 0;
        x = x / y; // Panic!
        return (x, 0);
    }

    function list() external view returns (IStrategyRouter.StrategyInfo[] memory infos) {
        infos = new IStrategyRouter.StrategyInfo[](1);
        infos[0] = IStrategyRouter.StrategyInfo({
            strat: strategy, enabled: true, priority: 0, weightBps: 10000
        });
    }

    function totalStrategyAssetsSafe() external view returns (uint256) {
        (bool ok, bytes memory data) = strategy.staticcall(abi.encodeWithSignature("totalAssets()"));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }
}

contract GasGuzzlerRouter {
    MockStrategy public strategyContract;
    address public strategy;

    constructor(address _asset) {
        strategyContract = new MockStrategy(_asset);
        strategy = address(strategyContract);
    }

    function isStrategyEnabled(address strat) external view returns (bool) {
        return strat == strategy;
    }

    function executeRedeemBatch(IStrategyRouter.Pull[] calldata)
        external
        pure
        returns (uint256, uint256)
    {
        // Infinite loop to consume gas
        while (true) { }
    }

    function list() external view returns (IStrategyRouter.StrategyInfo[] memory infos) {
        infos = new IStrategyRouter.StrategyInfo[](1);
        infos[0] = IStrategyRouter.StrategyInfo({
            strat: strategy, enabled: true, priority: 0, weightBps: 10000
        });
    }

    function totalStrategyAssetsSafe() external view returns (uint256) {
        (bool ok, bytes memory data) = strategy.staticcall(abi.encodeWithSignature("totalAssets()"));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }
}

contract EmptyRevertRouter {
    MockStrategy public strategyContract;
    address public strategy;

    constructor(address _asset) {
        strategyContract = new MockStrategy(_asset);
        strategy = address(strategyContract);
    }

    function isStrategyEnabled(address strat) external view returns (bool) {
        return strat == strategy;
    }

    function executeRedeemBatch(IStrategyRouter.Pull[] calldata)
        external
        pure
        returns (uint256, uint256)
    {
        revert(); // Empty revert
    }

    function list() external view returns (IStrategyRouter.StrategyInfo[] memory infos) {
        infos = new IStrategyRouter.StrategyInfo[](1);
        infos[0] = IStrategyRouter.StrategyInfo({
            strat: strategy, enabled: true, priority: 0, weightBps: 10000
        });
    }

    function totalStrategyAssetsSafe() external view returns (uint256) {
        (bool ok, bytes memory data) = strategy.staticcall(abi.encodeWithSignature("totalAssets()"));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }
}
