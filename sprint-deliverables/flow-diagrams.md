# Flow Diagrams

Mermaid diagrams for the final review.

## 1. Core Routing

```mermaid
flowchart TD
    A["External call"] --> B{"Explicit CoreVault function?"}
    B -->|yes| C["CoreVault executes wrapper"]
    B -->|no| D["fallback()"]
    D --> E["module = moduleOf[msg.sig]"]
    E --> F["role = roleOf[msg.sig]"]
    F --> G{"Role check passes?"}
    G -->|no| H["revert"]
    G -->|yes| I["delegatecall module"]
    I --> J["module reads namespaced storage"]
    J --> K["return/revert bubbled to caller"]
```

## 2. DepositRouter With Permit2

```mermaid
sequenceDiagram
    participant U as User
    participant R as DepositRouter
    participant P as Permit2
    participant A as USDC
    participant V as CoreVault

    U->>R: depositWithPermit2(amount, receiver=user, sig)
    R->>P: permitTransferFrom or allowanceTransferFrom
    P->>A: transferFrom(user, router, amount)
    R->>A: approve(vault, amount or max)
    R->>V: depositFor(amount, user)
    V->>A: transferFrom(router, vault, amount)
    V-->>U: mint shares
```

Security invariant: the vault pulls from the router because `msg.sender` is the
router. The user is never passed as an arbitrary payer to the vault.

## 3. Standard Queue Exit

```mermaid
flowchart TD
    A["User requestClaim(shares, receiver)"] --> B["QueueModule validates state"]
    B --> C["Shares moved into queue accounting"]
    C --> D{"Can settle instantly?"}
    D -->|yes| E["pay hot USDC to receiver"]
    D -->|no| F["record FIFO claim"]
    F --> G["Keeper/process call"]
    G --> H["settle fees and crystallize perf fee"]
    H --> I{"Enough hot liquidity?"}
    I -->|no| J["refill from warm / realize strategy"]
    I -->|yes| K["settle claim batch"]
    J --> K
```

## 4. Force Withdraw

```mermaid
flowchart TD
    A["forceWithdraw(assets, receiver, owner, plan, maxShares)"] --> B["Check FM state and pause"]
    B --> C["Soft refresh warm NAV"]
    C --> D["Calculate shares and force fees"]
    D --> E{"shares <= maxShares?"}
    E -->|no| R["revert SlippageExceeded"]
    E -->|yes| F["Spend allowance if caller != owner"]
    F --> G["Source hot/warm/strategy liquidity"]
    G --> H{"Exact assets available?"}
    H -->|no| R
    H -->|yes| I["Burn shares and transfer exact assets"]
```

## 5. Force Withdraw All

```mermaid
flowchart TD
    A["forceWithdrawAll(receiver)"] --> B["Read all caller shares"]
    B --> C["Deduct force fee shares"]
    C --> D["targetAssets = convertToAssets(netShares)"]
    D --> E["Try hot -> warm -> strategy force liquidity"]
    E --> F["Burn all net shares"]
    F --> G["assetsReceived = min(hot, targetAssets)"]
    G --> H["Transfer assetsReceived"]
```

Review note: this path is best-effort and lacks `minAssetsOut`; it remains the
main residual risk.

## 6. Strategy Deployment

```mermaid
flowchart TD
    A["deployToStrategies(maxAmount)"] --> B["Compute surplus"]
    B --> C["router.planDeposit(surplus)"]
    C --> D["plan uses registered/enabled strategies"]
    D --> E["Core transfers USDC to strategies"]

    X["deployToStrategiesWithPlan(plan,maxAmount)"] --> Y["OWNER_OR_GUARDIAN only"]
    Y --> Z["Validate each plan[i].strat is enabled"]
    Z --> E
```

## 7. Governance Component Change

```mermaid
flowchart TD
    A["Pre component timelock"] --> B["setEcosystem allowed for bootstrap"]
    B --> C["enableComponentsTimelock"]
    C --> D["Direct component setters blocked"]
    D --> E["submitBufferManager / submitRouter"]
    E --> F["ETA = now + paramMinDelay"]
    F --> G{"Vetoer revokes?"}
    G -->|yes| H["pending cleared"]
    G -->|no, after ETA| I["accept change"]
```

## 8. System Seal

```mermaid
sequenceDiagram
    participant T as Root Timelock
    participant S as SystemSealer
    participant V as CoreVault
    participant C as Components

    T->>S: verifyAndSeal(config)
    S->>V: verify owner, guardian, vetoer, routing, component timelock
    S->>V: verify selector roles
    S->>C: verify component ownership/governance
    S->>S: compute deterministic configHash
    S->>V: sealBySealer(configHash)
    V-->>T: system sealed
```
