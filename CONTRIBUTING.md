# Contributing

Thanks for your interest in contributing to `multyr-core`. This file describes
how external contributions are handled.

## Branch Convention

| Branch pattern | Purpose |
|---|---|
| `main` | Latest tagged release |
| `pierdev` | Development integration branch (not stable) |
| `reorg/runbook-<id>` | Individual Run Book execution branches |
| `feat/<short-name>` | Feature branches — rebase onto `pierdev` before review |
| `fix/<short-name>` | Bug fix branches |

## Commit Style

Internal commits use the Run Book step format:

```
runbook-<id>: step <N> — <one-line action>
```

External contributors may use a simpler `<area>: <imperative summary>` style.
Examples:

```
core: fix fee accounting rounding in FeeMixin
docs: update access-control.md role matrix
test: add edge case for zero-asset deposit
```

## Pull Request Process

1. Open the PR against `pierdev` (never against `main` directly).
2. Ensure CI passes: `forge build`, `forge test`, `forge fmt --check`.
3. Update `CHANGELOG.md` under the relevant heading.
4. A Foundation reviewer will respond within 7 days.
5. Squash or rebase before merge if requested.

## Code Style

- Solidity 0.8.20
- `forge fmt` is the canonical formatter — run before pushing
- Storage namespaces follow EIP-7201; add a new namespace entry per new stateful contract
- All new public functions need at least one unit test
- All revert paths need a named custom error in the relevant interface file
- Comments in English only

## Testing

- Unit and integration tests: `forge test --no-match-path "test/fork*"`
- Fork tests require `ARBITRUM_ARCHIVE_RPC_URL` — see [`docs/testing.md`](docs/testing.md)
- Coverage goal: ≥ 90% line coverage on `src/`

## Scope Notes

This repo contains the core vault and warm adapters only. Periphery contracts
live in `multyr-periphery`. Public strategies live in `multyr-strategies`.
Do not add strategy-specific logic to `src/core/`.

## License

By contributing, you agree that your contribution is licensed under the same
Business Source License 1.1 terms as the rest of this repository, except for
interface files placed under `src/interfaces/` which are MIT licensed.
