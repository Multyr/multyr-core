// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { VaultFactory } from "../../src/factory/VaultFactory.sol";
import { CoreVault } from "../../src/core/CoreVault.sol";
import { QueueModule } from "../../src/core/modules/QueueModule.sol";
import { AdminModule } from "../../src/core/modules/AdminModule.sol";
import { ERC4626Module } from "../../src/core/modules/ERC4626Module.sol";
import { LiquidityOpsModule } from "../../src/core/modules/LiquidityOpsModule.sol";
import { IAdminModule } from "../../src/interfaces/IAdminModule.sol";
import { IQueueModule } from "../../src/interfaces/IQueueModule.sol";
import { SelectorLib } from "../../src/core/libraries/SelectorLib.sol";
import { ERC20Mock } from "../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";

import { CoreDeployHelper } from "../helpers/CoreDeployHelper.sol";
import { DeployTypes } from "../../src/libs/DeployTypes.sol";

// Mock ecosystem components
import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";
import { IStrategyRouter } from "../../src/interfaces/IStrategyRouter.sol";

/// @dev Minimal BufferManager mock for factory tests
contract MockBufferManager {
    address public immutable asset;

    constructor(address _asset) {
        asset = _asset;
    }

    function getConfig() external view returns (IBufferManager.BufferConfig memory) {
        return IBufferManager.BufferConfig({
            targetHotBps: 500,
            minHotBps: 100,
            targetWarmBps: 2000,
            maxWarmBps: 3000,
            opsReserveTargetBps: 300,
            maxWarmSlippageBps: 50,
            asset: asset,
            warmAdapter: address(0),
            twapWindowSec: 3600,
            paused: false
        });
    }

    /// @notice Returns warm NAV state for deposit validation
    /// @dev Returns (nav=0, timestamp=now, valid=true) for successful deposits
    function warmNavState() external view returns (uint256 nav, uint40 ts, bool valid) {
        return (0, uint40(block.timestamp), true);
    }

    function prepareDeploy() external pure returns (uint256) {
        return 0;
    }
    function executeDeploy(uint256) external pure { }
    function refill(uint256) external pure { }

    function hotBalance() external pure returns (uint256) {
        return 0;
    }

    function warmBalance() external pure returns (uint256) {
        return 0;
    }

    function totalBuffer() external pure returns (uint256) {
        return 0;
    }
}

/// @dev Minimal StrategyRouter mock for factory tests
contract MockStrategyRouter {
    address public immutable vault;

    constructor(address _vault) {
        vault = _vault;
    }

    function list() external pure returns (IStrategyRouter.StrategyInfo[] memory) {
        return new IStrategyRouter.StrategyInfo[](0);
    }

    function planDeposit(uint256) external pure returns (IStrategyRouter.Allocation[] memory) {
        return new IStrategyRouter.Allocation[](0);
    }

    function executeDepositBatch(IStrategyRouter.Allocation[] calldata) external pure { }

    function planRedeem(uint256) external pure returns (IStrategyRouter.Pull[] memory) {
        return new IStrategyRouter.Pull[](0);
    }

    function executeRedeemBatch(IStrategyRouter.Pull[] calldata) external pure { }

    function totalStrategyAssetsSafe() external pure returns (uint256) {
        return 0;
    }
}

/// @title VaultFactory_Integration
/// @notice Integration tests for VaultFactory deployment flow (off-chain deploy, on-chain register)
contract VaultFactory_Integration is Test {
    VaultFactory public factory;
    QueueModule public sharedQueue;
    AdminModule public sharedAdmin;
    ERC4626Module public sharedERC4626;
    LiquidityOpsModule public sharedLiquidityOps;
    ERC20Mock public usdc;
    MockParamsProvider public params;

    address public owner = makeAddr("owner");
    address public feeCollector = makeAddr("feeCollector");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");

    function setUp() public {
        factory = new VaultFactory();
        sharedQueue = new QueueModule();
        sharedAdmin = new AdminModule();
        sharedERC4626 = new ERC4626Module();
        sharedLiquidityOps = new LiquidityOpsModule();

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        usdc._mint(address(this), 10_000_000e6);
        usdc._mint(alice, 1_000_000e6);

        params = new MockParamsProvider();
    }

    function _deployAndRegister(DeployTypes.DeployConfig memory config)
        internal
        returns (DeployTypes.DeployResult memory result)
    {
        result =
            CoreDeployHelper.deploy(config, sharedQueue, sharedAdmin, sharedERC4626, sharedLiquidityOps);
        DeployTypes.VaultRegistrationConfig memory regCfg = DeployTypes.VaultRegistrationConfig({
            asset: config.asset,
            name: config.name,
            symbol: config.symbol,
            owner: config.owner,
            feeCollector: config.feeCollector
        });
        bytes memory initData = abi.encode(regCfg);
        factory.registerVault(address(result.vault), initData);
    }

    function _deployWrapper(DeployTypes.DeployConfig memory config) external {
        CoreDeployHelper.deploy(config, sharedQueue, sharedAdmin, sharedERC4626, sharedLiquidityOps);
    }

    function test_CreateVault_WiringComplete() public {
        MockBufferManager bufferManager = new MockBufferManager(address(usdc));
        MockStrategyRouter strategyRouter = new MockStrategyRouter(address(0));

        DeployTypes.DeployConfig memory config = DeployTypes.DeployConfig({
            asset: IERC20Metadata(address(usdc)),
            name: "USDC Vault",
            symbol: "vUSDC",
            owner: owner,
            feeCollector: feeCollector,
            paramsProvider: address(params),
            ecosystem: IAdminModule.EcosystemConfig({
                bufferManager: address(bufferManager),
                strategyRouter: address(strategyRouter),
                healthRegistry: address(0),
                incentives: address(0),
                guardian: guardian,
                vetoer: address(0)
            }),
            freezeRouting: false,
            selectorRegistry: address(0)
        });

        DeployTypes.DeployResult memory result = _deployAndRegister(config);

        assertTrue(address(result.vault) != address(0), "Vault should be deployed");
        assertEq(result.vault.asset(), address(usdc), "Asset should be USDC");
        assertEq(result.vault.name(), "USDC Vault", "Name should match");
        assertEq(result.vault.symbol(), "vUSDC", "Symbol should match");

        (bool valid, uint256 missing) = SelectorLib.validateAllSelectorsMappedWithERC4626(
            result.vault,
            address(result.queueModule),
            address(result.adminModule),
            address(result.erc4626Module)
        );
        assertTrue(valid, "Routing should be complete");
        assertEq(missing, 0, "No selectors should be missing");

        IAdminModule.EcosystemConfig memory eco = IAdminModule(address(result.vault)).getEcosystem();
        assertEq(eco.bufferManager, address(bufferManager), "BufferManager should be set");
        assertEq(eco.strategyRouter, address(strategyRouter), "StrategyRouter should be set");
        assertEq(eco.guardian, guardian, "Guardian should be set");

        assertEq(result.vault.pendingOwner(), owner, "Pending owner should be set");
        vm.prank(owner);
        result.vault.acceptOwnerTransfer();
        assertEq(result.vault.owner(), owner, "Owner should be transferred");

        assertEq(factory.deployedVaultsCount(), 1, "Should track 1 vault");
        assertTrue(factory.isDeployedVault(address(result.vault)), "Should be tracked");
    }

    function test_CreateVault_DepositWithdrawSmoke() public {
        MockBufferManager bufferManager = new MockBufferManager(address(usdc));
        MockStrategyRouter strategyRouter = new MockStrategyRouter(address(0));

        DeployTypes.DeployConfig memory config = DeployTypes.DeployConfig({
            asset: IERC20Metadata(address(usdc)),
            name: "USDC Vault",
            symbol: "vUSDC",
            owner: owner,
            feeCollector: feeCollector,
            paramsProvider: address(params),
            ecosystem: IAdminModule.EcosystemConfig({
                bufferManager: address(bufferManager),
                strategyRouter: address(strategyRouter),
                healthRegistry: address(0),
                incentives: address(0),
                guardian: guardian,
                vetoer: address(0)
            }),
            freezeRouting: false,
            selectorRegistry: address(0)
        });

        DeployTypes.DeployResult memory result = _deployAndRegister(config);
        CoreVault vault = result.vault;

        vm.prank(owner);
        vault.acceptOwnerTransfer();
        vm.prank(owner);
        vault.unpauseAll();

        uint256 depositAmount = 100_000e6;
        vm.prank(alice);
        usdc.approve(address(vault), depositAmount);
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        assertEq(
            vault.balanceOf(alice), depositAmount, "Shares should equal assets for first deposit"
        );

        vm.prank(alice);
        IQueueModule(address(vault)).requestClaim(true, depositAmount);
        assertEq(usdc.balanceOf(alice), 1_000_000e6, "Alice should get assets back");
    }

    function test_CreateVault_WithFrozenRouting() public {
        MockBufferManager bufferManager = new MockBufferManager(address(usdc));
        MockStrategyRouter strategyRouter = new MockStrategyRouter(address(0));

        DeployTypes.DeployConfig memory config = DeployTypes.DeployConfig({
            asset: IERC20Metadata(address(usdc)),
            name: "USDC Vault Frozen",
            symbol: "vUSDCf",
            owner: owner,
            feeCollector: feeCollector,
            paramsProvider: address(params),
            ecosystem: IAdminModule.EcosystemConfig({
                bufferManager: address(bufferManager),
                strategyRouter: address(strategyRouter),
                healthRegistry: address(0),
                incentives: address(0),
                guardian: guardian,
                vetoer: address(0)
            }),
            freezeRouting: true,
            selectorRegistry: address(0)
        });

        DeployTypes.DeployResult memory result = _deployAndRegister(config);

        assertTrue(result.vault.isRoutingFrozen(), "Routing should be frozen");
    }

    function test_CreateVault_MultipleDeployments() public {
        MockBufferManager bufferManager = new MockBufferManager(address(usdc));
        MockStrategyRouter strategyRouter = new MockStrategyRouter(address(0));

        for (uint256 i = 0; i < 3; i++) {
            DeployTypes.DeployConfig memory config = DeployTypes.DeployConfig({
                asset: IERC20Metadata(address(usdc)),
                name: string(abi.encodePacked("Vault ", vm.toString(i))),
                symbol: string(abi.encodePacked("v", vm.toString(i))),
                owner: owner,
                feeCollector: feeCollector,
                paramsProvider: address(params),
                ecosystem: IAdminModule.EcosystemConfig({
                    bufferManager: address(bufferManager),
                    strategyRouter: address(strategyRouter),
                    healthRegistry: address(0),
                    incentives: address(0),
                    guardian: guardian,
                    vetoer: address(0)
                }),
                freezeRouting: false,
                selectorRegistry: address(0)
            });

            DeployTypes.DeployResult memory result = _deployAndRegister(config);
            assertTrue(factory.isDeployedVault(address(result.vault)), "Should be tracked");
        }

        assertEq(factory.deployedVaultsCount(), 3, "Should track 3 vaults");
    }

    function test_CreateVault_RevertOnZeroAsset() public {
        MockBufferManager bufferManager = new MockBufferManager(address(usdc));
        MockStrategyRouter strategyRouter = new MockStrategyRouter(address(0));

        DeployTypes.DeployConfig memory config = DeployTypes.DeployConfig({
            asset: IERC20Metadata(address(0)),
            name: "Bad Vault",
            symbol: "BAD",
            owner: owner,
            feeCollector: feeCollector,
            paramsProvider: address(params),
            ecosystem: IAdminModule.EcosystemConfig({
                bufferManager: address(bufferManager),
                strategyRouter: address(strategyRouter),
                healthRegistry: address(0),
                incentives: address(0),
                guardian: guardian,
                vetoer: address(0)
            }),
            freezeRouting: false,
            selectorRegistry: address(0)
        });

        vm.expectRevert();
        this._deployWrapper(config);
    }

    function test_CreateVault_RevertOnZeroBufferManager() public {
        MockStrategyRouter strategyRouter = new MockStrategyRouter(address(0));

        DeployTypes.DeployConfig memory config = DeployTypes.DeployConfig({
            asset: IERC20Metadata(address(usdc)),
            name: "Bad Vault",
            symbol: "BAD",
            owner: owner,
            feeCollector: feeCollector,
            paramsProvider: address(params),
            ecosystem: IAdminModule.EcosystemConfig({
                bufferManager: address(0),
                strategyRouter: address(strategyRouter),
                healthRegistry: address(0),
                incentives: address(0),
                guardian: guardian,
                vetoer: address(0)
            }),
            freezeRouting: false,
            selectorRegistry: address(0)
        });

        vm.expectRevert();
        this._deployWrapper(config);
    }

    function test_CreateVault_RevertOnZeroRouter() public {
        MockBufferManager bufferManager = new MockBufferManager(address(usdc));

        DeployTypes.DeployConfig memory config = DeployTypes.DeployConfig({
            asset: IERC20Metadata(address(usdc)),
            name: "Bad Vault",
            symbol: "BAD",
            owner: owner,
            feeCollector: feeCollector,
            paramsProvider: address(params),
            ecosystem: IAdminModule.EcosystemConfig({
                bufferManager: address(bufferManager),
                strategyRouter: address(0),
                healthRegistry: address(0),
                incentives: address(0),
                guardian: guardian,
                vetoer: address(0)
            }),
            freezeRouting: false,
            selectorRegistry: address(0)
        });

        vm.expectRevert();
        this._deployWrapper(config);
    }

    function test_CreateVault_RevertOnZeroGuardian() public {
        MockBufferManager bufferManager = new MockBufferManager(address(usdc));
        MockStrategyRouter strategyRouter = new MockStrategyRouter(address(0));

        DeployTypes.DeployConfig memory config = DeployTypes.DeployConfig({
            asset: IERC20Metadata(address(usdc)),
            name: "Bad Vault",
            symbol: "BAD",
            owner: owner,
            feeCollector: feeCollector,
            paramsProvider: address(params),
            ecosystem: IAdminModule.EcosystemConfig({
                bufferManager: address(bufferManager),
                strategyRouter: address(strategyRouter),
                healthRegistry: address(0),
                incentives: address(0),
                guardian: address(0),
                vetoer: address(0)
            }),
            freezeRouting: false,
            selectorRegistry: address(0)
        });

        vm.expectRevert();
        this._deployWrapper(config);
    }

    function test_SharedModulesAreReused() public {
        MockBufferManager bufferManager = new MockBufferManager(address(usdc));
        MockStrategyRouter strategyRouter = new MockStrategyRouter(address(0));

        DeployTypes.DeployConfig memory config = DeployTypes.DeployConfig({
            asset: IERC20Metadata(address(usdc)),
            name: "Test Vault",
            symbol: "TEST",
            owner: owner,
            feeCollector: feeCollector,
            paramsProvider: address(params),
            ecosystem: IAdminModule.EcosystemConfig({
                bufferManager: address(bufferManager),
                strategyRouter: address(strategyRouter),
                healthRegistry: address(0),
                incentives: address(0),
                guardian: guardian,
                vetoer: address(0)
            }),
            freezeRouting: false,
            selectorRegistry: address(0)
        });

        DeployTypes.DeployResult memory result1 = _deployAndRegister(config);
        DeployTypes.DeployResult memory result2 = _deployAndRegister(config);

        assertEq(
            address(result1.queueModule),
            address(result2.queueModule),
            "QueueModule should be shared"
        );
        assertEq(
            address(result1.adminModule),
            address(result2.adminModule),
            "AdminModule should be shared"
        );
        assertEq(
            address(result1.erc4626Module),
            address(result2.erc4626Module),
            "ERC4626Module should be shared"
        );
        assertEq(
            address(result1.queueModule), address(sharedQueue), "Should use shared queue module"
        );
        assertEq(
            address(result1.adminModule), address(sharedAdmin), "Should use shared admin module"
        );
        assertEq(
            address(result1.erc4626Module),
            address(sharedERC4626),
            "Should use shared ERC4626 module"
        );
    }
}
