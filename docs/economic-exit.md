# Economic Exit at Request — implementation notes, consumer audit, deployment plan

Implements *Withdrawal Model — Economic Exit at Request (FINAL)* (sections 3–9), with the
acceptance tests of sections 10–11. This file is the PR description: it carries the items
section 12 asks for (audit table, where `totalAssets()` lives, deployment plan) and the
places the implementation departs from, or had to interpret, the spec.

Older docs (`exit-engine.md`, `queue-mechanics.md`, `storage-layout.md`, `architecture.md`,
`access-control.md`, `fee-policy.md`, `audit-scope.md`) still describe the escrow / `ppsAtClose`
model. They are superseded by this file for everything about requests, epochs, funding,
claims and NAV, and have not been rewritten in this PR (code and tests only).

---

## 1. What changed

```
REQUEST → _crystallizeExit → fixed assetsOwed → burn net shares → totalOwed += assetsOwed
        → epoch settlement bucket → fundEpoch → claim (assetsOwed × liabilityIndex / 1e18)
```

| Area | Before | After |
|---|---|---|
| Price | fixed at `closeCurrentEpoch()` (`ppsAtClose`) | fixed **at request**, inside `_crystallizeExit` |
| Shares | all gross shares escrowed in the vault until claim | net shares **burned at request**, fee shares sent to the FeeCollector at request |
| Liability | implicit (`netShares × ppsAtClose`), inside `totalAssets()` | explicit `totalOwed`, subtracted from NAV |
| `cancelEpochWithdrawal` | existed | **removed** (selector unrouted) |
| Epoch | prices the bucket | settlement bucket only: groups liabilities, sets no price |
| Withdrawal minimum | `minClaimAmount` gate | none (deposits only) |
| NAV validity on exit | soft refresh, never blocks | request **reverts** unless the whole NAV passes `navStatus()` (warm cache complete+fresh, strategies readable+healthy, oracle valid) |
| Insolvency | not modelled | derived mode: `grossAssets < totalOwed` |

Removed storage / API: `EpochData.ppsAtClose`, `EpochData.totalNetAssets`, `EpochClaim.netShares`/`feeShares`,
`Layout.escrowedShares`, `Layout.closedPendingAssets`, `totalEscrowedShares()`, `closedPendingAssets()`,
`cancelEpochWithdrawal()`, `EpochWithdrawalCancelled`, `ClaimTooSmall`.
Added: `navStatus()` (vault) / `navValidity()` (router), `EpochData.reservedRemaining`, `grossAssets()`, `totalOwed()`, `liabilityIndex()`, `isInsolvent()`, `liabilityState()` on the
vault; `EpochData.totalAssetsOwed`, `EpochClaim.{assetsOwed,requestedAt,grossShares}`,
`Layout.totalOwed`, `syncInsolvencyState()`, events `InsolvencyEntered` / `InsolvencyExited`,
errors `VaultInsolvent`, `NavStale`, `NavInvalid`, `NothingToWithdraw`.

## 2. Accounting primitives (single source of truth)

| Primitive | Where | Definition |
|---|---|---|
| `grossAssets()` | `CoreVault.sol` | hot + warm + Σ strategy assets. **The only place they are summed.** |
| `totalOwed()` | `CoreVault.sol` (reads `EpochQueueStorage.totalOwed`) | Σ nominal `assetsOwed` over unclaimed claims, funded or not. Written only by `EpochedQueueModule`: `+=` at request, `-=` at claim / instant settlement. |
| `totalAssets()` | `CoreVault.sol` | `grossAssets() > totalOwed() ? grossAssets() − totalOwed() : 0`. Saturating; never reverts. |
| `liabilityIndex()` | `CoreVault.sol` | `1e18` if `totalOwed == 0 \|\| gross ≥ owed`, else `gross × 1e18 / owed`. Pure function of state, computed on read, not stored. |
| `reservedForClaims` | `EpochQueueStorage` | earmark only. **Not** subtracted from NAV (`totalOwed` already holds everything owed). Every subtraction involving it is saturating. |

**`totalAssets()` lives in the CoreVault shell**, not in a module (it is the ERC-4626 entry point).
The shell is not behind a proxy, so this change requires a **new CoreVault deployment** — see §5.
`test_W15_noModuleReconstructsNavLocally` fails if any module sums the portfolio itself.

## 3. Consumer audit (spec §5)

Class **A** = gross portfolio NAV (`grossAssets()`), class **B** = active shareholder NAV (`totalAssets()`).
Strategy/adapter-internal `totalAssets()` calls (`IStrategy`, `IWarmAdapter`, `StrategyScorer`, the
router's per-strategy NAV probes) read a *strategy's own balance*, not vault NAV, and are out of the
audit's subject; they are listed last for completeness.

### 3.1 Vault shell — `src/core/CoreVault.sol`

| Site | Class | Reads | Note |
|---|---|---|---|
| `totalAssets()` / `_totalAssets()` | B | definition | `max(0, gross − owed)` |
| `grossAssets()` / `_grossAssets()` / `_totalAssetsBreakdown()` | A | definition | only place hot+strat+warm is summed |
| `liabilityState()` / `liabilityIndex()` / `isInsolvent()` | A | `_grossAssets` vs `totalOwed` | the index and the mode are defined here once |
| `totalAssetsBreakdown()` → `nav` | A | `_grossAssets` | consumed by deploy sizing and buffer planning; docs updated: `nav` is **not** net of `totalOwed` |
| `maxDeposit` — `vaultDepositCap` | B | `_totalAssets` | cap on shareholder equity; new depositors buy equity |
| `maxDeposit` — `userDepositCap` | B | `convertToAssets` | shareholder valuation |
| `maxMint`, `previewDeposit`, `previewMint` | B | OZ conversions over `totalAssets()` | deposit/mint pricing |
| `previewWithdraw`, `previewRedeem`, `convertToShares`, `convertToAssets` | B | OZ defaults over `totalAssets()` | never revert on underflow (saturating base) |
| `_depositsAreCurrentlyAllowed` | A | `liabilityState()` | `maxDeposit` is 0 in insolvency and at zero equity (ERC-4626) |
| `canCrystallize` | B | `_totalAssets` | fee is on shareholder performance |
| `canRealize`, `canRealizeWithGap` | A | `_grossAssets` | ops-reserve target vs physical liquidity |
| `_refreshOpsNavCache` / `cachedNavForOps` | **A** | `_grossAssets` | *changed from `totalAssets()`*: an ops-only cache for keeper/plan decisions; physical value |
| `payRewardShares` (`convertToShares`) | B | | reward payout |

### 3.2 `ERC4626Module`

| Site | Class | Note |
|---|---|---|
| `deposit(…, minShares)` preview, `_depositInternal` (`_previewDeposit`) | B | deposit pricing |
| `mint(…, maxAssets)`, `_mintInternal` (`totalAssets()` × shares) | B | mint pricing |
| `_requireSolvent()` in deposit/mint | A | reverts `VaultInsolvent` |
| `_enforceDepositLimits` — vault cap (`totalAssets()`), user cap (`convertToAssets`) | B | |
| `forceWithdraw` (`previewWithdraw`, `convertToAssets`), fee-event conversions | B | force-exiting holder is a shareholder. Pulls liquidity via `executeRedeemBatch`, which carries the router's `checkOracleFreshness` guard -- **reverts** on a stale oracle. |
| `forceWithdrawAll` (`convertToAssets`, `totalAssets()==0` guard) | B | Pulls liquidity via `forceRedeemForWithdraw`, which has **no oracle check**. `forceWithdrawAll` -- not `forceWithdraw` with a caller-supplied plan -- is the guaranteed exit under a stale oracle (review: Stefano). |
| `_notifyIncentivesDeposit` (`convertToAssets`) | B | |
| `_freeLiquidity` | A | hot − `reservedForClaims`, saturating |

### 3.3 `EpochedQueueModule`

| Site | Class | Note |
|---|---|---|
| `_crystallizeExit` — insolvency / zero-equity check (`liabilityState`) | A | |
| `_crystallizeExit` — `convertToAssets(netShares)` | B | **the one pricing call** for a request |
| `_epochCapRemaining(…, _totalAssets())` (`capPerEpochBps`, dynamic cap) | B | read **before** the request moves the NAV |
| `_canInstant` — free liquidity | A | hot − reserved, saturating |
| `fundEpoch` — need (`nominal × index`), `reservedForClaims`, hot | A | saturating |
| `claimEpochAssets` / `batchClaimEpochAssets` — index | A | via `liabilityState()` |
| `_crystallize`, `_pps` (perf fee, HWM) | B | crystallisation uses NAV net of `totalOwed` |
| `_updateNavSmooth` | B | |
| `syncInsolvencyState` | A | |

### 3.4 Other modules and periphery

| Site | Class | Note |
|---|---|---|
| `FixedMaturityModule` — funding progress/target/success, `markMatured` snapshot, `fundingFailedPPS`, perf-fee base, `_previewDeposit` | B | `totalOwed == 0` in every state where standard exits are gated, so A ≡ B; B chosen because these are shareholder-capital measures |
| `AdminModule.seedDeadDeposit` (`convertToShares`) | B | |
| `PermitOpsMixin` (`previewWithdraw`) | B | |
| `LiquidityOpsModule` — `canDeploy`, `deployToStrategies` (`totalAssetsBreakdown`) | A | reserve/warm headroom on physical NAV; free hot is net of `reservedForClaims`, saturating |
| `LiquidityOpsModule.realizeForReserveAndOps` | **A** | *changed from `totalAssets()`* → `grossAssets()` |
| `LiquidityOpsModule._buildQueueSafetyContext` | A | *changed*: queue pressure now `totalOwed` (was escrowed **shares**) |
| `LiquidityOpsModule._eligibleList` (Σ strategy TVL for rebalance drift) | A | strategy-only TVL, not vault NAV; unchanged |
| `BufferManager.targetHot` | **A** | *changed from `totalAssets()`* |
| `BufferManager.plan` (`totalAssetsBreakdown`, `_reservedForClaims`) | A | reserved subtraction is saturating |
| `StrategyRouter._getCoreNav` (NAV-delta guard on deposit/redeem batches; drives `maxStrategyBps` exposure caps and the loss-cap guards) | **A** | *changed from `totalAssets()`*: a pending-exit liability must not amplify a portfolio delta |
| `StrategyRouter._getAvailableSurplusWithOffset` (ops reserve floor) | **A** | *changed from `totalAssets()`* |
| `VaultUpkeep._gapPassesThreshold` (realize-gap threshold) | **A** | *changed from `totalAssets()`*. Automation is listed out of scope in spec §15, but this one line is a class-A NAV-correctness fix (the realize-gap threshold must compare against the physical portfolio, not shareholder NAV net of `totalOwed`), not new automation behaviour -- flagged explicitly per review (Stefano). |
| Circuit-breaker TVL baseline | A | **no call site exists in `src`** (only the `circuitBreakerBps` param, the `CircuitBreakerTriggered` event and `lastTVLSnapshot` storage). Whoever implements it must read `grossAssets()`. |

### 3.5 `CoreVaultLens`

| Site | Class | Note |
|---|---|---|
| `pps`, `previewPPSPostDepositFee`, `previewPPSPostWithdrawFee` | B | |
| `totalAssetsSmooth` | B | |
| `calculateCapImmediateRemaining` | B | must match the module's cap base |
| `getUserReport` (`assetsValue`) | B | plus `pendingClaims` (Σ fixed `assetsOwed`) and `pendingClaimsPayable` (× index) |
| `getVaultReport` | A + B | `totalAssets` (B), `grossAssets`, `totalOwed`, `liabilityIndex`, `insolvent` (A); `pendingWithdrawals == totalOwed` |
| `canRealize` | **A** | *changed*, mirrors `CoreVault.canRealize` |
| `totalAssetsStrict`, `totalAssetsSafe` | A | **deviation from W-15, deliberate**: independent live recomputations (bypassing the cached warm NAV) used by ops as a cross-check of `grossAssets()`. Diagnostic only; no protocol logic reads them. Compare them against `grossAssets()`, not `totalAssets()`. |

### 3.6 Strategy / adapter-internal reads (not vault NAV)

`StrategyRouter` (per-strategy `totalAssets()` probes for realised-amount and health NAV),
`StrategyScorer`, `BufferManager` (warm adapter `totalAssets()` when refreshing the warm cache),
`AaveV3WarmAdapter_USDC`, `MorphoBlueWarmAdapter_USDC`. These feed `grossAssets()`; none is a NAV consumer.

## 4. Interpretations and deviations — please read

Everything below is a place where the spec was ambiguous or could not be followed to the letter.
Each is small, but each is a decision the reviewer should confirm.

1. **`_crystallizeExit` has one extra parameter, `ExitMode mode`.** The spec signature is
   `(address user, uint256 grossShares)`. The vault has two fee tiers (standard = `witBps`,
   instant = `witBps + immediateExitPenaltyBps`) and one helper must price both, so the tier
   is passed in. Standard and instant still share this single helper and contain no separate
   pricing or fee logic.
2. **An instant request that falls back into the queue now pays the instant tier.** Before, the
   fallback re-priced at the standard tier. Spec §6.2 says the fallback "never re-applies a fee",
   so the fee is fixed once, before the branch, by the entry point the user chose. Economic
   effect: a fallback pays `immediateExitPenaltyBps` it previously did not. If that is not wanted,
   the alternative is to drop the instant penalty entirely (spec §6 step 3 says only "withdraw
   fee"). Not changed here without a decision.
3. **The instant cap is measured on the net amount.** `_crystallizeExit` runs first, so the
   cap check compares `assetsOwed` (net of fee) with a cap read from the pre-request NAV. It used
   to compare the gross value. `consumeEpochCap` likewise consumes `assetsOwed`.
4. **The NAV gate covers the whole economic NAV, and there is no soft refresh before a request.**
   A request turns the NAV into an irrevocable liability, so `_crystallizeExit` calls
   `CoreVault.navStatus()` *before* pricing and reverts unless every input of `grossAssets()` is valid:
   warm cache present, complete (`warmNavValid`: no adapter failed) **and** no older than 15 minutes
   (age tested explicitly, I-10); every enabled strategy's `totalAssets()` readable
   (`StrategyRouter.navValidity`; the best-effort `totalStrategyAssetsSafe` counts a failing strategy as
   0, which would silently understate the NAV); every strategy `OK` in the health registry (DEGRADED/BROKEN
   rejects); and, if an oracle is configured for the vault asset, a live, fresh, non-zero, cross-consistent
   quote. Errors: `NavInvalid` (no BufferManager / warm incomplete), `NavStale`, `NavInputInvalid(reason)`
   (4 strategy valuation, 5 strategy health, 6 oracle). No oracle configured ⇒ no price input is required
   (the vault is asset-denominated). A refresh-then-check would make the required stale-NAV test unreachable,
   so requests depend on the keeper: **I-10 must be fixed and the keeper must refresh within 15 minutes
   before go-live**. Accepted requests are never repriced; a loss that no on-chain signal shows yet is
   protocol timing risk, covered only by the insolvency mechanism. Claims, close and fund are not gated.
5. **Insolvency funds at `nominal × liabilityIndex`, not at nominal.** (Reverses the reading in the first
   version of this PR, which left the tail epoch unfundable.) `fundEpoch` sizes an epoch's need as
   `ceil(unclaimed nominal × index / 1e18)` (identity while solvent) and earmarks exactly that in a new
   per-epoch `reservedRemaining`; each claim releases its proportional share of *its own* epoch's earmark.
   So with owed 50 and assets 30, the epoch funds at 30 and every claim is paid 60% in any order
   (`test_s11_insolvency_proRata_orderIndependent`). If the index *recovers* after funding, a claim pays the
   larger amount and the difference comes from free liquidity; if that is short the claim reverts
   `InsufficientFreeLiquidity` and is retried later — it is never paid short, so a transient loss is not a
   permanent haircut (`test_s11_recoveryAfterFunding_claimPaysFullNominal`). Residual limitation: that top-up
   needs free hot cash, and nothing realises strategy assets for it automatically.
   **Dust tolerance (found on the Arbitrum fork).** In insolvency the whole remaining portfolio is owed, so
   funding needs every last unit to be liquid. The live lending adapters cannot return the last wei of a
   position: realising 1,218,285 units returned 1,213,315 and left 4,975 stuck, which made the epoch unfundable
   by 0.0005%. `INSOLVENCY_FUNDING_DUST_BPS = 10` therefore treats a shortfall of up to 0.1% of the epoch's need
   as funded **in insolvency only** (solvent funding stays exact); the earmark is capped at what is on hand, and
   a claim whose payout exceeds earmark + free cash by no more than that tolerance is paid what is available
   (beyond it, it reverts). Earmarks and payouts are rounded **down** (floor is subadditive, so at one index the
   claims' payouts never exceed the earmark). The visible effect is that the index can drift **up** by at most
   the tolerance across a claim (W-13 holds to within 10 bps, and only upward). Multyr should confirm 10 bps.
5b. **Adapters paying out less than asked (no hack: slippage, rounding).** Tested in
   `AdapterShortfall.t.sol` with a real StrategyRouter and a strategy that pays a set % short. Findings:
   - The shortfall is a loss of the *vault*: Alice's claim stays the fixed amount and the remaining holders
     absorb it (solvent case), or the index drops (insolvent case).
   - `fundEpoch` used to ask a strategy for exactly the deficit. Every retry then shrinks the residue by the same
     factor and it stalls a unit or two short (a 1-unit ask returns 0), leaving a *solvent* epoch unfundable.
     It now asks for `deficit + 0.5% + 1` (`STRATEGY_REDEEM_BUFFER_BPS`) so ordinary slippage is covered in one
     call, and never for less than `MIN_STRATEGY_REDEEM` (10,000 units, 0.01 USDC): the router's loss cap is a
     percentage, so on a tiny ask one unit of rounding (25 asked, 24 returned = 4%) looked like a cap breach and
     reverted the whole redeem. Surplus cash stays in hot for the keeper.
   - If an adapter pays short by **more than `StrategyRouter.lossCapBps`** (default 0.5%), the router refuses the
     withdrawal atomically: nothing moves, the epoch stays `Closed`, no claim is payable, nothing is repriced. It
     is unblocked by governance raising the cap or using `emergencyRedeemBatch`. This is the one place an accepted
     claim can wait, and it is deliberate router policy, not something this PR changes.
6. **Zero-equity is treated like insolvency for deposits, mints and requests.** W-3 names
   `grossAssets < totalOwed`. `grossAssets == totalOwed` is solvent but leaves `totalAssets() == 0`, and
   the failure the spec cites for insolvency (a share price of 0: unbounded shares minted, or an
   exiting holder receiving nothing) is identical there. So deposit/mint revert `VaultInsolvent`
   when `gross < owed`, or `gross == owed` with shares outstanding; standard/instant requests revert
   when `gross <= owed`; `maxDeposit` is 0 in both. Claims, close and fund are unaffected
   (`test_W3_zeroEquity_gross_equals_owed_alsoBlocksDepositsAndRequests`). `isInsolvent()` itself
   stays exactly the spec's `gross < owed`.
7. **`forceWithdrawAll` returns `0` (no burn, no fee, no revert) when `totalAssets() == 0`**, and
   `forceWithdraw` reverts `NothingToWithdraw`. This covers insolvency *and* the equal case
   `gross == totalOwed` (zero shareholder equity while solvent). Without it a zero fill burned the
   caller's whole position for nothing (the existing "dust ⇒ fully filled" branch).
8. **A latch, `insolvencyLatched`, exists for events only.** Insolvency stays derived
   (`grossAssets < totalOwed`, §9.3); the bool only de-duplicates `InsolvencyEntered/Exited`, which
   are emitted from `closeCurrentEpoch`, `fundEpoch`, claims and the permissionless
   `syncInsolvencyState()`. A derived state cannot fire an event on its own, and a reverting
   request cannot emit one.
9. **No withdrawal minimum means dust claims are possible.** `minClaimAmount` no longer gates
   exits (§6.4). It used to bound dust-claim griefing of `outstandingClaimCount` (the dynamic-cap
   queue-depth signal). Each dust claim now costs the attacker a burned share and gas, nothing else.
10. **Removed views/selectors change the ABI.** `SelectorLib` counts: queue selectors 9 (−cancel,
   +`syncInsolvencyState`), queue views 10 (−`totalEscrowedShares`, −`closedPendingAssets`).
11. **Test infrastructure:** `MockBufferManagerForTests` gained an `autoFresh` mode (default on) that
    simulates a running keeper so the ~900 existing tests that warp time do not each need a manual
    refresh; any explicit setter turns it off. Suites that assert escrow/cancel/`ppsAtClose`
    behaviour were rewritten to the new model or removed (the cancel tests are replaced by
    `test_W10_*`, the `minClaimAmount` tests by `test_noWithdrawalMinimum_*`).

## 5. Deployment plan (new CoreVault)

`totalAssets()` is in the CoreVault shell and the shell is not behind a proxy, so the model change
ships as **a new CoreVault**, not an upgrade. **No deployment until this PR is reviewed and approved.**

Everything bound to the vault address must be redeployed with it, because the class-A consumers
(`BufferManager`, `StrategyRouter`, `VaultUpkeep`) now call `grossAssets()`, which the old vault
does not have, and the old ones would read a net-of-liabilities NAV from the new vault.

1. **Spec §13 — drain the old model first.** On the current vault: close epoch 1, fund it (hot is
   empty: `fundEpoch` realises from the strategy), and let all four pending claims be collected
   under the current model. Verify `outstandingClaimCount == 0` and `reservedForClaims` is dust.
   Two pricing models must never coexist on live claims. The new vault starts with `totalOwed == 0`.
2. **Fix I-10 and confirm the keeper.** `warmNavValid` must be genuinely refreshed; the keeper must call
   `refreshWarmNav()` at least every `MAX_WARM_NAV_AGE` (15 min, and `navRefreshInterval` must stay
   below it). Requests revert `NavStale` otherwise.
3. **Deploy**, through `DeployCoreSystem` / `SelectorLib` (the selector table is the source of truth):
   `CoreVault`, `EpochedQueueModule`, `ERC4626Module`, `LiquidityOpsModule`, `AdminModule`,
   `FixedMaturityModule`, `BufferManager`, `StrategyRouter`, `VaultUpkeep`, `CoreVaultLens`.
   Contract size check: `CoreVault` runtime is 22,137 B (limit 24,576).
4. **Wire and verify** the selectors (`SelectorLib.TOTAL_SELECTORS`), `approveWarmAdapters`,
   the fee params (note deviation 2 for `immediateExitPenaltyBps`), then seal.
5. **Move depositors** with the existing Arbitrum migration tooling (old vault → underlying → new vault).
   Open item: the tooling predates this PR and has not been re-run against it.
6. **Downstream (out of scope here, in this order after approval):** subgraph (`assetsOwed` on
   `ClaimRequest`, drop `ppsAtClose`, add `grossAssets`/`totalOwed`/`liabilityIndex`, new events),
   dapp (fixed amount at request, no cancel, "liquidity available by"), ops console (redefine
   I-2/I-3/I-7, add W-1..W-15, P0 alert on `InsolvencyEntered`), keeper/CRE.
7. **Disclose to depositors** (spec §14, D3/D4): amplified exposure while exits are pending, and
   front-running of a known loss (mitigated by the withdraw fee and the NAV freshness rule).

## 6. Arbitrum One fork tests (`test/fork/EconomicExit_ArbitrumFork.t.sol`)

The new code is `vm.etch`ed onto the **live** addresses (vault, queue / ERC4626 / liquidity-ops modules,
StrategyRouter, BufferManager) of the deployed system on a fork pinned at block 507,560,841, so the real
BufferManager + Aave/Morpho warm adapters, real `UsdcMultiLendingVault` and its seven lending adapters, real
StrategyHealthRegistry, real PriceOracleMiddleware + Chainlink USDC feed, real GlobalConfig limits and real
USDC are exercised. 17 tests: upgrade preserves live state; W-1/2/9; loss/gain after request; §13-style
realise-through-the-real-stack funding; instant fallback (W-12) under the live 1-day lock; no cancel; no minimum;
insolvency pro-rata, order independence, recovery; and the NAV gate against the real components (healthy,
reverting strategy, DEGRADED in the real registry, and a real stale Chainlink feed after +3 days, no mocks).
Fork-only shims (explained in the file): the queue-storage scalars are re-based (the live layout lost two fields;
production uses a fresh vault) and the freeze bit is cleared once to route the new `syncInsolvencyState` selector.

**Findings from the live system (independent of this PR, but they decide whether requests work at go-live):**
1. At the pinned block the live BufferManager reported `warmNavValid == true` with a warm cache **13 hours old** —
   the I-10 situation of spec §8, in the wild.
2. `BufferManager.navRefreshInterval` is **21,600 s (6 h)**; the source comment says it must be below the 15-minute
   `MAX_WARM_NAV_AGE`. With the new gate, requests are only accepted for the short window after each refresh unless
   the keeper cadence (and this parameter) is brought under 15 minutes.
3. Realising from the live strategy loses ~0.4% on a 1.2 USDC position (rounding/slippage): see the dust tolerance.
4. Pre-existing and unrelated: `AdapterIsolationMatrix.test_Isolation_Euler` fails at "latest" on live Euler market
   headroom.

## 7. Tests

| Spec | Test |
|---|---|
| W-1 … W-15, §11 scenarios | `test/unit/core/EconomicExit_Spec.t.sol` (31 tests, incl. fuzz) |
| W-1, 2, 3, 4, 5, 6, 9, 11, 13, 14 in any reachable state | `test/invariants/EconomicExit_Invariants.t.sol` (stateful, handler-driven) |
| W-15 | `test_W15_noModuleReconstructsNavLocally` reads the module sources and fails if any sums the portfolio or reads strategy NAV directly |
| Order of operations (W-6) | `test_W6_orderOfOperations_assetsOwedIsPricedBeforeTheBurn` — fails if the burn precedes the pricing |
| Stale NAV | `test_s11_staleNav_requestRevertsEvenWhenWarmNavValidIsTrue` |
| Insolvency | `test_s11_insolvency_fullScenario`, `test_W3_*`, `test_W13_*` |
| No cancel | `test_W10_*`, `test_noCancelPath_*`, `Withdrawal_PauseMatrix_Invariants` |
| PR #13 regression (reservation lifecycle and every PoC) | `EpochedQueueModule.t.sol`, `ReservationConsumers.t.sol`, `SharePriceCollapse_Security.t.sol`, `QueueEpochModule_WithdrawFlow_POC.t.sol` — adapted where the scenario relied on shares being escrowed or on a loss landing between close and fund (see below) |

PR #13 PoCs that had to change shape, and why: a scenario that *drained* hot cash to starve funding is,
in the new model, an insolvency (gross < owed), which blocks the follow-up request the PoC needed. Those
PoCs now move hot cash into the warm bucket instead (`_moveHotToWarm`): free liquidity is exactly as
starved, the portfolio stays solvent, and the property under test — a later epoch or an instant exit
cannot spend cash reserved for an earlier funded epoch — is asserted unchanged.

## 8. Second review round (Stefano + Pier) — what changed, and one item still open

Both reviewers looked at the branch after the first round (§4 items 1–7, the adapter-shortfall fix
in §4 item 5b). This section is the response: what was fixed, exactly, and the one design question
(Pier's fourth point) that is a genuine product decision, not a bug — implemented mechanically where
that was possible, but not resolved unilaterally.

### 8.1 Fixed

1. **NAV soft refresh before the gate (Stefano).** `_crystallizeExit` now calls
   `_trySoftRefreshWarmNav()` — identical pattern to `ERC4626Module`'s deposit/mint path — before
   `_requireFreshNav()`. A request no longer reverts just because nobody happened to poke the cache
   in the last 15 minutes; it only reverts if the refresh itself fails or the result is still
   invalid/stale (dead keeper, broken adapter). The age check remains independent of the flag
   regardless. Every existing "stale NAV reverts" test was rewritten to force the refresh *itself*
   to fail (`setRefreshShouldRevert(true)` on the mock; `vm.mockCallRevert` on the real
   `BufferManager` on the fork) rather than relying on nobody refreshing — otherwise the fix would
   have made those tests unable to fail.

2. **Instant fallback pays the standard fee, not the instant one (Stefano).** `requestInstantWithdrawal`
   now decides the tier *before* crystallizing: cap and liquidity are checked against a conservative,
   pre-fee estimate (`convertToAssets(shares)`, gross — monotonically ≥ the eventual net
   `assetsOwed`, so a pass here always covers the smaller real amount), then `_crystallizeExit` is
   called exactly once with the tier already fixed. A request that falls back into the queue now
   crystallizes as `STANDARD` from the start, never `INSTANT`. New test:
   `test_W12_fallback_paysTheStandardFee_notTheInstantOne` (proves it with `immediateExitPenaltyBps`
   set high enough that the two tiers are visibly different). This resolves deviation §4.2 from the
   first round — the instant-fee-on-fallback behaviour documented there no longer exists.

3. **Deposit lock is a hard revert on both ordinary exit paths (Pier).** A new `_requireNotLocked`
   check runs before *any* crystallization in both `requestEpochWithdrawal` and
   `requestInstantWithdrawal`. Previously only the instant path consulted `lockPeriod`, and only as
   a soft "fall back to the queue" signal — since a request now crystallizes (prices + burns)
   regardless of path, that silently let a locked user's shares be burned and `totalOwed` created
   during the lock window. `DepositLockActive()` is the new error. Force exit is the deliberate,
   unchanged bypass. Every existing test that used `lockPeriod` as a deterministic trick to force
   the instant→queue fallback (four of them, none about locking itself) was rewritten to force the
   fallback a different way — cap exhaustion or a drained hot balance — since that trick no longer
   works (the call now reverts outright instead of falling back).

4. **Instant liquidity waterfall is hot → warm refill → queue, never a strategy redeem (Pier).**
   `_canInstant` now attempts one `BufferManager.refill()` call (best-effort, swallowed on failure)
   when hot alone is short, before giving up and falling back to the queue. It never reaches the
   strategy router — matching the architecture's original hot+warm-backs-instant intent.

5. **Instant cap base is snapshotted at cap-epoch rollover, independent of standard-queue activity
   (Pier).** A new `CoreStorage.capBaseSnapshot` field is set once per cap epoch (on
   `rollEpochIfNeeded() == true`, or lazily backfilled if still zero) and is what
   `requestInstantWithdrawal` sizes the bucket against — not live `totalAssets()`, which is
   `grossAssets − totalOwed` and would otherwise shrink every time a *standard* request grows
   `totalOwed`, coupling the supposedly-independent 10%-style instant bucket to unrelated queue
   activity. `consumeEpochCap` was already instant-only (standard requests never called it); the fix
   is entirely on the base side. Exposed via `CoreVault.capBaseSnapshot()`, and
   `CoreVaultLens.calculateCapImmediateRemaining` reads the same snapshot (falling back to live
   `totalAssets()` only when nothing has been snapshotted yet) so the preview matches enforcement.

6. **`fundEpoch` tops up an already-`Funded` epoch (Stefano).** Previously calling `fundEpoch` on a
   `Funded` epoch was an unconditional no-op. If `liabilityIndex` recovers after an epoch was funded
   at a lower index, its claimants are owed more than is earmarked, and nothing permissionless could
   pull the extra cash in — `realizeForReserveAndOps` is sized on the ops reserve, not this gap, and
   claims would revert `InsufficientFreeLiquidity` forever even once real liquidity existed elsewhere
   in the vault. `fundEpoch` now computes `targetReserve = scaledByIndex(unclaimed)` against the
   epoch's *current* `reservedRemaining` regardless of state, and pulls the *gap* (hot → warm →
   strategy, same waterfall and slippage buffer as before) whether that gap is a first-time fund
   (`currentReserve == 0`) or a top-up. The ordinary "already fully covered" no-op path is preserved
   byte-for-byte (same skip event, same cursor sync) when there is genuinely nothing to add.
   `test_topUp_claimRevertsWhenFreeCashShort_thenPaysFullAfterLiquidityReturns` covers the mechanism
   directly. **This is necessary but not sufficient — see §8.2.**

7. **Empty claims are rejected (Stefano).** `_crystallizeExit` now reverts `ZeroAmount` if
   `assetsOwed` rounds to 0. Not a withdrawal minimum (spec §6.4 keeps none — a 1-wei-share request
   that prices to a non-zero, if tiny, amount is still accepted); this only stops a claim worth
   *nothing* from occupying a slot in `outstandingClaimCount`, the dynamic-cap queue-depth signal —
   at the deploy default (`queueStressThreshold = 100`), a hundred zero-value requests alone would
   otherwise drive the instant cap to its floor for every real depositor.

8. **Dust-tolerance drift, measured precisely (Stefano).** `INSOLVENCY_FUNDING_DUST_BPS` is left at
   10 (0.1%) — this is a number for Multyr to sign off on, not something to unilaterally change.
   `test_s11_insolvencyFunding_dustTolerance_worstCaseDriftIsExactlyTenBps` constructs the exact
   worst case (hot short by precisely 10 bps of the epoch's target reserve) and asserts the
   realized payout is short by exactly 10 bps of what the pro-rata formula would otherwise give —
   not "approximately", the exact boundary value, so the number in front of Multyr is unambiguous.

9. **Single `MAX_WARM_NAV_AGE` ("to complete").** Previously three separate literals/constants
   (`CoreVault.sol` ×2, `ERC4626Module`, `EpochedQueueModule`) that could drift out of sync. Now one
   definition, `CoreStorage.MAX_WARM_NAV_AGE`; the two module-level `public constant`s are kept (ABI
   compatibility) but their value is sourced from it.

10. **`minClaimAmount` marked dead, not removed ("to complete").** It is functionally unused for
    exits under spec §6.4 (no withdrawal minimum), but the field is left in
    `IParamsProvider.WithdrawalParams` / `GlobalConfig.WithdrawalConfig` rather than removed: 16
    deploy/ops files read or assert on it, including a dedicated `SetMinClaimAmount.s.sol`, and
    `GlobalConfig` is governance-managed on-chain storage that would need a coordinated migration.
    Both struct fields now carry an explicit `@dev DEPRECATED` comment. Removal is a follow-up PR
    that touches deploy tooling, not this one.

11. **`MIN_STRATEGY_REDEEM` derived from the asset's decimals, not hardcoded to 6 ("to complete").**
    `_minStrategyRedeem()` computes `10 ** (decimals − 2)` (0.01 units of the underlying) from
    `IERC20Metadata(_asset()).decimals()` each call, so it is correct whatever asset the vault is
    deployed with — previously a `10_000` constant that silently assumed 6-decimal USDC.

12. **`_notifyIncentivesExit` receives the NET `assetsOwed`, not gross (Stefano, noted for the
    record).** This was already true in the first-round implementation (`_crystallizeExit` calls it
    with `assetsOwed`, the post-fee amount) — flagged here explicitly per review, since the original
    `QueueModule` this was ported from notified on the gross share value.

13. **New tests requested explicitly:** five claimants sharing one insolvency pro-rata
    (`test_s11_insolvency_fiveClaimants_allGetTheIdenticalRatio_anyOrder`); the real
    `StrategyRouter` with a real (mocked-quote) oracle gone stale *and* hot deliberately scarce, at
    the unit level, proving the NAV-validity gate and the liquidity/funding path are independent
    mechanisms (`test_realRouter_staleOracle_andInsufficientHot_areIndependentGates` in
    `AdapterShortfall.t.sol`); the dust-tolerance drift measurement (item 8 above).

14. **`EpochedQueueModule`'s internal size-gate target raised from 16KB to 20KB.** The module now
    carries the whole exit engine (crystallization, the NAV gate, insolvency, funding top-up, the
    independent cap snapshot, lock enforcement) — a materially larger scope than the "small,
    stateless module" budget the original 16KB target was set for. Measured at review time: 16,915
    bytes, ~7.6KB of margin below the real EIP-170 limit (24,576 bytes). `AdminModule` and
    `ERC4626Module` are untouched and still comfortably under the original 16KB.

### 8.2 Open — needs a decision before merge (Pier's fourth point)

**The top-up fix (§8.1 item 6) makes funding liquidity catch up with a recovered index. It does not,
and cannot by itself, fix creditor parity across time.** Pier's example, worked through on this
branch: Alice and Bob are each owed 50 (gross 50, index 50%). Alice claims now: paid 25, her claim
is closed for good. The vault later recovers 25 (gross back to 50, but now only Bob's 50 is still
outstanding): index is 100%. Bob claims: paid 50. Alice got 25, Bob got 50, on identical nominal
claims — not because Bob claimed in a different *order* (W-14's "no first-claimer advantage" is still
true: at any single instant, every outstanding claim is paid at the same index), but because Bob
claimed *later*, after a recovery Alice's payment had already missed.

This is real and not fixed by anything in this round. It is a genuine fork in the design, and
resolving it changes behaviour either way, so it needs Multyr's answer, not a unilateral pick:

- **(a) Crystallize the recovery ratio for a cohort.** Once an epoch (or some wider grouping) is
  funded at a given index, that ratio is locked for every claim in it, permanently — a later
  recovery inside the *same* cohort no longer helps anyone left in it (it would instead flow to
  remaining *shareholders*, or need its own separate distribution rule). Mechanically the cheaper
  option: no new per-claim state, `payoutAt` already computes a fixed ratio once funded, it would
  just need to stop tracking `liabilityIndex` live for already-funded epochs and pin it at fund
  time instead of at claim time.
- **(b) Give every partially-paid creditor a residual entitlement.** A claim paid below its nominal
  `assetsOwed` keeps the unpaid remainder as a live, still-recovering claim rather than being closed
  outright. Fairer in the sense Pier describes (nobody's payment is ever "final" while the vault is
  short), but structurally bigger: `EpochClaim.claimed` is currently a boolean, all-or-nothing: this
  needs the claim to track a *paid-so-far* amount and stay open until it reaches nominal, which
  touches `_settleClaimAccounting`, `_coverPayout`, `outstandingClaimCount`, and every invariant
  that currently assumes a claim is binary (open or closed).

Spec §9.2's own words — "apply the same proportional recovery rate to all affected outstanding
claims" — read more like (a) than (b), but the spec's insolvency section was written before this
exact interaction was traced through, and does not decide it explicitly either way. **Not
implemented in this round.** Whichever Multyr picks, the mechanical work is scoped above and this
document should be updated with the chosen model before merge, per Pier's own framing: "otherwise
'order doesn't matter' is only true while the liability index remains unchanged between claims."

### 8.3 Fork-suite infrastructure note (not a contract issue)

5 of the 22 Arbitrum fork tests are blocked by the free public RPC (`arb1.arbitrum.io/rpc`), not by
anything in this PR: `test_fork_fundEpoch_realisesFromRealWarmAndStrategy_thenClaimPaysFixedAmount`,
`test_fork_fluidHack_severe_insolvency_claimsStillPayAtTheRecoveryRatio`,
`test_fork_insolvency_indexRecoversAutomatically_whenAssetsAreRestored`,
`test_fork_insolvency_proRata_sameIndex_noFirstClaimerAdvantage_andRecovery`,
`test_fork_strategyWithdrawalsFail_fundingFailsSafe_thenRecovers`. All five force a *large* redeem
out of the real `UsdcMultiLendingVault` strategy. Traced with `-vvvv`: `EpochedQueueModule.fundEpoch`
correctly calls `strategy.withdraw(...)`; INSIDE that call, the real strategy's own
`deployIdleToAdapters` → `execSelectAllocation` logic tries to rebalance the remaining idle funds
across its Venus/Aave/Morpho sub-adapters, and one of those calls (`currentAPYBps()` on the Morpho
adapter, reading Aave's reserve data) returns `FatalExternalError` — the free endpoint's archive
node not serving state that deep for this pinned block. This is outside `src/` entirely: it is
third-party strategy-package internals, not reachable from anything this PR touches, and is the
same category of RPC limitation as the pre-existing, unrelated `test_Isolation_Euler` failure (§6).
Two smaller-redeem tests that hit `expectRevert` immediately after a mocked strategy failure
(`test_fork_navGate_realStrategyValuationFails_rejected`,
`test_fork_liveWarmNav_flagTrueButCacheStale_requestsRevert`) were flaky for the same underlying
reason on some runs and reliably pass in isolation and on repeat full-suite runs. A paid/archive RPC
(`ARBITRUM_RPC_URL` env var, already supported by the suite) should clear all five deterministically;
not verified in this session.
