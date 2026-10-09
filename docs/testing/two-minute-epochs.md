# Two-minute withdrawal queue testing

The deployment script supports `ENABLE_TWO_MINUTE_TEST_EPOCHS=true`.
This explicitly selects a per-vault queue duration of 120 seconds, zero claim
cooldown, and zero deposit lock. It preserves the withdrawal caps, fees, deposit
minimum, and other settings. Without the flag the queue remains seven days.
GlobalConfig accepts durations from 120 seconds through 30 days; governance
alone can change the setting. Defaults for other vaults are unaffected.

This profile changes the withdrawal queue cadence, not the independent
instant-withdrawal cap epoch or governance timelocks. It does not register or
fund Automation, unpause the vault, or activate the strategy. Keepers still
need transactions to close, fund, and settle; 120 seconds is eligibility,
not a guarantee of payout within 120 seconds. Funding requires liquidity.

The September 25 Arbitrum GlobalConfig enforces a one-hour minimum in its
deployed bytecode. A source edit cannot change that contract. Applying this
profile there requires migrating its full configuration into a replacement,
updating every applicable consumer, and checking the resulting on-chain state.
No live migration is part of the local test result below.

Run:

```sh
forge test --match-path 'test/unit/core/{GlobalConfigQueue,EpochedQueueModule,FeeCollectorHarvestQueue}.t.sol' -vv
```

The two-minute lifecycle regression checks rejection at 119 seconds, closure
at 120 seconds, opening the next epoch, funding, permissionless keeper payout,
user self-claim, fixed recovery index, cleared liabilities/reserves, and another
closure at 240 seconds. It uses local harnesses and mocked assets, not actual
Arbitrum transactions or external adapter evidence.
