// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreVault } from "src/core/CoreVault.sol";
import { AdminModule } from "src/core/modules/AdminModule.sol";
import { ERC4626Module } from "src/core/modules/ERC4626Module.sol";
import { StrategyRouter } from "src/core/modules/StrategyRouter.sol";
import { SelectorLib } from "src/core/libraries/SelectorLib.sol";
import { ERC20Mock } from "src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "test/helpers/MockParamsProvider.sol";
import { IBufferManager } from "src/interfaces/IBufferManager.sol";
import { IStrategyRouter } from "src/interfaces/IStrategyRouter.sol";
import { IAdminModule } from "src/interfaces/IAdminModule.sol";
import { CoreHarness } from "test/helpers/CoreHarness.sol";
import { MockBufferManagerForTests } from "test/helpers/MockBufferManagerForTests.sol";

/// @notice Interface for forceWithdraw (routed via ERC4626Module)
interface IForceWithdraw {
    function forceWithdraw(
        uint256 assets,
        address receiver,
        address owner_,
        IStrategyRouter.Pull[] calldata plan,
        uint256 maxShares
    ) external returns (uint256 sharesSpent);
}

/**
 * @title ForceWithdrawBaseTest
 * @notice Base test contract for forceWithdraw functionality
 * @dev Sets up a complete vault with ERC4626Module and forceWithdraw support
 */
contract ForceWithdrawBaseTest is Test {
    CoreVault public vault;
    AdminModule public adminModule;
    ERC4626Module public erc4626Module;
    StrategyRouter public router;
    MockParamsProvider public params;
    ERC20Mock public usdc;

    address public owner = address(0x1);
    address public feeCollector = address(0x2);
    address public user = address(0x3);
    address public receiver = address(0x4);

    // Default fee parameters
    uint16 constant DEFAULT_WIT_BPS = 25; // 0.25%
    uint16 constant DEFAULT_FORCE_EXIT_BPS = 150; // 1.5%

    function setUp() public virtual {
        // Deploy mocks
        usdc = new ERC20Mock("USDC", "USDC", 6);
        params = new MockParamsProvider();

        // Deploy CoreVault (via CoreHarness for setBufferManagerUnsafe)
        CoreHarness _harness = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Test Vault",
            "vTEST",
            owner,
            feeCollector,
            address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(_harness));
        _harness.setBufferManagerUnsafe(address(mockBM));
        vault = _harness;

        // Deploy modules
        adminModule = new AdminModule();
        erc4626Module = new ERC4626Module();

        // Deploy StrategyRouter
        router = new StrategyRouter(owner, address(vault), address(params));

        // Wire up modules
        _wireModules();

        // Setup initial fees
        vm.prank(owner);
        IAdminModule(address(vault))
            .setInitialFees(
                0, // depBps
                DEFAULT_WIT_BPS, // witBps
                100, // immediateExitPenaltyBps
                DEFAULT_FORCE_EXIT_BPS, // forceExitPenaltyBps
                feeCollector
            );

        // Fund user and deposit
        _setupUserWithDeposit(1000e6);
    }

    function _wireModules() internal {
        vm.startPrank(owner);

        // AdminModule selectors (OWNER)
        bytes4[] memory adminOwnerSels = SelectorLib.getAdminModuleOwnerSelectors();
        for (uint256 i = 0; i < adminOwnerSels.length; i++) {
            vault.setModule(adminOwnerSels[i], address(adminModule), SelectorLib.ROLE_OWNER);
        }

        // AdminModule view selectors (PUBLIC)
        bytes4[] memory adminViewSels = SelectorLib.getAdminModuleViewSelectors();
        for (uint256 i = 0; i < adminViewSels.length; i++) {
            vault.setModule(adminViewSels[i], address(adminModule), SelectorLib.ROLE_PUBLIC);
        }

        // ERC4626Module selectors (PUBLIC)
        bytes4[] memory erc4626Sels = SelectorLib.getERC4626ModuleSelectors();
        for (uint256 i = 0; i < erc4626Sels.length; i++) {
            vault.setModule(erc4626Sels[i], address(erc4626Module), SelectorLib.ROLE_PUBLIC);
        }

        // Set router
        IAdminModule(address(vault)).setRouter(address(router));

        vm.stopPrank();
    }

    function _setupUserWithDeposit(uint256 amount) internal {
        usdc._mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _createPlan(address strat, uint256 amount)
        internal
        pure
        returns (IStrategyRouter.Pull[] memory)
    {
        IStrategyRouter.Pull[] memory plan = new IStrategyRouter.Pull[](1);
        plan[0] = IStrategyRouter.Pull({ strat: strat, amount: amount });
        return plan;
    }

    function _createEmptyPlan() internal pure returns (IStrategyRouter.Pull[] memory) {
        return new IStrategyRouter.Pull[](0);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MOCK ROUTER VARIANTS FOR FORCE WITHDRAW TESTING
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * @notice Mock router that succeeds on executeRedeemBatch
 */
contract MockSuccessRouter {
    address public core;
    address public asset;
    MockStrategy public strategy;

    constructor(address _core, address _asset) {
        core = _core;
        asset = _asset;
        strategy = new MockStrategy(_asset);
    }

    function isStrategyEnabled(address strat) external view returns (bool) {
        return strat == address(strategy);
    }

    function executeRedeemBatch(IStrategyRouter.Pull[] calldata plan)
        external
        returns (uint256 got, uint256 loss)
    {
        // Simulate successful withdrawal by transferring from strategy to core
        for (uint256 i = 0; i < plan.length; i++) {
            IERC20(asset).transfer(core, plan[i].amount);
            got += plan[i].amount;
        }
        loss = 0;
    }

    function list() external view returns (IStrategyRouter.StrategyInfo[] memory infos) {
        infos = new IStrategyRouter.StrategyInfo[](1);
        infos[0] = IStrategyRouter.StrategyInfo({
            strat: address(strategy), enabled: true, priority: 0, weightBps: 10000
        });
    }

    function totalStrategyAssetsSafe() external view returns (uint256) {
        return strategy.totalAssets();
    }
}

/**
 * @notice Mock router that reverts with LossCapExceeded (CRITICAL)
 */
contract MockLossCapRouter {
    MockStrategy public strategyContract;
    address public strategy;

    error LossCapExceeded(address strat, uint256 expected, uint256 received, uint256 lossBps);

    constructor(address _asset) {
        strategyContract = new MockStrategy(_asset);
        strategy = address(strategyContract);
    }

    function isStrategyEnabled(address strat) external view returns (bool) {
        return strat == strategy;
    }

    function executeRedeemBatch(IStrategyRouter.Pull[] calldata)
        external
        view
        returns (uint256, uint256)
    {
        revert LossCapExceeded(strategy, 1000, 900, 1000);
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

/**
 * @notice Mock router that reverts with AggregatedLossCapExceeded (CRITICAL)
 */
contract MockAggregatedLossCapRouter {
    MockStrategy public strategyContract;
    address public strategy;

    error AggregatedLossCapExceeded(uint256 requested, uint256 received, uint256 lossBps);

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
        revert AggregatedLossCapExceeded(1000, 900, 1000);
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

/**
 * @notice Mock router that reverts with generic error (non-critical)
 */
contract MockGenericRevertRouter {
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
        revert("GENERIC_ERROR");
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

/**
 * @notice Mock router with disabled strategy
 */
contract MockDisabledStrategyRouter {
    MockStrategy public strategyContract;
    address public strategy;

    constructor(address _asset) {
        strategyContract = new MockStrategy(_asset);
        strategy = address(strategyContract);
    }

    function isStrategyEnabled(address) external pure returns (bool) {
        return false; // Always disabled
    }

    function executeRedeemBatch(IStrategyRouter.Pull[] calldata)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    function list() external view returns (IStrategyRouter.StrategyInfo[] memory infos) {
        infos = new IStrategyRouter.StrategyInfo[](1);
        infos[0] = IStrategyRouter.StrategyInfo({
            strat: strategy, enabled: false, priority: 0, weightBps: 10000
        });
    }

    function totalStrategyAssetsSafe() external pure returns (uint256) {
        return 0;
    }
}

/**
 * @notice Simple mock strategy
 */
contract MockStrategy {
    address public asset;
    uint256 public totalAssets_;

    constructor(address _asset) {
        asset = _asset;
    }

    function totalAssets() external view returns (uint256) {
        return totalAssets_;
    }

    function setTotalAssets(uint256 _amount) external {
        totalAssets_ = _amount;
    }

    function name() external pure returns (string memory) {
        return "MockStrategy";
    }

    function deposit(uint256) external pure returns (uint256) {
        return 0;
    }

    function withdraw(uint256 amount, address to) external returns (uint256) {
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    function withdrawAll(address) external pure returns (uint256) {
        return 0;
    }

    function harvest() external pure returns (int256, uint256) {
        return (0, 0);
    }
    function setActive(bool) external pure { }

    function isActive() external pure returns (bool) {
        return true;
    }
}
