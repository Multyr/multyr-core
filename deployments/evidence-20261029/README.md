# Core main vs deployed contracts — 29 October 2026

**19/19 PASS** at Arbitrum block **519186126** (`0x987ad2045e500ff92b10addac4b50864fac5ab85c3ea68dbf6c8a98600e0ecb3`).
Core source: `703507d8a93165446f644331e99e08f6c0a7b48b` (`main` read on 29 October).
Source contracts were rebuilt from an isolated git archive with the pinned submodules and
Solidity 0.8.28, optimizer 200, viaIR, Shanghai. Archived remappings are necessary to reproduce
metadata byte-for-byte; a default build in another directory embeds different absolute paths.

For every contract: compiled creation prefix equals the RPC transaction input prefix; creation
receipt succeeds; CREATE trace output equals pinned current runtime; compiled runtime with
trace-derived immutable values equals that same runtime. **No bytes were masked or stripped.**
Constructor ABI, encoded arguments, immutable values and SHA-256 hashes are in
[the full proof](core-main-exact-bytecode-and-ownership.json). This is code identity, not an audit
of every current mutable parameter.

| Contract | Deployed address | Result |
|---|---|---|
| VaultFactory | `0xfde16c52e89ba078e9f71cc64c2256c8e66cbb01` | PASS |
| GlobalConfig | `0x5680e4948759569dcb9d2eab6a5504d733c83b2a` | PASS |
| FeeCollector | `0x6917ce91cdc284e637ef51dc844fefca83789e92` | PASS |
| PriceOracleMiddleware | `0x93c94af96e7e52ad5029ce8fea84d14583518b76` | PASS |
| StrategyHealthRegistry | `0x5a866d66089ce7ee63748b172801fbfd584451ff` | PASS |
| SelectorRegistry | `0x57719e54f531d49f73a49d453b594fc857247fee` | PASS |
| SystemSealer | `0x6c259f1d143fc6de138a26624038819342756af9` | PASS |
| CoreVault | `0x5e0cdb76487bd96ff069ef7f78eadf5b5909c8cb` | PASS |
| EpochedQueueModule | `0xccad3125667639b1a49667be8dd201e66b0a3b21` | PASS |
| AdminModule | `0x0693ffe87ee54494c4ead1da679bb01af765938b` | PASS |
| ERC4626Module | `0x1e4884436f1447f491a137c497d1a94c864a991f` | PASS |
| LiquidityOpsModule | `0x24715ed56e665b4391a2cc83ad6958534e60d84d` | PASS |
| BufferManager | `0x9b3fe5c76e0c10de254ee2153f71df6a96020d96` | PASS |
| StrategyRouter | `0x37847d2e12892e3298dee695e7e971fba0ca3e24` | PASS |
| AaveV3WarmAdapter_USDC | `0xd9a47bda143819bc01962bf43acd928789a90b66` | PASS |
| MorphoVaultWarmAdapter_USDC | `0x1df16ac92908feee3b104c630d818edfd3c75c1e` | PASS |
| VaultUpkeep | `0xcd31634f472fcc1d0b64fae3ed72bb7c0792b55f` | PASS |
| RecoveryGate | `0x45261d190f7192a68736cf058ad9448ebd53a560` | PASS |
| ClaimSettlementUpkeep | `0x4e845762e66518f34641326c7f77faf4b81c1260` | PASS |

## Current governance

CoreVault.owner(), VaultFactory.owner(), FeeCollector.governor() and
RecoveryGate.rootTimelock() all return **0x70ef444799D6FBbE0865bA598Bee6795e064a326**.
All four corresponding pending-authority getters return zero. The deployer is not the
governing authority of these four contracts at this block. This does not assert absence of
every other privileged role.

The pending-handover fields in `broadcast/core-addresses.json` are historical and superseded
for current-ownership purposes by this snapshot. That file is preserved, not hand-edited.

## Reproduce

Use the exact Core commit and initialized pinned submodules in a clean directory. Set RPC_URL
to an Arbitrum endpoint supporting `debug_traceTransaction` with callTracer.

```sh
python3 script/release/rebuild_evidence.py --source-root /path/to/clean-main \
  --metadata deployments/evidence-20261029/compiler-recipes.json \
  --solc /path/to/solc-0.8.28 --out /tmp/core-exact-artifacts
python3 script/release/verify_chain.py --artifacts /tmp/core-exact-artifacts \
  --commit 703507d8a93165446f644331e99e08f6c0a7b48b \
  --receipts /path/to/core-receipts.json /path/to/claims-receipts.json \
  --output /tmp/new-core-proof.json
```

The transaction hashes in the proof identify the original creation receipts. The receipt files
are discovery inputs only: transaction data, status and runtime are independently read from RPC.

## Release-process validation

Seven Python tests passed (clean pushed tag, dirty tracked/untracked source rejection,
unpushed/wrong-HEAD tags, overwrite rejection, guard coverage). All deployment scripts compile.
No production `src/` contract changed. Existing historical broadcast JSON is unchanged.
The new process requires review/merge before it becomes the main-branch release workflow.

Historical limitation: the deployment predates the corresponding source commit. This proof
does not retroactively make that deployment a clean tagged release.
