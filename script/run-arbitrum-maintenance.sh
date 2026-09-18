#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
mode="${1:-simulate}"
if [[ $# -gt 0 ]]; then shift; fi
case "$mode" in
 simulate) ;;
 broadcast) set -- --broadcast --slow "$@" ;;
 *) echo 'Usage: script/run-arbitrum-maintenance.sh [simulate|broadcast] [Foundry wallet options]' >&2; exit 2 ;;
esac
# Forge loads this repository's .env itself. Never source or print its secrets.
# Public RPC default; override ARBITRUM_RPC_URL in your shell if needed.
forge script script/RunArbitrumMaintenance.s.sol:RunArbitrumMaintenance \
 --evm-version cancun --rpc-url "${ARBITRUM_RPC_URL:-https://arb1.arbitrum.io/rpc}" \
 --sender 0x908756f36954f2853134259B8846c49F90E84ECe \
 "$@"
