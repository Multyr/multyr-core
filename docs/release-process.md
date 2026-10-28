# Core release provenance

Production deployments must use `script/release/release.py`. All `Deploy*.s.sol` and
`Redeploy*.s.sol` entry points invoke a preflight before broadcasting on public chains.
Local chain 31337 is exempt for unit tests. Mainnet forks use their real chain ID and
therefore require the same preflight.

## Required release sequence

1. Review and merge source changes. Commit all source and initialized submodule revisions.
2. Push both Core and Strategy commits and their release tags to `origin`. Never move a deployed tag.
3. Use clean checkouts at those exact tags. Untracked source, modified files, mismatched
   submodules, missing tags and local-only tags are rejected.
4. Provide the reviewed existing Core/Strategy address inventory as JSON and run a simulation:

   ```sh
   python3 script/release/release.py --core-tag CORE_TAG --strategy-tag STRATEGY_TAG \
     --strategy-repo ../multyr-strategies --addresses /path/to/reviewed-addresses.json
   ```

   Supply RPC_URL and signing configuration through the local environment. Never commit secrets.
5. Review the simulation. Its generated records make the working trees dirty: commit and push
   the evidence, or use fresh clean checkouts of the same source tags for the broadcast.
   Use the same command with `--broadcast` only after deployment authorization.
6. Inspect every receipt, constructor binding and runtime comparison. Receipt capture alone
   does not mean governance handover, configuration, verification or acceptance is complete.
7. Commit the identical generated release package in both repositories. The package records
   both source commits/tags, `dirty: false`, supplied address inventory, newly created addresses,
   receipt copies and SHA-256 integrity hashes. Audit scope must cite an exact source commit.

Each invocation creates a unique timestamp/UUID directory. Outputs use exclusive creation;
existing deployment records are never updated. Foundry's mutable run-latest file is isolated
inside that attempt, then copied to an immutable receipt filename. CI rejects changes or deletion
of existing JSON under `broadcast/` and `deployments/`. Treat evidence packages as generated,
not hand-editable. Corrections use a new snapshot referencing the superseded record.

If a broadcast partially succeeds, stop and reconcile transaction receipts. This wrapper does
not auto-resume or retry deployment transactions. Do not start a new attempt blindly.

## Ownership records

Deployment-time ownership is historical. `broadcast/core-addresses.json` is the legacy
8 October snapshot and **must not be used as current ownership evidence**. Its pending-handover
fields were not refreshed following acceptance. See `deployments/evidence-20261029/` for a
fresh block-pinned read of the four ownership contracts. Preserve the old file for provenance.
Append a fresh chain snapshot after each governance change and reference its block/hash.

## Bytecode proof

`script/release/verify_chain.py` uses read-only RPC methods. Build the exact source revision
in a clean directory with its pinned dependencies/compiler/settings. Pass its `out/` directory,
source commit, original broadcast receipts and a new output filename. The verifier checks the
compiled creation prefix against the actual creation transaction, reads the successful CREATE
trace, and compares its entire runtime to current code at a single pinned block. It additionally
compares the compiled runtime after inserting immutable values from that trace. It does not mask
or ignore differing bytes. Constructor ABI/encoded arguments and every immutable value are
recorded for review. This proves code identity at the recorded block, not correctness of every
mutable setting, absence of vulnerabilities, or a clean working tree at the historical deploy.

The legacy deployment predates its corresponding commit. Retrospective bytecode equality does
not retroactively establish clean/tagged deployment provenance. Keep that limitation explicit.
