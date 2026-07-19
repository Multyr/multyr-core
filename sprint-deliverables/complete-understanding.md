# Complete Understanding

This document captures the deeper design rationale behind the Multyr Core
architecture. It complements `architecture-understanding.md`, which is the
high-level walkthrough, by explaining why the main architectural choices were
made.

## 1. Diamond-Lite Selector Routing

The vault needs to appear as one address. The share token and user-facing
functions must live on a single contract, but ERC-4626 deposits, queue
settlement, governance, fixed maturity, and liquidity operations are too large
to safely fit into one monolithic contract. A single contract would also create
a large audit surface where unrelated domains can accidentally interact.

A full EIP-2535 Diamond was avoided because it adds more machinery than this
system needs: diamond cuts, loupe introspection, facet arrays, and a more complex
storage model. Multyr uses a simpler diamond-lite router:

```solidity
module = moduleOf[msg.sig];
role = roleOf[msg.sig];
module.delegatecall(msg.data);
```

The routing table is just `mapping(bytes4 => address)` plus
`mapping(bytes4 => uint8)`. The fallback path checks the selector role and then
delegates to the configured module.

`delegatecall` is required because modules need to read and write vault state:
shares, fees, queue state, epoch accounting, component addresses, and flags. If
the modules used ordinary `call`, all state would need to be passed in and
returned as diffs, which would be fragile and gas-heavy.

## 2. Namespaced EIP-7201 Storage

All modules run in the vault storage context, so storage collisions are the main
danger. The repo uses EIP-7201-style namespaces:

```solidity
SLOT = keccak256(
    abi.encode(uint256(keccak256("dsf.core.main.storage.v1")) - 1)
) & ~bytes32(uint256(0xff));
```

The `- 1` avoids a known preimage issue. The `& ~0xff` aligns the namespace to a
256-byte boundary, leaving room for struct growth.

There are separate storage libraries because each one maps to an audit domain:

| Storage Library | Why It Exists |
|---|---|
| `CoreStorage` | routing, ownership, components, system flags |
| `FeeStorage` | fee params, HWM, pending governance values |
| `QueueStorage` | claims, FIFO queue, epoch settlement state |
| `FixedMaturityStorage` | fixed-maturity lifecycle and funding state |

This separation makes review easier. A reviewer auditing fee logic can focus on
`FeeStorage`; a reviewer auditing queue settlement can focus on `QueueStorage`.

## 3. SelectorRegistry As Immutable Policy

`SelectorRegistry` is a separate deployed contract with pure functions only. It
has no storage, no admin, and no upgrade path. Its selector checks are compile-
time constants.

The reason for separating it from `CoreVault` storage is safety. If required
roles lived only in mutable vault storage, an owner mistake or compromised owner
could wire an owner-only selector as public. For example, a governance setter
could accidentally become callable by anyone.

The registry is consulted at wire time, not on every call. This is the right gas
tradeoff:

- runtime deposits and exits do not pay an external registry call
- deployment or governance wiring reverts immediately if a known selector is
  assigned the wrong role
- the invalid state never lands on-chain

## 4. packedFlags As uint256 Bitmap

The vault stores boolean system state in `CoreStorage.packedFlags`, a single
`uint256` bitmap. It includes pause flags, routing freeze, component timelock,
system seal, dead deposit done, fee initialization, performance fee
initialization, and the reentrancy lock.

The reasons are straightforward:

- `uint256` is one EVM storage slot.
- Reading or writing any flag touches one slot.
- A `uint64` would fit the current flags, but it costs the same as `uint256` for
  storage access and leaves less expansion room.
- Adding a new flag is adding a bit constant, not changing the storage layout.

This is why `uint256` makes sense even though the current flag count is much
smaller than 256 bits.

## 5. Three Liquidity Tiers

The vault uses three liquidity tiers:

- **Hot**: USDC directly held by `CoreVault`. This is instant and exact.
- **Warm**: assets held in warm adapters through `BufferManager`. This can be
  recalled but may involve adapter slippage.
- **Strategy**: yield positions behind `StrategyRouter`. This is the slowest and
  may involve partial withdrawals, strategy-specific mechanics, or failures.

`totalAssets()` sums all three and is the canonical NAV for share price math,
fee accounting, and conversion functions. This value must be accurate because it
directly affects `convertToShares`, `convertToAssets`, deposits, exits, and HWM
fee logic.

The operational NAV cache is separate. It is acceptable for keeper decisions
such as whether surplus can be deployed. It must not be used for fee math or
user share-price calculations.

## 6. Async Standard Exits And Force Exits

Standard ERC-4626 `withdraw` and `redeem` revert with
`AsyncWithdrawalRequired`. `maxWithdraw` and `maxRedeem` return `0`, which is
ERC-4626-compliant because synchronous withdrawal is not available.

The reason is fairness. If the vault allowed direct synchronous exits while most
assets were deployed, early redeemers could drain hot USDC and later redeemers
would be disadvantaged. The queue gives users FIFO and epoch-based treatment.

Force exits exist for emergency liquidity:

- `forceWithdraw` is the protected exact-asset path. It has a `maxShares`
  slippage guard and a user-provided pull plan.
- `forceWithdrawAll` exits the whole share position and pays best-effort
  liquidity. This path is simple and deterministic, but it should be treated as
  a residual risk until it has `minAssetsOut` or another protection.

## 7. Processor Mint/Burn Pattern

Modules execute through `delegatecall`, but ERC-20 `_mint`, `_burn`, and
`_transfer` are internal functions on `CoreVault`. Solidity internal calls are
compiled as jumps within the same bytecode, so module bytecode cannot call those
internal functions directly.

`CoreVault` exposes processor callbacks:

- `processorMint`
- `processorBurn`
- `processorTransfer`
- `processorSpendAllowance`

These functions check module authorization before touching share balances.
Modules call back into the vault when they need share accounting. This keeps
ERC-20 internals inside `CoreVault` while still allowing module logic to perform
mint, burn, transfer, and allowance operations.

## 8. Dead Deposit

The dead deposit protects against the first-depositor ERC-4626 inflation attack.
Without a starting supply, an attacker can manipulate initial share price with a
small first mint plus donation.

`seedDeadDeposit` mints initial shares to the dead receiver and sets
`FLAG_DEAD_DEPOSIT_DONE`. It is one-shot. This prevents repeated dead deposits
from being used to manipulate share price later.

The system sealer requires the dead deposit flag before production seal, so a
vault should not enter production with zero initial share supply.

## 9. paramMinDelay And Submit/Accept Governance

Fee parameters and performance fee parameters are not meant to change
immediately in production. The owner submits a change, the vault records an ETA,
and the owner can accept only after `paramMinDelay`. The vetoer can revoke before
acceptance.

The purpose is user protection. Fee changes directly affect user value. A delay
gives users and vetoers time to react before the change becomes active.

`paramMinDelay` itself follows the submit/accept pattern. That prevents an owner
from reducing the delay to zero and changing sensitive params in the same
transaction.

## 10. Component Timelock As One-Way Ratchet

`enableComponentsTimelock()` sets `FLAG_COMPONENTS_TIMELOCKED`. There is no
disable function. This one-way design is intentional.

Buffer manager and strategy router are critical because they control where vault
liquidity moves. After the component timelock is enabled, direct component swaps
are blocked and updates must use submit/accept paths with delay.

This protects against a compromised owner key after production. A malicious
router or buffer manager swap becomes observable before execution, giving the
vetoer and users time to respond.

The sealer checks this flag before sealing. Production seal therefore requires
the one-way component timelock to be active.

## 11. Root Timelock Ownership And SystemSealer

After deployment, ownership moves from the deployer to the root timelock. This
makes production governance delayed and observable.

`SystemSealer` is separate from `CoreVault` because its job is specialized:
verify final deployment invariants, then call the vault's seal function. Keeping
it separate makes it easier to audit and avoids bloating the vault runtime.

The production path is:

```solidity
SystemSealer.verifyAndSeal(config);
CoreVault.sealBySealer(configHash);
```

`sealBySealer` checks that `msg.sender` is the authorized sealer. The sealer is
set once before production seal. The final seal sets `FLAG_SYSTEM_SEALED`.

## 12. Start-Paused Deployment

`CoreVault` starts paused. This is deliberate because deployment and module
wiring can span multiple transactions. During that window, the vault address
exists but selectors or components may not be fully wired.

Starting paused prevents accidental interaction before the vault is ready. The
vault should only be unpaused after modules, roles, components, initial params,
dead deposit, ownership transfer, and seal prerequisites are handled.

## 13. DepositRouter Belongs In Periphery

Permit2 integration, referral binding, and signature handling are UX/periphery
concerns. The vault only needs one invariant: `msg.sender` is the payer.

The safe router pattern is:

1. Pull user funds into the router with Permit2.
2. Approve the vault from the router.
3. Call `depositFor(amount, user)` or `deposit(amount, user)`.

This keeps the vault clean and composable. A new router, referral system, batch
deposit helper, or signature scheme can be deployed without changing vault core
logic.

## 14. Review Summary

The architecture chooses small, explicit trust boundaries:

- selector roles are immutable policy
- storage domains are namespaced
- the vault is one user-facing address
- modules write shared state only through delegatecall
- governance changes are delayed and vetoable
- critical component timelocks are one-way
- deposits never accept an arbitrary third-party payer
- production seal verifies final ownership and routing state

That is the core mental model to carry into the final review.
