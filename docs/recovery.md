# recovery.md — Multyr Core: Emergency Module Recovery

**Version**: 1.0.0 | **Status**: implemented (kpi4/epochedqueue-cutover)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Why Not Generic Upgradeability](#2-why-not-generic-upgradeability)
3. [Architecture](#3-architecture)
4. [Recoverable Groups](#4-recoverable-groups)
5. [Immutable Recovery Policy](#5-immutable-recovery-policy)
6. [Lifecycle](#6-lifecycle)
7. [Proposal Digest](#7-proposal-digest)
8. [Security Approver Rotation](#8-security-approver-rotation)
9. [What Recovery Cannot Do](#9-what-recovery-cannot-do)
10. [Relationship to Migration](#10-relationship-to-migration)
11. [Critical Caveat](#11-critical-caveat)
12. [Events](#12-events)
13. [Testing](#13-testing)
14. [Deployment Checklist](#14-deployment-checklist)

---

## 1. Overview

Emergency Module Recovery is a narrow, immutable mechanism that lets `ROOT_TIMELOCK` replace the module implementation behind one of four pre-approved, economically-isolated selector groups after a sealed vault's normal routing (`setModule`/`setModulesBatch`) has been permanently disabled by `freezeRouting()`.

It exists because a software defect discovered after routing is frozen would otherwise require migrating the entire vault, even when the defect is confined to a single module. It does **not** exist to let governance continuously evolve the protocol after sealing — see [§2](#2-why-not-generic-upgradeability).

This document, and the implementation it describes, is Multyr's response to the *Multyr Core Upgradeability, Emergency Recovery & Incident Response Architecture Review* (snapshot `0bab749`), which rejected a general-purpose post-seal `RecoveryController` in favor of exactly this narrower design. See `docs/developer-response-recovery-architecture.{html,pdf}` for the full point-by-point response.

## 2. Why Not Generic Upgradeability

> Multyr should support Emergency Module Recovery, not permanent protocol upgradeability. — architecture review §1

The review's concern with a general `RecoveryController` was that it risks converting Multyr from a *progressively immutable* protocol into a *permanently governance-upgradeable* one — materially changing the trust model users and allocators rely on. `RecoveryGate` is designed so that, structurally, it cannot do this:

- It cannot add selectors, relax roles, or touch anything outside `moduleOf` for one pre-approved group.
- Its own policy (delay, cooldown, vault, root timelock) is immutable — set once at construction, no setters exist.
- The recoverable groups themselves are fixed at compile time (read from `SelectorLib`), not configurable post-deployment.
- `CoreVault`'s constitutional surface — the shell, governance addresses, sealing logic, and the recovery policy binding itself — is entirely outside `RecoveryGate`'s reach by construction (see [§9](#9-what-recovery-cannot-do)).

## 3. Architecture

```
ROOT_TIMELOCK
   |  schedule(RecoveryGate.propose(groupId, newModules, reasonRef))
   v
RecoveryGate (immutable, no proxy)
   |  propose()    — only ROOT_TIMELOCK
   |  approve()    — only SECURITY_APPROVER, bound to an exact digest
   |  vetoCancel() — only CoreVault.vetoer(), read live
   |  execute()    — open caller, once approved + matured + not vetoed
   v
CoreVault.recoverModuleGroup(groupId, newModules)
   |  onlyRecoveryGate
   |  selectors derived from SelectorLib, not trusted from the caller
   |  never writes roleOf — role relaxation is structurally impossible
   v
Atomic replacement of every selector in the group
```

Source: `src/governance/RecoveryGate.sol`, `src/core/CoreVault.sol` (`recoverModuleGroup`, `setRecoveryGate`, `onlyRecoveryGate`).

`RecoveryGate.propose()` is `onlyRootTimelock`-gated the same way `SystemSealer.verifyAndSeal()` is scheduled today — through `rootTimelock.scheduleBatch([...])`. The recovery-specific delay (`minDelay`, [§5](#5-immutable-recovery-policy)) is `RecoveryGate`'s own clock, layered **on top of**, not instead of, the timelock's own scheduling delay.

## 4. Recoverable Groups

Selector sets are read directly from `src/core/libraries/SelectorLib.sol` — the same source of truth `CoreVault`'s own deployment wiring uses. There is no second, independently-maintained selector registry to drift out of sync (review §9's whitelist requirement, satisfied by reuse rather than a new contract).

| Group ID | Constant | Module | Selectors |
|---|---|---|---|
| 0 | `EPOCH_QUEUE_GROUP` | `EpochedQueueModule` | `getQueueModuleSelectors()` + `getQueueModuleViewSelectors()` |
| 1 | `ERC4626_GROUP` | `ERC4626Module` | `getERC4626ModuleSelectors()` |
| 2 | `LIQUIDITY_GROUP` | `LiquidityOpsModule` | `getLiquidityOpsModuleSelectors()` |
| 3 | `FIXED_MATURITY_GROUP` | `FixedMaturityModule` | `getFixedMaturityModuleSelectors()` |

**Permanently excluded, not merely unlisted:** `AdminModule`'s 26 owner selectors (governance/sealing/authorization surface — timelock submit/accept/revoke, vetoer rotation, component setters, `freezeParams()`, `setEcosystem()`) have no group ID at all. Every direct `CoreVault` function (`setModule*`, `freezeRouting`, `pause*`, `setSelectorRegistry`, `setRecoveryGate`, `authorizeModule`) is not `moduleOf`-routed in the first place — there is no selector for `recoverModuleGroup` to touch even if a group ID were mis-specified. `StrategyRouter`, `BufferManager`, `StrategyHealthRegistry`, `FeeCollector`, `GlobalConfig` are satellite contracts referenced by address, not routed selectors — they remain governed exclusively by `AdminModule`'s existing timelocked `submit*/accept*/revoke*` component-setter pattern, untouched by this mechanism.

## 5. Immutable Recovery Policy

Fixed at `RecoveryGate` construction — no setters exist for any of these:

| Field | Value | Rationale |
|---|---|---|
| `vault` | constructor arg | The one `CoreVault` this gate serves |
| `rootTimelock` | constructor arg | The one address that may `propose()` |
| `minDelay` | constructor arg, `>= 14 days` enforced by the constructor itself | Review §12 — recovery is remediation, not same-block containment |
| `cooldown` | constructor arg | Minimum gap between two completed recoveries of the *same* group — prevents salami-slicing continuous evolution through repeated individually-reviewable recoveries |
| Recoverable groups | compile-time, via `SelectorLib` | Not configurable post-deployment at all |
| `securityApprover` | constructor arg, **the one rotatable field** | See [§8](#8-security-approver-rotation) |

A misconfigured deployment cannot exist: `RecoveryGate`'s constructor reverts with `DelayTooShort()` if `minDelay < 14 days`, so there is no way to deploy a gate with a shorter delay than the review's floor.

## 6. Lifecycle

1. **Propose** — `ROOT_TIMELOCK` calls `propose(groupId, newModules, reasonRef)`. Reverts if `newModules.length` doesn't match the group's selector count, if a proposal for that group is already pending, or if the group's cooldown hasn't elapsed since its last completed recovery. Computes and stores a digest ([§7](#7-proposal-digest)), starts the `minDelay` clock.
2. **Approve** — `SECURITY_APPROVER` calls `approve(groupId, digest)`, supplying the exact digest being approved. If `propose()` is called again for the same group before this executes, the digest changes and any prior approval is silently invalidated.
3. **Veto (optional, any time before execution)** — `CoreVault.vetoer()` (read live, not cached) calls `vetoCancel(groupId)`. Cancellation-only — the vetoer has no other capability on `RecoveryGate` and cannot propose, approve, or execute.
4. **Execute** — anyone calls `execute(groupId)` once `block.timestamp >= eta`, within a 7-day execution window, once approved and not vetoed. Calls `CoreVault.recoverModuleGroup(groupId, newModules)`, which atomically rewrites every selector in the group — the whole group replaces together or the call reverts, never a partial mix of old and new implementations (review §10).

## 7. Proposal Digest

Per review §13, the digest committed at `propose()` time binds:

- `vault`, `block.chainid`, `groupId`
- the group's exact selector set
- every selector's **current** `moduleOf` address and codehash
- the **proposed** module address(es) and their codehash(es)
- `MANIFEST_VERSION` (a `RecoveryGate` constant)
- `reasonRef` — an off-chain reference identifier (e.g. an incident report hash)

"Unchanged role mapping" (also required by review §13) is not a digest field because it cannot vary: `recoverModuleGroup()` never writes `roleOf` at all ([§9](#9-what-recovery-cannot-do)), so there is nothing about roles for the approver to review or for the digest to commit to.

## 8. Security Approver Rotation

`securityApprover` is the one field in an otherwise fully immutable policy that can change — resolving the open question raised in the developer response (`docs/developer-response-recovery-architecture` §6): a permanently fixed approver address is itself an operational risk (signer key loss over a multi-year sealed deployment with no recourse).

Rotation uses the same propose/execute/veto shape as a recovery itself:

- `proposeApproverChange(newApprover)` — `onlyRootTimelock`, starts the same `minDelay` clock.
- `executeApproverChange()` — open caller, after the delay.
- `vetoApproverChange()` — `CoreVault.vetoer()` only.

Because rotation is subject to the same delay as a recovery, a compromised `ROOT_TIMELOCK` cannot install a friendly approver in time to affect any recovery already in flight — the earliest a new approver could take effect is no sooner than a recovery proposed at the same time would mature.

## 9. What Recovery Cannot Do

Enforced structurally, not by convention (review §11):

- **Cannot add new selectors** — `recoverModuleGroup` only ever rewrites `moduleOf` for the group's fixed, `SelectorLib`-derived selector set.
- **Cannot relax or change roles** — `recoverModuleGroup` takes no role parameter at all and never writes `roleOf`.
- **Cannot expose previously privileged selectors** — same reason.
- **Cannot touch CoreVault's shell, ownership, guardian, or vetoer** — none of these are `moduleOf`-routed selectors.
- **Cannot modify its own policy** — no setters exist on `vault`, `rootTimelock`, `minDelay`, `cooldown`, or the recoverable group definitions.
- **Cannot reach `AdminModule`'s governance/sealing selectors, or any satellite component** ([§4](#4-recoverable-groups)).
- **The Guardian cannot call anything on `RecoveryGate`** — it has no role in the recovery lifecycle at all, consistent with review §3.3 (Guardian is fast-restrict, never constructive).

## 10. Relationship to Migration

Emergency Module Recovery does not solve every defect. If the flaw is in `CoreVault`'s direct functions, the fallback routing dispatcher, core storage architecture, the recovery entry point itself, or a critical immutable governance binding, the correct solution remains **migration** — deploying a new vault and moving user funds, not attempting to repair the sealed shell in place. This is a deliberate boundary: it prevents the recovery mechanism from becoming capable of rewriting the entire system (review §36).

## 11. Critical Caveat

Restricting recovery to existing selectors, unchanged roles, pre-approved groups, and expected codehashes does **not** mathematically prove that a replacement module only repairs a bug. A replacement module executed through `delegatecall` can still materially alter economic behavior while using exactly the same selectors and authorization roles, and it can interact with vault storage and assets.

The correct claim is therefore: *Emergency recovery cannot expand the sealed authorization and selector topology, and is procedurally restricted to remediation.* It is not, and should not be represented as, cryptographic proof that every future replacement contains only bug fixes. That guarantee comes from the combination of on-chain constraints (this contract) with governance delay, independent security approval, transparent codehash commitment, and pre-execution review and testing — not from any one of those alone (review §4).

## 12. Events

| Event | Emitted by | When |
|---|---|---|
| `RecoveryProposed(groupId, digest, eta, reasonRef)` | `RecoveryGate` | `propose()` |
| `RecoveryApproved(groupId, digest)` | `RecoveryGate` | `approve()` |
| `RecoveryVetoed(groupId, digest)` | `RecoveryGate` | `vetoCancel()` |
| `RecoveryExecuted(groupId, digest, newModules)` | `RecoveryGate` | `execute()` |
| `ApproverChangeProposed/Executed/Vetoed(...)` | `RecoveryGate` | approver rotation |
| `RecoveryGateSet(gate)` | `CoreVault` | `setRecoveryGate()` |
| `ModuleGroupRecovered(groupId, newModules)` | `CoreVault` | `recoverModuleGroup()` |

## 13. Testing

Acceptance tests: `test/invariants/Recovery_Invariants.t.sol`. Incident simulations: `test/incident-sim/`. See [architecture review §40](#) for the full acceptance-test list this suite is built against.

## 14. Deployment Checklist

Before sealing a vault that wires recovery:

1. Deploy `RecoveryGate` with the vault's address, `ROOT_TIMELOCK`, the chosen `SECURITY_APPROVER`, `minDelay >= 14 days`, and the chosen `cooldown`.
2. Call `CoreVault.setRecoveryGate(gate)` — set-once, before `freezeRouting()`/sealing.
3. Include `recoveryGate` and `recoveryManifestVersion` (`RecoveryGate.MANIFEST_VERSION()`) in the `SystemSealer.SealConfig` passed to `verifyAndSeal()` — the seal will reject a mismatch between the manifest and what's actually wired into the vault.
4. If a deployment deliberately does not wire recovery, pass `recoveryGate: address(0)` and `recoveryManifestVersion: 0` — `SystemSealer` treats this as a valid, explicit "no recovery" configuration, not an error.
