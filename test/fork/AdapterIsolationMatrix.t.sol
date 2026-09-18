// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";

/// @notice Minimal ABI for the live "Multyr Strategies" USDC lending allocation
///         engine on Arbitrum One. This suite is NOT part of this repo's src/ tree
///         (it is a separately deployed package) -- signatures below were pulled
///         from the verified on-chain source, not guessed.
interface ILendingAdapter {
    function name() external view returns (string memory);
    function underlying() external view returns (address);
    function totalAssets() external view returns (uint256);
    function withdrawableAssets() external view returns (uint256);
    function currentAPYBps() external view returns (uint16);
    function maxCapacity() external view returns (uint256);
    function externalMarketTVL() external view returns (uint256);
}

interface IMultiMarketAdapter {
    function effectiveAPYBps() external view returns (uint16);
}

interface IUsdcMultiLendingVault {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function KEEPER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function toggleAdapter(address adapter, bool on) external;
    function enabled(address adapter) external view returns (bool);
    function isAdapter(address adapter) external view returns (bool);
    function flagged(address adapter) external view returns (bool);
    function positionAssets(address adapter) external view returns (uint256);
    function idleCash() external view returns (uint256);
    function positions() external view returns (address[] memory addrs, uint256[] memory assets);
    function totalAssets() external view returns (uint256);
    function paused() external view returns (bool);
    function deployIdle() external;
    function ASSET() external view returns (address);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @title AdapterIsolationMatrix
/// @notice Deterministic, adapter-by-adapter isolation test against the LIVE deployed
///         UsdcMultiLendingVault allocation engine on an Arbitrum mainnet fork.
///         For each of the 7 supported lending adapters in turn: disables the other
///         six at the vault level, seeds idle USDC, triggers deployIdle() as the real
///         keeper (StrategyUpkeep) would, then asserts funds actually landed in the
///         target adapter (and nowhere else), accounting matches, externalMarketTVL
///         is nonzero, maxCapacity/rate reads succeed, and vault-level position
///         bookkeeping agrees.
/// @dev    Runs entirely against a forked EVM state (vm.createSelectFork) -- no
///         transaction is ever broadcast to real Arbitrum, so this never touches
///         real user funds or real governance. Each `test_Isolation_*` function gets
///         its own fresh fork (forge calls setUp() before every test), so the 7
///         adapters are tested independently with no cross-test state leakage.
///
///         Governance note (verified on-chain, see PR/task notes): RootTimelock
///         currently has minDelay()==0 and every timelock role is held by a single
///         EOA rather than a multisig, so there is no real timelock delay to warp
///         past here -- vm.prank(TIMELOCK) is used to exercise the real access-control
///         check (toggleAdapter is onlyAdminOrBootstrap, DEFAULT_ADMIN_ROLE==RootTimelock)
///         without re-simulating TimelockController's own schedule/execute ceremony.
contract AdapterIsolationMatrix is Test {
    address constant VAULT = 0x2ca30120C828Fc136d348234f7e68116572DD83E; // UsdcMultiLendingVault
    address constant TIMELOCK = 0xE2812E869F8005397130CCDF1aaabd75447844df; // RootTimelock (DEFAULT_ADMIN_ROLE)
    address constant STRATEGY_UPKEEP = 0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550; // KEEPER_ROLE holder
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address constant AAVE = 0x2A5097977418C4Dc616f963Caae11d8f76325F2a;
    address constant MORPHO = 0xb6B34A0d49Cda4d0E0B515C4aA17f2642e0792B5;
    address constant COMET = 0x273c429DD929830033BBE60AB08547ADe60BD74c;
    address constant EULER = 0x4624F8349540e7540BD925F2149E7C89BbbcDe2a;
    address constant DOLOMITE = 0x7aA2F4Ce5c7031c34f2dB681045Da7eA751a651f;
    address constant FLUID = 0xa5044692678aeB49dEF903a441D3f84878367Ef5;
    address constant VENUS = 0x86e262C02cA6245D6bDF3901cF4d063cfB0d2Bd5;

    uint256 constant SEED_USDC = 1_000e6; // 1,000 USDC idle-cash seed per iteration

    address[7] internal adapters;
    string[7] internal labels;
    IUsdcMultiLendingVault internal vault;

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc"));
        vm.createSelectFork(rpc);
        require(block.chainid == 42161, "fork did not land on Arbitrum One");

        vault = IUsdcMultiLendingVault(VAULT);
        adapters = [AAVE, MORPHO, COMET, EULER, DOLOMITE, FLUID, VENUS];
        labels = ["Aave", "Morpho", "Comet", "Euler", "Dolomite", "Fluid", "Venus"];

        require(vault.ASSET() == USDC, "vault asset mismatch");
        require(!vault.paused(), "vault is paused on live chain -- aborting");
    }

    function test_Isolation_Aave() public { _runIsolation(0); }
    function test_Isolation_Morpho() public { _runIsolation(1); }
    function test_Isolation_Comet() public { _runIsolation(2); }
    function test_Isolation_Euler() public { _runIsolation(3); }
    function test_Isolation_Dolomite() public { _runIsolation(4); }
    function test_Isolation_Fluid() public { _runIsolation(5); }
    function test_Isolation_Venus() public { _runIsolation(6); }

    function _runIsolation(uint256 targetIdx) internal {
        address target = adapters[targetIdx];
        console2.log("");
        console2.log("===== ADAPTER ISOLATION TEST:", labels[targetIdx]);
        console2.log("adapter address:", target);
        require(vault.isAdapter(target), "target not registered on vault");

        // ---- pre-state snapshot for every adapter (deltas, not absolutes, since
        //      some adapters already carry small live production balances) ----
        uint256[7] memory taBefore;
        for (uint256 i; i < 7; ++i) {
            taBefore[i] = ILendingAdapter(adapters[i]).totalAssets();
        }

        // ---- disable all others, ensure target enabled, as RootTimelock ----
        vm.startPrank(TIMELOCK);
        for (uint256 i; i < 7; ++i) {
            vault.toggleAdapter(adapters[i], i == targetIdx);
        }
        vm.stopPrank();

        for (uint256 i; i < 7; ++i) {
            assertEq(vault.enabled(adapters[i]), i == targetIdx, "toggleAdapter did not stick");
        }
        console2.log("[governance] only", labels[targetIdx], "enabled (others toggled off via RootTimelock)");

        bool flagged = vault.flagged(target);
        uint256 capBefore = ILendingAdapter(target).maxCapacity();
        uint256 taTargetBefore = ILendingAdapter(target).totalAssets();
        console2.log("[pre-check] flagged:", flagged);
        console2.log("[pre-check] maxCapacity:", capBefore);
        console2.log("[pre-check] totalAssets (pre-deploy):", taTargetBefore);

        // ---- seed idle cash directly on the vault (tests the allocation engine
        //      itself; bypasses the upstream CoreVault deposit UX on purpose) ----
        uint256 seed = SEED_USDC;
        if (capBefore > 0 && taTargetBefore + seed > capBefore) {
            seed = capBefore > taTargetBefore ? capBefore - taTargetBefore : 0;
        }
        uint256 vaultBalBefore = IERC20Min(USDC).balanceOf(VAULT);
        deal(USDC, VAULT, vaultBalBefore + seed);
        console2.log("[seed] idle USDC deposited:", seed);

        // ---- trigger allocation as the real keeper (StrategyUpkeep, KEEPER_ROLE) ----
        vm.prank(STRATEGY_UPKEEP);
        try vault.deployIdle() {
            console2.log("[keeper] deployIdle() call: OK");
        } catch (bytes memory reason) {
            console2.log("[keeper] deployIdle() call: REVERTED");
            console2.logBytes(reason);
            revert("FAIL: deployIdle() reverted with only the target adapter enabled");
        }

        // ---- accounting: target adapter must have received funds ----
        uint256 taTargetAfter = ILendingAdapter(target).totalAssets();
        console2.log("[accounting] target totalAssets before/after:", taTargetBefore, taTargetAfter);
        assertGt(
            taTargetAfter,
            taTargetBefore,
            "FAIL: target adapter totalAssets did not increase (no headroom / eligibility rejected / capacity 0?)"
        );

        uint256 extTvl = ILendingAdapter(target).externalMarketTVL();
        console2.log("[accounting] externalMarketTVL:", extTvl);
        assertGt(extTvl, 0, "FAIL: externalMarketTVL is zero after deployment");

        (address[] memory posAddrs, uint256[] memory posAmts) = vault.positions();
        uint256 recorded;
        for (uint256 i; i < posAddrs.length; ++i) {
            if (posAddrs[i] == target) recorded = posAmts[i];
        }
        uint256 recordedMapping = vault.positionAssets(target);
        console2.log("[accounting] vault.positions() recorded:", recorded);
        console2.log("[accounting] vault.positionAssets() recorded:", recordedMapping);
        assertGt(recorded, 0, "FAIL: vault.positions() shows zero for target adapter");
        assertEq(recorded, recordedMapping, "FAIL: positions() and positionAssets() disagree");

        console2.log("[capacity] maxCapacity (0 = uncapped):", capBefore);

        uint16 apy = ILendingAdapter(target).currentAPYBps();
        console2.log("[rate] currentAPYBps:", apy);
        try IMultiMarketAdapter(target).effectiveAPYBps() returns (uint16 eapy) {
            console2.log("[rate] effectiveAPYBps:", eapy);
        } catch {
            console2.log("[rate] effectiveAPYBps: n/a (single-market adapter)");
        }

        console2.log("[vault] totalAssets:", vault.totalAssets());
        console2.log("[vault] idleCash:", vault.idleCash());

        // ---- isolation: no OTHER adapter should have received funds ----
        for (uint256 i; i < 7; ++i) {
            if (i == targetIdx) continue;
            uint256 taOtherAfter = ILendingAdapter(adapters[i]).totalAssets();
            console2.log(labels[i], "totalAssets before/after (must be flat):", taBefore[i], taOtherAfter);
            assertLe(taOtherAfter, taBefore[i] + 1, "FAIL: a disabled adapter received funds");
        }

        console2.log("===== RESULT: PASS -", labels[targetIdx]);
    }
}
