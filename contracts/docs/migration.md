# Phased v1 → v2 Migration

## Overview

The v1 → v2 migration runs as nine explicit phases, orchestrated by three pieces:

- **Operator CLI** — [`script/migration.ts`](../script/migration.ts), run as `bun run migration -- <command>` from `contracts/`. Each phase is an individual subcommand; `fork full` and `clean-testnet` run all phases end-to-end as rehearsals.
- **Hardhat plugin** — [`plugins/migration/index.ts`](../plugins/migration/index.ts), registering `migration <task>` tasks. These wrap the same phase functions but derive signers from the configured Hardhat network/keystore: `bunx hardhat --network <net> migration <task>`.
- **Phased deploy scripts** — the scripts under [`deploy/`](../deploy/) carry migration tags (`migration:phase1:deploy-v2`, `migration:phase5:switch-urp-to-managed`, `migration:phase6:upgrade-managed-urp`, `migration:post-cutover:direct-urp-to-v2`) so each on-chain change is bound to its phase. Phase 1 (`phase deploy-v2`) runs only the `migration:phase1:deploy-v2` tag by default.

Phase numbering below matches the console output of the `runForkFull` orchestrator in [`script/migration.ts`](../script/migration.ts).

## Phases

| Phase | Action | CLI command(s) | Signer |
| --- | --- | --- | --- |
| 0 † | Deploy fresh v1 contracts (clean-testnet only) | part of `clean-testnet` | `deployer` |
| 1 | Deploy all v2 contracts, registrar deferred | `phase deploy-v2` | `deployer` / `owner` / `urManager` (+ one `v1Owner` tx, deferrable) |
| 2 | Initial pre-migration: seed v1 names as reserved on v2 | `premigration run` / `resume`, then `premigration verify` | BatchRegistrar owner |
| 3 | Disable v1 registrar controllers (v1 registration freeze) | `phase disable-v1-registrars`, then `phase verify-v1-registrars-disabled` | v1 owner |
| 4 | Final pre-migration sync from a fresh post-freeze export | `premigration run --min-expiry-days 0 --skip-existing-reservations`, then `premigration verify` | BatchRegistrar owner |
| 5 | Switch top URP → managed URP | `phase switch-urp-to-managed`, then `phase verify-urp` | top URP admin (DAO on mainnet, top URP owner on sepolia) |
| 6 | Upgrade managed URP → `UniversalResolverV2` (resolution cutover) | `phase upgrade-managed-urp`, then `phase verify-urp` | `urManager` (security council) |
| 7 | Revoke `REGISTRAR \| RENEW` from `BatchRegistrar` | `phase disable-batch-registrar`, then `phase verify-batch-registrar-disabled` | registry root-role admin |
| 8 | Authorize v1 handoff controllers (`Graveyard`, testnet helper) | `phase activate-v1-handoff-controllers` | v1 owner |
| 9 | Activate `ETHRenewerV1` on v1, then grant `REGISTRAR \| RENEW` to `ETHRegistrar` | `phase activate-v1-renewer`, then `phase enable-v2-registrar` and `phase verify-v2-registrar` | v1 owner, then registry root-role admin |

† Phase 0 only exists in `clean-testnet`, which deploys a fresh v1 stack (from `lib/ens-contracts/deploy`) into a `deployments/v1/<namespace>` directory before running phases 1–9.

Every phase command takes `--network sepolia|mainnet` plus `--rpc-url` (or the `SEPOLIA_RPC_URL` / `MAINNET_RPC_URL` env var). Contract addresses default to the deployment JSON under `--deployments-dir` / `--deployment-network` (v2) and `--v1-deployments-dir` / `--v1-deployment-network` (v1); explicit address flags override. Owner-signed phase commands accept `--calldata-only` to print the transaction target and calldata for multisig execution instead of broadcasting.

### Phase 1: deploy v2 contracts

Runs all deploy scripts tagged `migration:phase1:deploy-v2` with the `deferV2Registrar` tag set, so [`deploy/03_ETHRegistrar.ts`](../deploy/03_ETHRegistrar.ts) deploys `ETHRegistrar` **without** granting it `REGISTRAR | RENEW` at the registry root — that grant is deferred to [phase 9](#phase-9-activate-ethrenewerv1-and-enable-the-v2-ethregistrar). `BatchRegistrar` holds the roles in the meantime for pre-migration seeding. The deploy also sets up the URP proxy chain pointing at the v1 `UniversalResolver` (see [universalResolver.md](./universalResolver.md)).

One step requires a v1-owner signature: pointing the v1 `.eth` resolver at `ENSV2Resolver` ([`deploy/00_ENSV2Resolver.ts`](../deploy/00_ENSV2Resolver.ts)). With `--defer-v1-owner-transactions` (and `--deferred-v1-owner-transactions-file <path>`) such transactions are recorded to a JSONL file instead of broadcast; the owner executes them later with `phase execute-owner-txs --file <path> --role v1Owner`.

`--include-testnet-premigration-registrar` additionally deploys `TestnetV1PremigrationRegistrar` (see [premigration.md](./premigration.md)).

### Phase 2: initial pre-migration

Seeds every active or in-grace v1 `.eth` 2LD into the v2 registry as a **reserved** entry via `BatchRegistrar`, driven by a registration CSV — see [premigration.md](./premigration.md) for the CSV format, continuity-expiry rules, checkpointing, and verification. The rehearsal orchestrator runs this pass with `--min-expiry-days 7`, leaving names about to expire for the final sync.

### Phase 3: disable v1 registrars

Removes `LegacyETHRegistrarController`, `ETHRegistrarController`, `WrappedETHRegistrarController`, and `NameWrapper` as v1 `BaseRegistrar` controllers (via `RegistrarSecurityController` when deployed, otherwise directly on `BaseRegistrar`). New v1 registrations and renewals are frozen from this point.

### Phase 4: final pre-migration sync

After the freeze, export a fresh registration CSV (Dune for Sepolia, BigQuery for mainnet — see [premigration.md](./premigration.md#cli-reference)) and re-run pre-migration with `--min-expiry-days 0 --skip-existing-reservations` so names registered, renewed, or newly past the expiry buffer since phase 2 are caught up. Reservations whose continuity expiry already matches are skipped; differing expiries are renewed.

### Phase 5: switch top URP to managed URP

The top `UpgradableUniversalResolverProxy` admin (DAO on mainnet, top URP owner on sepolia) points the top URP at `ManagedUniversalResolverProxy`. Resolution behavior is unchanged — both still resolve via v1. Deploy-script equivalent: tag `migration:phase5:switch-urp-to-managed`. See [universalResolver.md](./universalResolver.md).

### Phase 6: upgrade managed URP to UniversalResolverV2

The managed URP admin (`urManager` / security council) upgrades the managed URP implementation to `UniversalResolverV2`. **This is the v2 resolution cutover.** Deploy-script equivalent: tag `migration:phase6:upgrade-managed-urp`. After the migration stabilizes, the post-cutover step (tag `migration:post-cutover:direct-urp-to-v2`) retires the managed hop.

### Phase 7: disable the BatchRegistrar

Revokes the `REGISTRAR | RENEW` root roles from `BatchRegistrar` on the v2 `ETHRegistry`, ending pre-migration seeding. On testnets, `TestnetV1PremigrationRegistrar` keeps its roles so test names can still be created. `phase batch-registrar-owner` prints (and optionally verifies) the BatchRegistrar owner beforehand.

### Phase 8: authorize v1 handoff controllers

Authorizes `Graveyard` as a v1 `BaseRegistrar` controller, and (re-)authorizes `TestnetV1PremigrationRegistrar` when that deployment exists. The individual steps are also available as `phase activate-v1-graveyard` and `phase authorize-testnet-v1-premigration-registrar`.

### Phase 9: activate ETHRenewerV1 and enable the v2 ETHRegistrar

`phase activate-v1-renewer` authorizes `ETHRenewerV1` as a v1 `BaseRegistrar` controller and transfers v1 `BaseRegistrar` ownership to it (via `RegistrarSecurityController.transferRegistrarOwnership` when deployed). `phase enable-v2-registrar` then grants `REGISTRAR | RENEW` on the v2 `ETHRegistry` to `ETHRegistrar` — the grant deferred since phase 1 — opening live v2 registrations.

> **Relation to `prepareMigration.ts`:** phases 7 and 9 replace the all-at-once role swap performed by [prepareMigration.md](./prepareMigration.md); that script remains the path for non-phased deployments.

## CLI reference

`bun run migration -- <command>` from `contracts/` (entrypoint [`script/migration.ts`](../script/migration.ts), wired through `package.json`). The CLI auto-loads `contracts/.env` (already-set environment variables win). Run `bun run migration -- <command> --help` for full options.

| Command | Purpose |
| --- | --- |
| `fetch-data` | Export ENS registrations from the TheGraph subgraph (mainnet or sepolia) into a pre-migration CSV |
| `premigration run` | Start pre-migration reservations from a fresh checkpoint (phases 2/4) |
| `premigration resume` | Resume pre-migration from the checkpoint |
| `premigration status` | Print the current pre-migration checkpoint JSON |
| `premigration verify` | Verify eligible CSV names were reserved or registered on v2 |
| `phase deploy-v2` | Phase 1: deploy the v2 migration contracts with the registrar deferred |
| `phase disable-v1-registrars` | Phase 3: disable v1 registrar controllers |
| `phase verify-v1-registrars-disabled` | Verify v1 registrar controllers are disabled |
| `phase execute-owner-txs` | Execute prepared owner transactions from a JSONL file (optionally filtered by `--role`) |
| `phase switch-urp-to-managed` | Phase 5: point the top URP at the managed URP |
| `phase upgrade-managed-urp` | Phase 6: upgrade the managed URP to `UniversalResolverV2` |
| `phase verify-urp` | Verify top and managed URP implementations |
| `phase disable-batch-registrar` | Phase 7: revoke registrar/renew roles from `BatchRegistrar` |
| `phase verify-batch-registrar-disabled` | Verify `BatchRegistrar` no longer has registrar/renew roles |
| `phase batch-registrar-owner` | Print and optionally verify the `BatchRegistrar` owner |
| `phase activate-v1-handoff-controllers` | Phase 8: authorize `Graveyard` + testnet helper as v1 controllers |
| `phase activate-v1-graveyard` | Phase 8 (individual): authorize `Graveyard` only |
| `phase authorize-testnet-v1-premigration-registrar` | Phase 8 (individual, testnet): authorize the testnet premigration helper |
| `phase activate-v1-renewer` | Phase 9: authorize `ETHRenewerV1` on v1 and transfer `BaseRegistrar` ownership to it |
| `phase enable-v2-registrar` | Phase 9: grant registrar/renew roles to `ETHRegistrar` |
| `phase verify-v2-registrar` | Verify `ETHRegistrar` has registrar/renew roles |
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
| `premigration-run` | Run pre-migration reservations (phases 2/4) with the Hardhat signer as BatchRegistrar owner |

## Environment variables

Resolved by [`script/migration.ts`](../script/migration.ts) (the CLI also auto-loads `contracts/.env`):

| Variable | Used for |
| --- | --- |
| `SEPOLIA_RPC_URL` / `MAINNET_RPC_URL` | Default RPC when `--rpc-url` is omitted |
| `DEPLOYER_KEY` | Deployer key (`phase deploy-v2`); fallback for owner/urManager keys |
| `OWNER_KEY` | Owner / registry root-role admin (`phase deploy-v2`, `disable-batch-registrar`, `enable-v2-registrar`; falls back to `DEPLOYER_KEY`) |
| `UR_MANAGER_KEY` | Managed URP admin (`phase upgrade-managed-urp`; falls back to `DEPLOYER_KEY`) |
| `SEPOLIA_V1_OWNER_KEY` / `V1_OWNER_KEY` | v1 owner (`disable-v1-registrars` †, `activate-v1-*`, `authorize-testnet-v1-premigration-registrar`) |
| `SEPOLIA_TOP_URP_OWNER_KEY` / `TOP_URP_OWNER_KEY` | Top URP admin (`phase switch-urp-to-managed`) |
| `OWNER_TX_KEY` | Generic signer for `phase execute-owner-txs` when no role-specific key matches |
| `<PREFIX>_MNEMONIC`, `<PREFIX>_MNEMONIC_PATH`, `<PREFIX>_MNEMONIC_INDEX`, `<PREFIX>_MNEMONIC_PASSPHRASE` | Mnemonic-backed signer alternatives for `phase execute-owner-txs`; prefixes `OWNER_TX`, `SEPOLIA_V1_OWNER` / `V1_OWNER`, `SEPOLIA_TOP_URP_OWNER` / `TOP_URP_OWNER` |
| `PREMIGRATION_PRIVATE_KEY`, `BATCH_REGISTRAR_OWNER_KEY`, `DEPLOYER_KEY` | BatchRegistrar owner key fallbacks for `premigration run` / `resume` |
| `THEGRAPH_API_KEY` / `GRAPH_API_KEY` | TheGraph Gateway key for `fetch-data` |

† `phase disable-v1-registrars` takes the key via `--private-key`; the env fallbacks apply when it is executed through `phase execute-owner-txs` with `--role v1Owner`.

For `phase execute-owner-txs`, the key is selected by the `--role` filter: `v1Owner` → the v1-owner variables, `sepolia-top-urp-owner` → the top-URP-owner variables, `deployer` → `DEPLOYER_KEY`; with no role, `OWNER_TX_KEY` and then the role-specific variables are tried in order.

## Rehearsals

### `fork full`

```bash
bun run migration -- fork full --network sepolia --csv-file ./csv-data/ens-registrations-sepolia.csv \
  [--work-dir <dir>] [--save-deployments] [--snapshot-file <path>]
```

Spawns a local Anvil fork of the network RPC (default port 8547 sepolia / 8548 mainnet), impersonates the deployer, owner, v1 owner, URP admins, and BatchRegistrar owner, and runs phases 1–9 in order with smoke checks interleaved:

- v1 registration succeeds before phase 3 and is rejected after;
- a pre-migrated name is migrated to v2 via `UnlockedMigrationController` after phase 4;
- the v2 registrar rejects registrations before phase 9's grant, rejects pre-migrated reserved names after it, and accepts a fresh name after enablement.

`--direct` skips Anvil and targets `--rpc-url` directly (e.g. a Tenderly virtual testnet) — it requires explicit `--deployer` and `--ur-manager` addresses, plus `--owner` on sepolia (the Hardhat `migration fork-full` task derives them from the keystore). `--resume-from-phase 2` (requires `--work-dir`) skips phase 1 and reloads saved deployments. `--snapshot-file` records a pre-rehearsal `evm_snapshot` id, which the Hardhat `migration revert` task can restore.

### `clean-testnet`

```bash
bun run migration -- clean-testnet --network sepolia --rpc-url <url> --deployer <address>
```

Sepolia only. Runs phase 0 — a fresh v1 stack deployed into `deployments/v1/<namespace>` — then phases 1–9 directly against the RPC, always including `TestnetV1PremigrationRegistrar`. The v2 namespace defaults to `sepolia-clean-<timestamp>`; the command refuses to reuse the canonical `sepolia` namespace or any namespace that already contains deployment files. Without `--csv-file`, only the generated smoke labels are seeded. Against an RPC without state controls (anything other than a local node or a Tenderly virtual testnet), a configured deployer key is required — prefer the Hardhat `migration clean-testnet` task, which signs with the configured Hardhat account.

## Related docs

- [premigration.md](./premigration.md) — the `BatchRegistrar` seeding step in detail (phases 2 and 4): CSV format, continuity expiry, checkpoints, verification.
- [universalResolver.md](./universalResolver.md) — the URP proxy chain behind phases 5 and 6, and the post-cutover step.
- [prepareMigration.md](./prepareMigration.md) — the non-phased, all-at-once role hand-off script that phases 7 and 9 supersede.
