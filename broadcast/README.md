# Historical deployment snapshots

JSON in this directory is deployment-time evidence, not a live ownership/configuration API.
In particular, `core-addresses.json` records pending handover at deployment and must not be
interpreted as current ownership. See `../deployments/evidence-20261029/` for the superseding
block-pinned ownership and bytecode report, and `../docs/release-process.md` for the release flow.

Never overwrite these records or hand-edit their fields. Append a dated generated snapshot.
