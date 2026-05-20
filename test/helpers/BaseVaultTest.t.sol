// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ICoreAggregatorVaultV1, IVaultUpkeep } from "./Interfaces.sol";
import { CoreHarness } from "./CoreHarness.sol";
import { VaultUpkeep } from "../../src/automation/VaultUpkeep.sol";
import { ERC20Mock } from "../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "./MockParamsProvider.sol";
import { MockBufferManagerForTests } from "./MockBufferManagerForTests.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Minimal stubs for VaultUpkeep v2 constructor dependencies
contract StubRouterReader {
    uint64 public lastBatchTimestamp;
    function setLastBatchTimestamp(uint64 ts) external { lastBatchTimestamp = ts; }
}

contract StubGlobalConfigReader {
    uint256 public minRebalanceCooldown = 3600;
    function setMinRebalanceCooldown(uint256 cd) external { minRebalanceCooldown = cd; }
}

/// @dev Adjust the import below to your actual vault source path OR provide the deployed address via env.
/// import {CoreAggregatorVaultV1} from "../src/core/CoreAggregatorVaultV1.sol";
/// import {VaultUpkeep} from "../src/core/VaultUpkeep.sol";

contract BaseVaultTest is Test {
    ICoreAggregatorVaultV1 internal vault;
    IVaultUpkeep internal upkeep;
    address internal user = address(0xBEEF);
    address internal user2 = address(0xCAFE);
    IERC20Metadata internal assetToken;

    // Set these before running: either deploy in setUp() or set to existing addresses.
    address internal vaultAddr;
    address internal upkeepAddr;

    function setUp() public virtual {
        // Option A: set addresses via env (forge test --env .env)
        // vaultAddr = vm.envAddress("VAULT_ADDR");
        // upkeepAddr = vm.envAddress("UPKEEP_ADDR");

        if (vaultAddr == address(0)) {
            // Deploy minimal ERC20 (USDC-like) and mint to this contract
            ERC20Mock usdc = new ERC20Mock("USDC", "USDC", 6);
            usdc._mint(address(this), 1_000_000e6);
            assetToken = IERC20Metadata(address(usdc));

            // Deploy MockParamsProvider with default lockPeriod=0
            MockParamsProvider params = new MockParamsProvider();
            params.setLockPeriod(0);

            // Deploy new CoreHarness with 6-param constructor (Diamond-lite)
            CoreHarness core = new CoreHarness(
                IERC20Metadata(address(usdc)),
                "USDC Aggregator Vault",
                "agUSDC",
                address(this), // owner
                address(this), // treasury
                address(params) // params
            );

            // Set guardian after construction
            core.setGuardian(address(this));

            // Install mock BufferManager so deposit/mint don't revert NavInvalid
            // DEFAULT: warmNavState = (0, block.timestamp, true) — fresh + valid
            // For NAV-specific tests, use dedicated suites with configurable mocks
            MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(core));
            core.setBufferManagerUnsafe(address(mockBM));

            vaultAddr = address(core);

            // Deploy VaultUpkeep with sensible defaults
            StubRouterReader stubRouter = new StubRouterReader();
            StubGlobalConfigReader stubConfig = new StubGlobalConfigReader();
            VaultUpkeep upk = new VaultUpkeep(
                vaultAddr,
                address(0), // buffer manager (optional wiring)
                address(stubRouter),
                address(stubConfig),
                25,
                100,
                type(uint256).max,
                type(uint256).max,
                10, // minRealizeGapBps (0.1%)
                10000 // minRealizeFloor (0.01 USDC)
            );
            upkeepAddr = address(upk);
        }

        // Bind interfaces
        vault = ICoreAggregatorVaultV1(vaultAddr);
        upkeep = IVaultUpkeep(upkeepAddr);
    }

    // Utilities
    function _assumeNonZero(uint256 x) internal pure returns (uint256) {
        return x == 0 ? 1 : x;
    }
}
