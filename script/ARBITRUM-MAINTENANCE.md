# Arbitrum maintenance transaction runner

Run from multyr-core. This operates on the exact deployed VaultUpkeep, StrategyUpkeep and USDC strategy addresses from the supplied deployment list. It does not require CRE access or a CRE receiver: it calls the existing upkeeps directly.

```sh
script/run-arbitrum-maintenance.sh simulate
script/run-arbitrum-maintenance.sh broadcast
python3 script/maintenance-receipts.py
```

Forge consumes the repository .env without printing credentials. DEPLOYER_ADDRESS defaults to the previously authorized 0x908756f36954f2853134259B8846c49F90E84ECe and must match it. If DEPLOYER_PRIVATE_KEY is configured, Forge consumes it internally and requires its derived account to match. Otherwise pass --account NAME or --keystore PATH (and optionally --password-file PATH) to the wrapper. Do not put secret values on command lines or in chat. No script reads a password file itself.

The default public RPC is https://arb1.arbitrum.io/rpc; override ARBITRUM_RPC_URL in your shell if needed. MAINTENANCE_MAX_STEPS defaults to 4 and is bounded to 1..8.

Simulation does not submit transactions. Broadcast sends real transactions and spends Arbitrum ETH. Forge performs its preflight before broadcasting and --slow waits for confirmations. Do not use --skip-simulation or --resume blindly after failure: some earlier transactions may already be mined; read the broadcast receipts and current state first.

Sequence: snapshot strategy positions, run one due core action, then up to four contract-selected strategy actions, snapshot again. Core can select crystallization rather than deployment; strategy usually refreshes observations before deploying idle funds. Repeated non-step actions stop the loop. A repeated rebalance-step opcode is allowed because a plan may need several steps.

The snapshot events distinguish recorded positionAssets from each adapter's reported totalAssets. Script snapshots are simulation diagnostics; confirm live values after broadcasting. Forge stores transaction receipts under broadcast/RunArbitrumMaintenance.s.sol/42161/. Script-only diagnostic events are not emitted by the mainnet target contracts.

This runner never forces weights, changes governance, grants roles, deposits wallet USDC or refreshes liquidity with unauthorized calls. It follows the existing allocation engine; it cannot guarantee deposits into Morpho, Aave, Comet, Fluid and Dolomite. Liquidity cache refresh requires a separate KEEPER_ROLE-authorized caller if needed. All seven enabled adapters remain eligible under existing policy, including Euler and Venus.

Upkeeps can catch downstream failures, so a status-1 receipt is not sufficient. Check UpkeepPerformed success (core), UpkeepErrored/SnapshotPokeFailed/ExternalTVLPokeFailed (strategy), actual token transfers, and live position changes before reporting success.
