# Phased v1 → v2 Migration

## Overview

The v1 → v2 migration runs as seven explicit phases, orchestrated by three pieces:

- **Operator CLI** — [`script/migration.ts`](../script/migration.ts), run as `bun run migration -- <command>` from `contracts/`. Each phase is an individual subcommand; `fork full` and `clean-testnet` run all phases end-to-end as rehearsals.
- **Hardhat plugin** — [`plugins/migration/index.ts`](../plugins/migration/index.ts), registering `migration <task>` tasks. These wrap the same phase functions but derive signers from the configured Hardhat network/keystore: `bunx hardhat --network <net> migration <task>`.
- **Phased deploy scripts** — the scripts under [`deploy/`](../deploy/) carry migration tags (`migration:phase1:deploy-v2`, `migration:phase5:switch-urp-to-managed`, `migration:phase6:upgrade-managed-urp`, `migration:post-cutover:direct-urp-to-v2`) so each on-chain change is bound to a deploy step. Phase 1 (`phase deploy-v2`) runs only the `migration:phase1:deploy-v2` tag by default; the `…switch-urp-to-managed` / `…upgrade-managed-urp` tags drive the resolution cutover in phase 7 (their tag strings predate this numbering and are kept as stable identifiers).

Phase numbering below matches the console output of the `runForkFull` orchestrator in [`script/migration.ts`](../script/migration.ts).

> **Ordering note.** Renewal compatibility is enabled early (phase 4) so unmigrated v1 names stay renewable throughout the migration window, and the final pre-migration sync (phase 5) then picks up any renewed expiries. The Universal Resolver is cut over to v2 last (phase 7) so public resolution flips only once everything else is live.

## Phases

| Phase | Action | CLI command(s) | Signer |
| --- | --- | --- | --- |
| 0 † | Deploy fresh v1 contracts (clean-testnet only) | part of `clean-testnet` | `deployer` |
| 1 | Deploy all v2 contracts (incl. reverse-registrar adapters), registrar deferred | `phase deploy-v2` | `deployer` / `owner` / `urManager` (+ one `v1Owner` tx, deferrable) |
| 2 | Initial pre-migration: seed v1 names as reserved on v2 | `premigration run` / `resume`, then `premigration verify` | BatchRegistrar owner |
| 3 | Disable v1 registrar controllers (v1 registration freeze) | `phase disable-v1-registrars`, then `phase verify-v1-registrars-disabled` | v1 owner |
| 4 | Authorize `ETHRenewerV1` as a v1 controller so unmigrated names stay renewable | `phase authorize-v1-renewer` | v1 owner |
| 5 | Final pre-migration sync from a fresh post-freeze export (picks up renewed expiries) | `premigration run`, then `premigration verify` | BatchRegistrar owner |
| 6 | Enable the v2 controller: revoke `REGISTRAR \| RENEW` from `BatchRegistrar` → authorize v1 handoff controllers (`Graveyard`, testnet helper) → transfer v1 `BaseRegistrar` ownership to `ETHRenewerV1` → grant `REGISTRAR \| RENEW` to `ETHRegistrar` | `phase disable-batch-registrar`, `phase activate-v1-handoff-controllers`, `phase activate-v1-renewer`, `phase enable-v2-registrar` (+ the matching `verify-*`) | registry root-role admin + v1 owner |
| 7 | Switch Universal Resolver to v2 (resolution cutover): intermediate URP → `UniversalResolverV2` (sepolia reuses the existing top URP → intermediate URP wiring; bootstrap networks first switch top URP → intermediate URP) | `phase upgrade-managed-urp`, then `phase verify-urp` (bootstrap also runs `phase switch-urp-to-managed` first) | `urManager` (intermediate URP admin); bootstrap also needs the top URP admin (DAO on mainnet) for the switch |

† Phase 0 only exists in `clean-testnet`, which deploys a fresh v1 stack (from `lib/ens-contracts/deploy`) into a `deployments/v1/<namespace>` directory before running phases 1–7.

Every phase command takes `--network sepolia|mainnet` plus `--rpc-url` (or the `SEPOLIA_RPC_URL` / `MAINNET_RPC_URL` env var). Contract addresses default to the deployment JSON under `--deployments-dir` / `--deployment-network` (v2) and `--v1-deployments-dir` / `--v1-deployment-network` (v1); explicit address flags override. The v1-owner-signed and URP-admin phase commands (`disable-v1-registrars`, `authorize-v1-renewer`, `activate-v1-graveyard`, `activate-v1-handoff-controllers`, `activate-v1-renewer`, `authorize-testnet-v1-premigration-registrar`, `switch-urp-to-managed`, `upgrade-managed-urp`) accept `--calldata-only` to print the transaction target and calldata for multisig execution instead of broadcasting. The registry root-role admin commands (`disable-batch-registrar`, `enable-v2-registrar`) broadcast or impersonate only.

### Phase 1: deploy v2 contracts

Runs all deploy scripts tagged `migration:phase1:deploy-v2` with the `deferV2Registrar` tag set, so [`deploy/03_ETHRegistrar.ts`](../deploy/03_ETHRegistrar.ts) deploys `ETHRegistrar` **without** granting it `REGISTRAR | RENEW` at the registry root — that grant is deferred to [phase 6](#phase-6-enable-the-v2-controller). `BatchRegistrar` holds the roles in the meantime for pre-migration seeding. The deploy also sets up the URP proxy chain pointing at the v1 `UniversalResolver` (see [universalResolver.md](./universalResolver.md)) and deploys the v2 reverse-registrar adapters ([`deploy/02_ReverseRegistrarAdapter.ts`](../deploy/02_ReverseRegistrarAdapter.ts) and [`deploy/02_DefaultReverseRegistrarAdapter.ts`](../deploy/02_DefaultReverseRegistrarAdapter.ts)), each authorized as a controller on the corresponding v1 reverse registrar via a v1-owner transaction.

Several steps require a v1-owner signature: pointing the v1 `.eth` resolver at `ENSV2Resolver` ([`deploy/00_ENSV2Resolver.ts`](../deploy/00_ENSV2Resolver.ts)) and the reverse-adapter controller grants above. With `--defer-v1-owner-transactions` (and `--deferred-v1-owner-transactions-file <path>`) such transactions are recorded to a JSONL file instead of broadcast; the owner executes them later with `phase execute-owner-txs --file <path> --role v1Owner`.

`--include-testnet-premigration-registrar` additionally deploys `TestnetV1PremigrationRegistrar` (see [premigration.md](./premigration.md)).

> The migration timeline also lists external deployments (e.g. an HCA component) that live outside this repository; they are out of scope for these contracts and are not driven by `phase deploy-v2`.

### Phase 2: initial pre-migration

Seeds every active or in-grace v1 `.eth` 2LD into the v2 registry as a **reserved** entry via `BatchRegistrar`, driven by a registration CSV — see [premigration.md](./premigration.md) for the CSV format, the bonus-period expiry rule, checkpointing, and verification. Each reservation's v2 expiry is the name's v1 expiry plus the configurable `--bonus-period-days` (default 62).

### Phase 3: disable v1 registrars

Removes `LegacyETHRegistrarController`, `ETHRegistrarController`, `WrappedETHRegistrarController`, and `NameWrapper` as v1 `BaseRegistrar` controllers (via `RegistrarSecurityController` when deployed, otherwise directly on `BaseRegistrar`). New v1 registrations are frozen from this point.

### Phase 4: authorize ETHRenewerV1

`phase authorize-v1-renewer` authorizes `ETHRenewerV1` as a v1 `BaseRegistrar` controller (via `RegistrarSecurityController` when deployed). `ETHRenewerV1` *only renews* names already reserved on v2, so this does **not** reopen the registration freeze from phase 3 — it keeps unmigrated names renewable throughout the migration window, with each renewal extending both the v1 registration and the v2 reservation in a single transaction. The final lock-down step that transfers v1 `BaseRegistrar` ownership to `ETHRenewerV1` is deferred to phase 6, after the handoff controllers are authorized.

Because `ETHRenewerV1` can only renew names that are already `RESERVED` on v2, this phase is effective only once the initial pre-migration (phase 2) has completed.

> **Mainnet renewal continuity.** Between phase 3 (freeze) and phase 4 (authorize) there is no renewal path, and the long final sync (phase 5) can run for days. To avoid a multi-day renewal outage when the v1 owner is a DAO/multisig, execute phases 3 and 4 **atomically in a single v1-owner batch** — both commands support `--calldata-only`, so their calldata can be combined into one Safe/multisend transaction. The lengthy pre-migration steps (phases 2 and 5) run via the checkpointed `premigration run` / `resume` commands, independent of these one-shot owner transactions.

### Phase 5: final pre-migration sync

After the freeze, export a fresh registration CSV (Dune for Sepolia, BigQuery for mainnet — see [premigration.md](./premigration.md#cli-reference)) and re-run pre-migration so names registered or renewed since phase 2 are caught up. Names already reserved on v2 are re-reserved with their bonus-adjusted expiry — picking up any expiry extensions from renewals performed via `ETHRenewerV1` since phase 4 — and newly eligible names are reserved for the first time.

### Phase 6: enable the v2 controller

The "enable the v2 controller" cutover bundles four owner-gated steps, in order:

1. **Disable the BatchRegistrar** (`phase disable-batch-registrar`) — revokes `REGISTRAR | RENEW` from `BatchRegistrar` on the v2 `ETHRegistry`, ending pre-migration seeding. On testnets, `TestnetV1PremigrationRegistrar` keeps its roles so test names can still be created. `phase batch-registrar-owner` prints (and optionally verifies) the BatchRegistrar owner beforehand.
2. **Authorize v1 handoff controllers** (`phase activate-v1-handoff-controllers`) — authorizes `Graveyard` as a v1 `BaseRegistrar` controller, and (re-)authorizes `TestnetV1PremigrationRegistrar` when that deployment exists. The individual steps are also available as `phase activate-v1-graveyard` and `phase authorize-testnet-v1-premigration-registrar`.
3. **Transfer v1 `BaseRegistrar` ownership to `ETHRenewerV1`** (`phase activate-v1-renewer`) — the final v1 lock-down (via `RegistrarSecurityController.transferRegistrarOwnership` when deployed). It re-authorizes `ETHRenewerV1` as a controller if needed, but the authorization usually already happened in phase 4. This must run **after** the handoff-controller grants above, because the v1 owner can no longer manage controllers once ownership has moved.
4. **Enable the v2 `ETHRegistrar`** (`phase enable-v2-registrar`) — grants `REGISTRAR | RENEW` on the v2 `ETHRegistry` to `ETHRegistrar`, the grant deferred since phase 1, opening live v2 registrations. `phase verify-v2-registrar` confirms the grant.

### Phase 7: switch the Universal Resolver to v2

The resolution cutover, run last so public resolution flips to v2 only once everything else is live. On sepolia the top `UpgradableUniversalResolverProxy` already fronts the long-lived intermediate `ManagedUniversalResolverProxy`, so the cutover is a single transaction: the intermediate URP admin (`urManager`) upgrades the intermediate URP implementation to `UniversalResolverV2` (`phase upgrade-managed-urp`, deploy tag `migration:phase6:upgrade-managed-urp`) — **this is the v2 resolution cutover.** The externally-administered top URP is never touched. On bootstrap networks (mainnet, fresh chains) the top URP admin (DAO on mainnet) first points the top URP at the freshly deployed intermediate URP (`phase switch-urp-to-managed`, deploy tag `migration:phase5:switch-urp-to-managed`; a no-op where the wiring already exists) before the upgrade, and the post-cutover step (tag `migration:post-cutover:direct-urp-to-v2`) can later retire the managed hop. `phase verify-urp` confirms both implementations. See [universalResolver.md](./universalResolver.md).

> **Relation to `prepareMigration.ts`:** phase 6 replaces the all-at-once role swap performed by [prepareMigration.md](./prepareMigration.md); that script remains the path for non-phased deployments.

## Deployment artifacts

Phase 1 reads and writes rocketh deployment artifacts under [`deployments/`](../deployments/README.md). Each deployment set is a **namespace** directory (e.g. the existing Sepolia v2 set `sepolia-official-v1-20260525-r2`) holding one JSON per contract plus `.chain`/`.migrations.json`/`.deployment.json` metadata; v1 reference contracts live under `deployments/v1/<network>`. A command selects the namespace with `--deployments-dir` (root, defaults to `deployments/`) and `--deployment-network` (subdirectory, defaults to the network name), and the v1 references with `--v1-deployments-dir` / `--v1-deployment-network`.

`phase deploy-v2` **deploys fresh by default**: it archives the current namespace to `deployments/<env>-<YYYYMMDD>-r<N>` — where the date is the archived set's original deploy time (from `.deployment.json`, falling back to the latest `.migrations.json` timestamp) and `<N>` auto-increments per same-date archive — then deploys into a clean `deployments/<env>/` and stamps a new `.deployment.json`. This applies to both sepolia and mainnet.

Phase 1 sends many transactions, so a deploy can be interrupted partway. Re-run with `--resume` to continue into the **existing** namespace instead of archiving: rocketh is idempotent against the namespace, so each script reuses an artifact of the same name and only the not-yet-deployed contracts are sent. See [`deployments/README.md`](../deployments/README.md) for the full layout, git-tracking model, and conventions.

## CLI reference

`bun run migration -- <command>` from `contracts/` (entrypoint [`script/migration.ts`](../script/migration.ts), wired through `package.json`). The CLI auto-loads `contracts/.env` (already-set environment variables win). Run `bun run migration -- <command> --help` for full options.

| Command | Purpose |
| --- | --- |
| `fetch-data` | Export ENS registrations from the TheGraph subgraph (mainnet or sepolia) into a pre-migration CSV |
| `premigration run` | Start pre-migration reservations from a fresh checkpoint (phases 2/4) |
| `premigration resume` | Resume pre-migration from the checkpoint |
| `premigration status` | Print the current pre-migration checkpoint JSON |
| `premigration verify` | Verify eligible CSV names were reserved or registered on v2 |
| `phase deploy-v2` | Phase 1: deploy the v2 migration contracts (incl. reverse-registrar adapters) with the registrar deferred; archives any existing namespace and deploys fresh by default (`--resume` continues an interrupted deploy instead) |
| `phase reclaim-v1-registrar-ownership` | Re-migration only: reclaim v1 `BaseRegistrar` ownership from a prior deployment's `ETHRenewerV1` back to the v1 owner (run before the Phase 1 deferred-tx replay on an already-migrated chain); signed by the prior renewer's owner / urManager |
| `phase disable-v1-registrars` | Phase 3: disable v1 registrar controllers |
| `phase verify-v1-registrars-disabled` | Verify v1 registrar controllers are disabled |
| `phase authorize-v1-renewer` | Phase 4: authorize `ETHRenewerV1` as a v1 controller so unmigrated names stay renewable |
| `phase execute-owner-txs` | Execute prepared owner transactions from a JSONL file (optionally filtered by `--role`) |
| `phase disable-batch-registrar` | Phase 6: revoke registrar/renew roles from `BatchRegistrar` |
| `phase verify-batch-registrar-disabled` | Verify `BatchRegistrar` no longer has registrar/renew roles |
| `phase batch-registrar-owner` | Print and optionally verify the `BatchRegistrar` owner |
| `phase activate-v1-handoff-controllers` | Phase 6: authorize `Graveyard` + testnet helper as v1 controllers |
| `phase activate-v1-graveyard` | Phase 6 (individual): authorize `Graveyard` only |
| `phase authorize-testnet-v1-premigration-registrar` | Phase 6 (individual, testnet): authorize the testnet premigration helper |
| `phase activate-v1-renewer` | Phase 6: transfer v1 `BaseRegistrar` ownership to `ETHRenewerV1` (final lock-down) |
| `phase enable-v2-registrar` | Phase 6: grant registrar/renew roles to `ETHRegistrar` |
| `phase verify-v2-registrar` | Verify `ETHRegistrar` has registrar/renew roles |
| `phase switch-urp-to-managed` | Phase 7: point the top URP at the managed URP |
| `phase upgrade-managed-urp` | Phase 7: upgrade the managed URP to `UniversalResolverV2` (resolution cutover) |
| `phase verify-urp` | Verify top and managed URP implementations |
| `fork full` | Run the full phased migration rehearsal against an Anvil fork |
| `clean-testnet` | Deploy fresh testnet v1 contracts and run the full phased migration (sepolia only) |

## Hardhat plugin tasks

Registered by [`plugins/migration/index.ts`](../plugins/migration/index.ts); invoke as:

```bash
bunx hardhat --network <net> migration <task> [--options]
```

The tasks select the migration network with `--migration-network sepolia|mainnet` and use the Hardhat network's RPC and configured signer (so private keys can come from the Hardhat keystore instead of flags/env). See `bunx hardhat migration <task> --help` for options.

| Task | Purpose |
| --- | --- |
| `snapshot` | Create an RPC state snapshot (`evm_snapshot`), optionally writing the id to `--file` |
| `revert` | Revert to a snapshot id (from `--snapshot-id` or `--file`) |
| `verify-all` | Verify final migration wiring plus resolution smoke checks against `--names` |
| `batch-registrar-owner` | Print and optionally verify the `BatchRegistrar` owner |
| `fork-full` | Run the full phased migration rehearsal (Hardhat-signer variant of `fork full`) |
| `clean-testnet` | Deploy fresh testnet v1 and run the full phased migration |
| `smoke-v2-registrar` | Register a fresh `.eth` name through the enabled v2 registrar |
| `set-v1-reverse-default-resolver` | Point the v1 `ReverseRegistrar` default resolver at the v1 `PublicResolver` |
| `deploy-v2` | Deploy the v2 migration contracts (phase 1) |
| `premigration-run` | Run pre-migration reservations (phases 2/5) with the Hardhat signer as BatchRegistrar owner |

## Environment variables

Resolved by [`script/migration.ts`](../script/migration.ts) (the CLI also auto-loads `contracts/.env`):

| Variable | Used for |
| --- | --- |
| `SEPOLIA_RPC_URL` / `MAINNET_RPC_URL` | Default RPC when `--rpc-url` is omitted |
| `DEPLOYER_KEY` | Deployer key (`phase deploy-v2`); fallback for owner/urManager keys |
| `OWNER_KEY` | Owner / registry root-role admin (`phase deploy-v2`, `disable-batch-registrar`, `enable-v2-registrar`; falls back to `DEPLOYER_KEY`) |
| `UR_MANAGER_KEY` | Intermediate URP admin (`phase upgrade-managed-urp`; falls back to `DEPLOYER_KEY`) |
| `SEPOLIA_V1_OWNER_KEY` / `V1_OWNER_KEY` | v1 owner (`disable-v1-registrars` †, `authorize-v1-renewer`, `activate-v1-*`, `authorize-testnet-v1-premigration-registrar`) |
| `SEPOLIA_TOP_URP_OWNER_KEY` / `TOP_URP_OWNER_KEY` | Top URP admin (`phase switch-urp-to-managed`) |
| `OWNER_TX_KEY` | Generic signer for `phase execute-owner-txs` when no role-specific key matches |
| `<PREFIX>_MNEMONIC`, `<PREFIX>_MNEMONIC_PATH`, `<PREFIX>_MNEMONIC_INDEX`, `<PREFIX>_MNEMONIC_PASSPHRASE` | Mnemonic-backed signer alternatives for `phase execute-owner-txs`; prefixes `OWNER_TX`, `SEPOLIA_V1_OWNER` / `V1_OWNER`, `SEPOLIA_TOP_URP_OWNER` / `TOP_URP_OWNER` |
| `PREMIGRATION_PRIVATE_KEY`, `BATCH_REGISTRAR_OWNER_KEY`, `DEPLOYER_KEY` | BatchRegistrar owner key fallbacks for `premigration run` / `resume` |
| `THEGRAPH_API_KEY` / `GRAPH_API_KEY` | TheGraph Gateway key for `fetch-data` |

† `phase disable-v1-registrars` takes the key via `--private-key`; the env fallbacks apply when it is executed through `phase execute-owner-txs` with `--role v1Owner`.

For `phase execute-owner-txs`, the key is selected by the `--role` filter: `v1Owner` → the v1-owner variables, `sepolia-top-urp-owner` → the top-URP-owner variables, `deployer` → `DEPLOYER_KEY`; with no role, `OWNER_TX_KEY` and then the role-specific variables are tried in order.

## Live deployment (Sepolia)

End-to-end runbook for a real, fresh Sepolia deployment that replaces the live v2 set and re-runs every phase. Rehearse first (see [Rehearsals](#rehearsals)) — `fork full` exercises this exact sequence against forked state.

### Signer keys

Three keys cover every signature in the sepolia reuse flow. The deployer fills the `owner`/registry-root-admin role, the v1 owner is a separate account, and the intermediate URP admin is the wallet that controls the long-lived intermediate URP. The top URP owner key is **not** needed here — the top URP already fronts the intermediate URP, so the cutover never touches it:

- **`DEPLOYER_KEY`** — the deployer EOA that signs phase-1 contract deployments. On Sepolia it also resolves as `owner` (registry root-role admin: `disable-batch-registrar`, `enable-v2-registrar`). It is also the `BatchRegistrar` owner that drives pre-migration. Must be a freshly funded account with enough Sepolia ETH for the many transactions in phase 1.
- **`SEPOLIA_V1_OWNER_KEY`** — the v1 owner (`0x0f32b753afc8abad9ca6fe589f707755f4df2353`), which controls the v1 `BaseRegistrar` / `RegistrarSecurityController`. Signs the deferred phase-1 v1-owner transactions (pointing the v1 `.eth` resolver at the new `ENSV2Resolver` and authorizing the reverse-registrar adapters), plus `disable-v1-registrars` (phase 3), `authorize-v1-renewer` (phase 4), and `activate-v1-handoff-controllers` / `activate-v1-renewer` (phase 6).
- **`UR_MANAGER_KEY`** — the admin of the long-lived intermediate `ManagedUniversalResolverProxy` (`0x6d80F2172CFdEc5730fE683860C33d26fC42e6F1`, admin `0xffFffFFfFF52D316B7Bd028358089bc8066b8f80`). Signs `upgrade-managed-urp` (phase 7), the v2 resolution cutover. Configured as `securityCouncil`/`urManager` for sepolia in the account config.

> **`SEPOLIA_TOP_URP_OWNER_KEY`** is only needed on bootstrap networks (mainnet, fresh chains) where the top URP does not yet front an intermediate URP and the top URP admin (`0x69420f05A11f617B4B74fFe2E04B2D300dFA556F` on sepolia, the DAO on mainnet) must first run `switch-urp-to-managed`. On sepolia that switch is a no-op.

> **`phase deploy-v2` cannot sign v1-owner transactions itself** — it only wires the deployer/owner keys. So phase 1 must record its v1-owner transactions with `--defer-v1-owner-transactions` and you replay them with `phase execute-owner-txs --role v1Owner`, which reads `SEPOLIA_V1_OWNER_KEY`. Every later v1-owner / top-URP command reads its key from env directly, except `disable-v1-registrars`, which takes `--private-key` explicitly.

### Setup

```bash
cd contracts
bun run compile                     # forge + hardhat → generated/artifacts

export SEPOLIA_RPC_URL=<reliable paid sepolia RPC>     # phase 1 sends many txs
export DEPLOYER_KEY=0x<fresh funded EOA>               # also owner / urManager / securityCouncil / BatchRegistrar owner
export SEPOLIA_V1_OWNER_KEY=0x<key for 0x0f32…2353>
export SEPOLIA_TOP_URP_OWNER_KEY=0x<key for 0x6942…556F>

mkdir -p .dev/sepolia-live
```

Also prepare a **current** Sepolia registration CSV for the pre-migration phases (Dune export — see [premigration.md](./premigration.md)). The repo's `csv-data/ens-registrations-sepolia.csv` is a small sample, not a real export.

### Phase 1 — deploy fresh v2

```bash
# deployer-signed deploy into deployments/sepolia/; v1-owner txs recorded, not broadcast
bun run migration -- phase deploy-v2 --network sepolia \
  --defer-v1-owner-transactions \
  --deferred-v1-owner-transactions-file .dev/sepolia-live/phase1-v1owner.jsonl

# Re-deploying onto an ALREADY-MIGRATED chain only: the v1 BaseRegistrar is still
# owned by the prior deployment's ETHRenewerV1, so reclaim it to the v1 owner before
# replaying the deferred txs — one of them is a v1 BaseRegistrar setResolver, which is
# owner-gated. Signed by the prior renewer's owner (urManager). No-op on a pristine chain.
bun run migration -- phase reclaim-v1-registrar-ownership --network sepolia \
  --private-key $UR_MANAGER_KEY

# v1 owner replays the deferred setResolver + reverse-adapter grants
bun run migration -- phase execute-owner-txs --network sepolia \
  --role v1Owner --file .dev/sepolia-live/phase1-v1owner.jsonl
```

`phase deploy-v2` archives any existing `sepolia` namespace (to `sepolia-<YYYYMMDD>-r<N>`) and deploys fresh into the default `sepolia` namespace; every later phase auto-resolves addresses from `deployments/sepolia/`. If phase 1 is interrupted, re-run the same command with `--resume` to continue.

> **Deployer and `.env` hygiene.** `DEPLOYER_KEY` should be a freshly funded EOA. If it
> happens to be the same address as the v1 owner, `phase deploy-v2` now wires that address
> with the v1-owner key (from `SEPOLIA_V1_OWNER_KEY`/`V1_OWNER_KEY`, falling back to
> `DEPLOYER_KEY`) so it keeps a local signer; previously a keyless same-address v1 owner
> would shadow the deployer's signer and every deploy tx would fail node-side signing.
> Keep `.env` values free of inline `#` comments — the loader trims a whitespace-introduced
> inline comment, but quote the value if it must contain a literal `#`.

### Phases 2–7 — wire up and cut over

```bash
# Phase 2 — initial pre-migration (BatchRegistrar owner = deployer). See premigration.md.
bun run migration -- premigration run --network sepolia \
  --csv-file <fresh-sepolia.csv> --work-dir .dev/sepolia-live/premig-1
bun run migration -- premigration verify --network sepolia --csv-file <fresh-sepolia.csv>

# Phase 3 — freeze v1 registrations (v1 owner; this command needs --private-key)
bun run migration -- phase disable-v1-registrars --network sepolia \
  --private-key $SEPOLIA_V1_OWNER_KEY
bun run migration -- phase verify-v1-registrars-disabled --network sepolia

# Phase 4 — keep unmigrated names renewable (v1 owner via env)
bun run migration -- phase authorize-v1-renewer --network sepolia

# Phase 5 — final sync from a fresh post-freeze CSV export
bun run migration -- premigration run --network sepolia \
  --csv-file <fresh-sepolia-post-freeze.csv> --work-dir .dev/sepolia-live/premig-2
bun run migration -- premigration verify --network sepolia --csv-file <fresh-sepolia-post-freeze.csv>

# Phase 6 — enable v2 controller (registry root admin = deployer/owner; + v1 owner)
bun run migration -- phase disable-batch-registrar --network sepolia
bun run migration -- phase activate-v1-handoff-controllers --network sepolia
bun run migration -- phase activate-v1-renewer --network sepolia
bun run migration -- phase enable-v2-registrar --network sepolia
bun run migration -- phase verify-v2-registrar --network sepolia

# Phase 7 — resolution cutover (intermediate URP admin = UR_MANAGER_KEY).
# The top URP already fronts the intermediate URP, so only the upgrade is needed.
bun run migration -- phase upgrade-managed-urp --network sepolia
bun run migration -- phase verify-urp --network sepolia
```

### After

The new `deployments/sepolia/` namespace is git-ignored by default; to commit it add a `!deployments/sepolia/` line to `contracts/.gitignore` (see [deployments/README.md](../deployments/README.md)).

Two things to plan for:

- **Renewal gap (phases 3→5).** Between the freeze and the end of the long final sync renewals are paused until `authorize-v1-renewer` (phase 4) reopens them. With an EOA v1 owner on Sepolia you can run phases 3 and 4 back-to-back, so the window is small. (The atomic-batch guidance under [phase 4](#phase-4-authorize-ethrenewerv1) is a mainnet/multisig concern.)
- **Pre-migration is the heavy, stateful part.** Phases 2 and 5 are checkpointed (`premigration resume`) and have their own flags (`--registry`, `--batch-registrar`, `--batch-size`, the v1-expiry RPC). Read [premigration.md](./premigration.md) and confirm the CSV export before the live run.

> **Mainnet differs.** There the owner, top URP admin, and v1 owner are all the DAO/multisig, so the owner-signed and URP-admin phases are run with `--calldata-only` (or deferred) and executed through the Safe rather than with local keys.

## Rehearsals

### `fork full`

```bash
bun run migration -- fork full --network sepolia --csv-file ./csv-data/ens-registrations-sepolia.csv \
  [--work-dir <dir>] [--save-deployments] [--snapshot-file <path>]
```

Spawns a local Anvil fork of the network RPC (default port 8547 sepolia / 8548 mainnet), impersonates the deployer, owner, v1 owner, URP admins, and BatchRegistrar owner, and runs phases 1–7 in order with smoke checks interleaved:

- v1 registration succeeds before phase 3 and is rejected after;
- `ETHRenewerV1` is confirmed as an authorized v1 renewal controller after phase 4;
- a pre-migrated name is migrated to v2 via `UnlockedMigrationController` after phase 5;
- the v2 registrar rejects registrations before phase 6's grant, rejects pre-migrated reserved names after it, and accepts a fresh name after enablement.

When the target chain has already completed the v1 hand-off — re-running against an already-migrated Sepolia, or a repeat mainnet run after a redeploy — `fork full` detects this from the v1 registrar-controller state and skips the smoke checks that require live v1 registration (the v1-registration bullet and the pre-migrated-reserved-name rejection in the last bullet), while still running the deploy, pre-migration, renewer authorization, the pre-enablement rejection, the fresh-name registration, and the URP cut-over. A pristine chain runs all of them. There is no flag for this; it is detected automatically.

`--direct` skips Anvil and targets `--rpc-url` directly (e.g. a Tenderly virtual testnet) — it requires explicit `--deployer` and `--ur-manager` addresses, plus `--owner` on sepolia (the Hardhat `migration fork-full` task derives them from the keystore). `--resume-from-phase 2` (requires `--work-dir`) skips phase 1 and reloads saved deployments. `--snapshot-file` records a pre-rehearsal `evm_snapshot` id, which the Hardhat `migration revert` task can restore.

### `clean-testnet`

```bash
bun run migration -- clean-testnet --network sepolia --rpc-url <url> --deployer <address>
```

Sepolia only. Runs phase 0 — a fresh v1 stack deployed into `deployments/v1/<namespace>` — then phases 1–7 directly against the RPC, always including `TestnetV1PremigrationRegistrar`. The v2 namespace defaults to `sepolia-clean-<timestamp>`; the command refuses to reuse the canonical `sepolia` namespace or any namespace that already contains deployment files. Without `--csv-file`, only the generated smoke labels are seeded. Against an RPC without state controls (anything other than a local node or a Tenderly virtual testnet), a configured deployer key is required — prefer the Hardhat `migration clean-testnet` task, which signs with the configured Hardhat account.

## Related docs

- [deployments/README.md](../deployments/README.md) — deployment artifact layout, namespace naming, and the idempotency rule for fresh re-deploys.
- [premigration.md](./premigration.md) — the `BatchRegistrar` seeding step in detail (phases 2 and 5): CSV format, continuity expiry, checkpoints, verification.
- [universalResolver.md](./universalResolver.md) — the URP proxy chain behind phase 7, and the post-cutover step.
- [prepareMigration.md](./prepareMigration.md) — the non-phased, all-at-once role hand-off script that phase 6 supersedes.
