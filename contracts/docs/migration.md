# Phased v1 → v2 Migration

The v1 → v2 migration runs as seven explicit phases, driven by the `bun run migration` operator CLI
from `contracts/`. Phases run **strictly in order**. To rehearse the whole thing in one command see
[Quick start](#quick-start); to run it for real, work through [Phases](#phases) and the
[Live deployment (Sepolia)](#live-deployment-sepolia) runbook.

## Quick start

Rehearse all seven phases end-to-end against a throwaway local Anvil fork of the network — nothing
touches a real chain:

```bash
cd contracts
bun run compile
bun run migration -- fork full --network sepolia --csv-file ./csv-data/ens-registrations-sepolia.csv
```

That impersonates every signer and runs phases 1–7 with smoke checks interleaved. To rehearse against
a **live fork** (real v1 state) use a Tenderly virtual testnet — see
[Tenderly virtual testnets](#tenderly-virtual-testnets). To stand up a fresh, fully-owned testnet
stack instead, see [`clean-testnet`](#clean-testnet).

## Deployment contexts

Pick your path before running anything — it determines which phases apply:

- **Live public network (sepolia/mainnet)** — v1 already exists on-chain; run phases **1–7** with real
  signer keys. On mainnet the owner, URP admin, and v1 owner are the DAO/multisig, so owner-gated
  phases run with `--calldata-only` (or deferred) and execute through a Safe. → [Live deployment
  (Sepolia)](#live-deployment-sepolia).
- **Clean testnet (fresh v1)** — no usable v1; deploy a fresh v1 stack first (**phase 0**), then
  phases 1–7, always including `TestnetV1PremigrationRegistrar`. Sepolia only, via `clean-testnet`.
  → [`clean-testnet`](#clean-testnet).
- **Fork / Tenderly rehearsal** — dry-run phases 1–7 against a fork of the target network,
  impersonating every signer. Local Anvil via [`fork full`](#fork-full); a live fork via a
  [Tenderly virtual testnet](#tenderly-virtual-testnets).

The Universal Resolver cutover (phase 7) has a further split: **sepolia is a reuse network** (the top
proxy already fronts the intermediate one, so `switch-urp-to-managed` is skipped) while **mainnet and
fresh chains are bootstrap** (run `switch-urp-to-managed` first). Details in
[Phase 7](#phase-7-switch-the-universal-resolver-to-v2).

## Phases

Phase numbering matches the console output of the `fork full` orchestrator in
[`script/migration.ts`](../script/migration.ts). Every command below also takes the shared
[common options](#common-options) (`--network`, `--rpc-url`, deployment dirs); run any command with
`--help` for its authoritative option list.

| Phase | Action | Command(s) | Applies to | Signer |
| --- | --- | --- | --- | --- |
| 0 | Deploy fresh v1 contracts | part of `clean-testnet` | clean-testnet only | `deployer` |
| 1 | Deploy all v2 contracts (registrar deferred) | `phase deploy-v2` | live + clean-testnet | `deployer` / `owner` / `urManager` (+ v1 owner) |
| 2 | Seed v1 names as reserved on v2 | `premigration run` → `verify` | live + clean-testnet | BatchRegistrar owner |
| 3 | Freeze v1 registrations | `phase disable-v1-registrars` (+ `verify-*`) | live + clean-testnet | v1 owner |
| 4 | Keep unmigrated names renewable | `phase authorize-v1-renewer` | live + clean-testnet | v1 owner |
| 5 | Final pre-migration sync | `premigration run` → `verify` | live + clean-testnet | BatchRegistrar owner |
| 6 | Enable the v2 controller | `disable-batch-registrar` → `activate-v1-handoff-controllers` → `activate-v1-renewer` → `enable-v2-registrar` (+ `verify-*`) | live + clean-testnet | registry root-role admin + v1 owner |
| 7 | Switch Universal Resolver to v2 (cutover) | `phase upgrade-managed-urp` (+ `switch-urp-to-managed` on bootstrap) (+ `verify-urp`) | live + clean-testnet (bootstrap step mainnet/fresh only) | `urManager` (+ top URP owner on bootstrap) |

> **Re-deploying fresh onto an already-migrated network.** "Re-deploying fresh" means deploying a
> brand-new v2 set onto a network whose v1 a previous deployment already migrated — the earlier v2 set
> is archived (see [Deployment artifacts](#deployment-artifacts)) and left orphaned on-chain. Phase 1
> is where the fresh deploy happens; the later phases re-seed and re-wire v1 to the **new** contract
> addresses rather than the archived ones. Phases below carry a **Re-deploying fresh** note wherever
> that changes what you run — most importantly, phase 1 needs a `reclaim-v1-registrar-ownership` prep
> step and phase 3 becomes a no-op. The one-command shortcut is [`fork full`](#fork-full), which
> detects an already-migrated chain and adjusts automatically.

### Phase 0: deploy fresh v1 (clean-testnet only)

- **Applies to:** clean-testnet only. Skipped for live deployments — sepolia/mainnet already have v1.
- **Command:** no standalone phase command; it is the first step of [`clean-testnet`](#clean-testnet).
- **Prerequisites:** none — it is the entry step of `clean-testnet`. Sepolia only.
- **Env / args:** `--network sepolia`, `--rpc-url`, `--deployer <address>`. A funded deployer key is
  required unless the RPC provides state controls (local node or Tenderly virtual testnet, which
  impersonate instead).
- **Expected outcome:** a fresh v1 ENS stack (from `lib/ens-contracts/deploy`) deployed into
  `deployments/v1/<namespace>`, giving a v1 set to migrate from.

### Phase 1: deploy v2 contracts

- **Applies to:** live + clean-testnet.
- **Command:**
  ```bash
  bun run migration -- phase deploy-v2 --network sepolia

  # On live networks, record the v1-owner txs instead of broadcasting, then replay them:
  bun run migration -- phase deploy-v2 --network sepolia \
    --defer-v1-owner-transactions \
    --deferred-v1-owner-transactions-file .dev/phase1-v1owner.jsonl
  bun run migration -- phase execute-owner-txs --network sepolia \
    --role v1Owner --file .dev/phase1-v1owner.jsonl
  ```
  Add `--include-testnet-premigration-registrar` on testnet/clean runs to also deploy
  `TestnetV1PremigrationRegistrar`. Re-run with `--resume` to continue an interrupted deploy.
- **Prerequisites:** `bun run compile`; a freshly funded deployer (phase 1 sends many transactions).
- **Env / args:** `DEPLOYER_KEY` (also the `owner`/`urManager` fallback and the BatchRegistrar owner);
  `SEPOLIA_V1_OWNER_KEY` / `V1_OWNER_KEY` for the deferred v1-owner replay. `phase deploy-v2` cannot
  sign v1-owner transactions itself, hence the defer-then-replay flow above.
- **Expected outcome:** all v2 contracts deployed with the `ETHRegistrar` grant **deferred** to
  [phase 6](#phase-6-enable-the-v2-controller) (`BatchRegistrar` holds `REGISTRAR | RENEW` for
  seeding); the URP proxy chain points at the v1 `UniversalResolver`
  (see [universalResolver.md](./universalResolver.md)); the v2 reverse-registrar adapters are deployed
  and authorized as controllers on the v1 reverse registrars; artifacts written to
  `deployments/<network>/` (deploys fresh by default — see [Deployment artifacts](#deployment-artifacts)).
- **Re-deploying fresh:** `deploy-v2` archives the existing `deployments/<network>/` namespace and
  deploys a brand-new v2 set with new addresses (`--resume` is only for continuing an *interrupted*
  deploy into the same namespace, not for a fresh redeploy). First run
  [`phase reclaim-v1-registrar-ownership`](#cli-commands): the v1 `BaseRegistrar` is still owned by the
  prior deployment's `ETHRenewerV1`, and one deferred phase-1 tx is an owner-gated `setResolver` the v1
  owner must sign. Every later phase then seeds and wires v1 to this **new** set; the prior set stays
  on-chain but orphaned.

> External deployments on the migration timeline (e.g. an HCA component) live outside this repo and
> are not driven by `phase deploy-v2`.

### Phase 2: initial pre-migration

- **Applies to:** live + clean-testnet.
- **Command:**
  ```bash
  bun run migration -- premigration run --network sepolia \
    --csv-file <registrations.csv> --work-dir .dev/premig-1
  bun run migration -- premigration verify --network sepolia --csv-file <registrations.csv>
  ```
- **Prerequisites:** phase 1 complete. A current v1 registration CSV (Dune export for sepolia,
  BigQuery for mainnet). See [premigration.md](./premigration.md) for the CSV format, expiry rule,
  checkpointing, and verification.
- **Env / args:** BatchRegistrar owner key (`PREMIGRATION_PRIVATE_KEY`, `BATCH_REGISTRAR_OWNER_KEY`,
  or `DEPLOYER_KEY`); `--csv-file`, `--work-dir`, `--bonus-period-days` (default 62).
- **Expected outcome:** every active or in-grace v1 `.eth` 2LD seeded as a **reserved** entry on v2,
  with v2 expiry = v1 expiry + bonus period. `premigration verify` confirms the reservations.
- **Re-deploying fresh:** the new v2 registry is empty, so this seeds it from scratch exactly like a
  first run. Reservations from the prior deployment lived on the now-archived registry and do **not**
  carry over. Use a fresh `--work-dir` so no stale `preMigration-checkpoint.json` is picked up.

### Phase 3: disable v1 registrars

- **Applies to:** live + clean-testnet.
- **Command:**
  ```bash
  bun run migration -- phase disable-v1-registrars --network sepolia \
    --private-key $SEPOLIA_V1_OWNER_KEY
  bun run migration -- phase verify-v1-registrars-disabled --network sepolia
  ```
- **Prerequisites:** phase 2 complete (so no active name is stranded by the freeze). Signed by the v1
  owner. This command takes the key via `--private-key` explicitly — the env fallback applies only
  when it is run through `phase execute-owner-txs --role v1Owner`.
- **Env / args:** v1 owner key via `--private-key` (or `SEPOLIA_V1_OWNER_KEY` / `V1_OWNER_KEY` through
  execute-owner-txs). `--calldata-only` emits calldata for a multisig instead of broadcasting.
- **Expected outcome:** `LegacyETHRegistrarController`, `ETHRegistrarController`,
  `WrappedETHRegistrarController`, and `NameWrapper` removed as v1 `BaseRegistrar` controllers (via
  `RegistrarSecurityController` when deployed); new v1 registrations frozen.
  `verify-v1-registrars-disabled` confirms.
- **Re-deploying fresh:** normally a **no-op you can skip** — the v1 registrars were removed by the
  prior deployment and stay frozen (reclaiming v1 `BaseRegistrar` ownership in phase 1 does not
  re-enable them). Re-running is harmless (each controller logs "already disabled"); prefer just
  `verify-v1-registrars-disabled` to confirm the freeze is still in place.

### Phase 4: authorize ETHRenewerV1

- **Applies to:** live + clean-testnet.
- **Command:**
  ```bash
  bun run migration -- phase authorize-v1-renewer --network sepolia
  ```
- **Prerequisites:** phase 2 complete — `ETHRenewerV1` can only renew names already `RESERVED` on v2,
  so this phase is effective only after the initial pre-migration. Runs right after the phase 3 freeze.
- **Env / args:** v1 owner key (`SEPOLIA_V1_OWNER_KEY` / `V1_OWNER_KEY`, read from env).
  `--calldata-only` for a multisig.
- **Expected outcome:** `ETHRenewerV1` authorized as a v1 `BaseRegistrar` controller; unmigrated names
  stay renewable, each renewal extending both the v1 registration and the v2 reservation in one
  transaction. This does **not** reopen the phase 3 registration freeze. The final lock-down that
  transfers v1 `BaseRegistrar` ownership to `ETHRenewerV1` is deferred to
  [phase 6](#phase-6-enable-the-v2-controller).
- **Re-deploying fresh:** authorizes the **newly-deployed** `ETHRenewerV1` (a new address) as a v1
  controller — must be re-run. The prior deployment's `ETHRenewerV1` remains an authorized controller
  (orphaned but harmless); the tooling does not deauthorize it, so remove it manually only if you want
  a clean controller set.

> **Mainnet renewal continuity.** Renewals are paused between phase 3 (freeze) and phase 4
> (authorize), and the phase 5 sync can run for days. When the v1 owner is a DAO/multisig, execute
> phases 3 and 4 **atomically in one v1-owner batch** — both support `--calldata-only`, so their
> calldata combines into a single Safe/multisend transaction.

### Phase 5: final pre-migration sync

- **Applies to:** live + clean-testnet.
- **Command:**
  ```bash
  bun run migration -- premigration run --network sepolia \
    --csv-file <fresh-post-freeze.csv> --work-dir .dev/premig-2
  bun run migration -- premigration verify --network sepolia --csv-file <fresh-post-freeze.csv>
  ```
- **Prerequisites:** phase 3 freeze done. Export a **fresh** post-freeze registration CSV so names
  registered or renewed since phase 2 are caught up.
- **Env / args:** same BatchRegistrar owner key as [phase 2](#phase-2-initial-pre-migration).
- **Expected outcome:** names already reserved on v2 are re-reserved with their bonus-adjusted expiry
  — picking up any expiry extensions from `ETHRenewerV1` renewals since phase 4 — and newly eligible
  names are reserved for the first time.
- **Re-deploying fresh:** same as [phase 2](#phase-2-initial-pre-migration) — re-seeds the new
  registry against a fresh post-freeze CSV and a fresh `--work-dir`.

### Phase 6: enable the v2 controller

- **Applies to:** live + clean-testnet.
- **Command:** four owner-gated steps, **in order**, then verify:
  ```bash
  bun run migration -- phase disable-batch-registrar          --network sepolia
  bun run migration -- phase activate-v1-handoff-controllers  --network sepolia
  bun run migration -- phase activate-v1-renewer              --network sepolia
  bun run migration -- phase enable-v2-registrar              --network sepolia
  bun run migration -- phase verify-v2-registrar              --network sepolia
  ```
- **Prerequisites:** phase 5 complete. Order matters — the handoff controllers must be authorized
  **before** `activate-v1-renewer` transfers v1 `BaseRegistrar` ownership away from the v1 owner
  (after which the v1 owner can no longer manage controllers).
- **Env / args:** registry root-role admin key (`OWNER_KEY`, falls back to `DEPLOYER_KEY`) for
  `disable-batch-registrar` and `enable-v2-registrar`; v1 owner key for the `activate-v1-*` steps. The
  owner-gated and v1-owner steps accept `--calldata-only` for a multisig. On testnets
  `TestnetV1PremigrationRegistrar` keeps its roles, re-authorized by `activate-v1-handoff-controllers`
  (the individual steps are also available as `activate-v1-graveyard` and
  `authorize-testnet-v1-premigration-registrar`).
- **Expected outcome:** `BatchRegistrar` roles revoked (pre-migration seeding ends); `Graveyard` (+
  testnet helper) authorized as v1 controllers; v1 `BaseRegistrar` ownership transferred to
  `ETHRenewerV1` (final lock-down); `ETHRegistrar` granted `REGISTRAR | RENEW` on the v2 `ETHRegistry`
  — live v2 registrations open. `verify-v2-registrar` confirms the grant. This bundle replaces the
  all-at-once role swap done by [prepareMigration.md](./prepareMigration.md).
- **Re-deploying fresh:** re-points v1 at the new set and must be re-run —
  `activate-v1-handoff-controllers` authorizes the new `Graveyard`, `activate-v1-renewer` transfers v1
  `BaseRegistrar` ownership to the new `ETHRenewerV1` (the ownership you reclaimed in phase 1), and
  `enable-v2-registrar` grants the new `ETHRegistrar`. The prior deployment's `Graveyard`/`ETHRenewerV1`
  remain authorized as orphaned v1 controllers.

### Phase 7: switch the Universal Resolver to v2

- **Applies to:** live + clean-testnet. The **`switch-urp-to-managed`** step is **bootstrap-only**
  (mainnet and fresh chains); the sepolia reuse path skips it.
- **Command:**
  ```bash
  # Reuse networks (sepolia): the top URP already fronts the intermediate URP, so only the upgrade runs
  bun run migration -- phase upgrade-managed-urp --network sepolia
  bun run migration -- phase verify-urp          --network sepolia

  # Bootstrap networks (mainnet, fresh chains): point the top URP at the intermediate URP first
  bun run migration -- phase switch-urp-to-managed --network mainnet
  bun run migration -- phase upgrade-managed-urp   --network mainnet
  bun run migration -- phase verify-urp            --network mainnet
  ```
- **Prerequisites:** phase 6 complete. Run **last**, so public resolution flips to v2 only once
  everything else is live.
- **Env / args:** intermediate URP admin key (`UR_MANAGER_KEY`, falls back to `DEPLOYER_KEY`) for
  `upgrade-managed-urp`; top URP owner key (`SEPOLIA_TOP_URP_OWNER_KEY` / `TOP_URP_OWNER_KEY`) for the
  bootstrap `switch-urp-to-managed`. `--calldata-only` for a multisig/DAO.
- **Expected outcome:** the resolution cutover — the intermediate URP is upgraded to
  `UniversalResolverV2` and public resolution serves v2. `verify-urp` confirms both proxy
  implementations. See [universalResolver.md](./universalResolver.md) for the proxy chain and the
  optional post-cutover step.
- **Re-deploying fresh:** on a reuse network (sepolia) the top **and** intermediate URPs are adopted by
  address and never redeployed — phase 1 deploys a fresh `UniversalResolverV2` implementation and
  `upgrade-managed-urp` re-points the reused intermediate URP at it, orphaning the prior
  implementation. Bootstrap networks (mainnet/fresh) deploy a fresh intermediate URP instead. Must be
  re-run to serve the new implementation.

## Live deployment (Sepolia)

End-to-end runbook for a fresh Sepolia deployment against the canonical (live) v1. **Rehearse first**
— [`fork full`](#fork-full), ideally against a [Tenderly live fork](#tenderly-virtual-testnets),
exercises this exact sequence.

### Signer keys

Three keys cover every signature on the sepolia reuse path. The top URP owner key is **not** needed —
the top URP already fronts the intermediate URP, so the cutover never touches it.

| Key | Role |
| --- | --- |
| `DEPLOYER_KEY` | Deployer EOA; on sepolia also resolves as `owner` (registry root-role admin) and is the `BatchRegistrar` owner. Must be freshly funded — phase 1 sends many transactions. |
| `SEPOLIA_V1_OWNER_KEY` | v1 owner (`0x0f32b753afc8abad9ca6fe589f707755f4df2353`); signs the deferred phase-1 v1-owner txs, phase 3, phase 4, and the phase-6 `activate-v1-*` steps. |
| `UR_MANAGER_KEY` | Intermediate `ManagedUniversalResolverProxy` admin (`0x6d80F2172CFdEc5730fE683860C33d26fC42e6F1`, admin `0xffFffFFfFF52D316B7Bd028358089bc8066b8f80`); signs the phase-7 cutover. |

### Setup

```bash
cd contracts
bun run compile                                      # forge + hardhat → generated/artifacts

export SEPOLIA_RPC_URL=<reliable paid sepolia RPC>   # phase 1 sends many txs
export DEPLOYER_KEY=0x<fresh funded EOA>             # also owner / urManager / BatchRegistrar owner
export SEPOLIA_V1_OWNER_KEY=0x<key for 0x0f32…2353>

mkdir -p .dev/sepolia-live
```

Also export a **current** Sepolia registration CSV for the pre-migration phases (Dune export — see
[premigration.md](./premigration.md)); the repo's `csv-data/ens-registrations-sepolia.csv` is a small
sample, not a real export.

> **Deployer and `.env` hygiene.** `DEPLOYER_KEY` should be a freshly funded EOA. If it happens to be
> the same address as the v1 owner, `phase deploy-v2` wires that address with the v1-owner key so it
> keeps a local signer. Keep `.env` values free of inline `#` comments — quote a value if it must
> contain a literal `#`.

### Run the phases

Run the phases in order; each links to its entry in [Phases](#phases) for the exact command,
prerequisites, and expected outcome:

1. [Phase 1 — deploy fresh v2](#phase-1-deploy-v2-contracts), recording v1-owner txs with
   `--defer-v1-owner-transactions --deferred-v1-owner-transactions-file .dev/sepolia-live/phase1-v1owner.jsonl`
   and replaying them via `phase execute-owner-txs --role v1Owner`.
2. [Phase 2 — initial pre-migration](#phase-2-initial-pre-migration) (`--work-dir .dev/sepolia-live/premig-1`).
3. [Phase 3 — freeze v1 registrations](#phase-3-disable-v1-registrars) (`--private-key $SEPOLIA_V1_OWNER_KEY`).
4. [Phase 4 — keep names renewable](#phase-4-authorize-ethrenewerv1). With an EOA v1 owner on Sepolia
   you can run phases 3 and 4 back-to-back, so the renewal gap is small.
5. [Phase 5 — final sync](#phase-5-final-pre-migration-sync) from a fresh post-freeze CSV
   (`--work-dir .dev/sepolia-live/premig-2`).
6. [Phase 6 — enable the v2 controller](#phase-6-enable-the-v2-controller).
7. [Phase 7 — resolution cutover](#phase-7-switch-the-universal-resolver-to-v2): sepolia is a reuse
   network, so only `upgrade-managed-urp` + `verify-urp` run.

> **Re-deploying onto an already-migrated Sepolia?** This runbook assumes a first migration. On a
> repeat deploy the order is unchanged, but read each phase's **Re-deploying fresh** note first: run
> [`phase reclaim-v1-registrar-ownership`](#cli-commands) before phase 1, skip phase 3 (v1 is already
> frozen), and expect phases 2, 4, 5, 6, and 7 to re-seed and re-wire v1 to the new contract set.

### After

The new `deployments/sepolia/` namespace (and any dated archive) is committed automatically —
`.gitignore` tracks real namespaces and ignores only the `-fork` / `-clean-` runtime sets (see
[deployments/README.md](../deployments/README.md)). Pre-migration (phases 2 and 5) is the heavy,
stateful part: it is checkpointed (`premigration resume`) and has its own flags — read
[premigration.md](./premigration.md) and confirm the CSV export before the live run.

> **Mainnet differs.** The owner, top URP admin, and v1 owner are all the DAO/multisig, so the
> owner-signed and URP-admin phases run with `--calldata-only` (or deferred) and execute through the
> Safe. Mainnet is also a **bootstrap** URP network, so phase 7 additionally runs
> `switch-urp-to-managed` first.

### Verify source code

Once live, submit the deployed contracts for source verification on Etherscan and Sourcify. This reads
the artifacts under `deployments/<network>/` — no recompile or redeploy is required:

```bash
cd contracts
export ETHERSCAN_API_KEY=<etherscan v2 api key>   # one key covers all chains; not needed for Sourcify
bun run verify:sepolia                            # → verify:mainnet for the mainnet set
```

`verify:<network>` runs [`script/verify.ts`](../script/verify.ts), which submits every contract to
both Etherscan and Sourcify via [`@rocketh/verifier`](https://www.npmjs.com/package/@rocketh/verifier).
It is idempotent and re-runnable: contracts already verified on a backend are detected and skipped. The
verifier rebuilds the solc standard-JSON input from each artifact's metadata, backfilling source
content from disk for forge-compiled artifacts, so a contract verifies regardless of which compiler
produced it. Flags after `--` pass through (e.g. `bun run verify -- --network sepolia --etherscan-only`).

## Rehearsals

### `fork full`

```bash
bun run migration -- fork full --network sepolia --csv-file ./csv-data/ens-registrations-sepolia.csv \
  [--work-dir <dir>] [--save-deployments] [--snapshot-file <path>]
```

Spawns a local Anvil fork of the network RPC (default port 8547 sepolia / 8548 mainnet), impersonates
the deployer, owner, v1 owner, URP admins, and BatchRegistrar owner, and runs phases 1–7 in order with
smoke checks interleaved:

- v1 registration succeeds before phase 3 and is rejected after;
- `ETHRenewerV1` is confirmed as an authorized v1 renewal controller after phase 4;
- a pre-migrated name is migrated to v2 via `UnlockedMigrationController` after phase 5;
- the v2 registrar rejects registrations before phase 6's grant, rejects pre-migrated reserved names
  after it, and accepts a fresh name after enablement.

When the target chain has already completed the v1 hand-off (re-running against an already-migrated
Sepolia, or a repeat mainnet run), `fork full` detects this from the v1 registrar-controller state and
skips the smoke checks that require live v1 registration, while still running the deploy,
pre-migration, renewer authorization, the pre-enablement rejection, the fresh-name registration, and
the URP cutover. A pristine chain runs all of them; there is no flag — it is detected automatically.

`--direct` skips Anvil and targets `--rpc-url` directly (see
[Tenderly virtual testnets](#tenderly-virtual-testnets)) — it requires explicit `--deployer` and
`--ur-manager` addresses, plus `--owner` on sepolia (the Hardhat `migration fork-full` task derives
them from the keystore). `--resume-from-phase 2` (requires `--work-dir`) skips phase 1 and reloads
saved deployments. `--snapshot-file` records a pre-rehearsal `evm_snapshot` id, which the Hardhat
`migration revert` task can restore.

### `clean-testnet`

`clean-testnet` stands up a **complete, throwaway v1 → v2 migration on public Sepolia using a fresh v1
stack you fully own** — for integration testing or demos where you want a real, on-chain v1 + v2
migrated set without depending on, or risking, the canonical ENS deployment.

```bash
bun run migration -- clean-testnet --network sepolia --rpc-url <url> --deployer <address>
```

Sepolia only. It runs **phase 0** — a fresh v1 stack deployed into `deployments/v1/<namespace>` — then
phases 1–7 directly against the RPC, always including `TestnetV1PremigrationRegistrar`. The v2
namespace defaults to `sepolia-clean-<timestamp>`; the command refuses to reuse the canonical
`sepolia` namespace or any namespace that already contains deployment files. Without `--csv-file`,
only the generated smoke labels are seeded. Against an RPC without state controls (anything other than
a local node or a Tenderly virtual testnet) a configured deployer key is required — prefer the Hardhat
`migration clean-testnet` task, which signs with the configured Hardhat account.

### Tenderly virtual testnets

Every command that impersonates signers also works against a **Tenderly Virtual TestNet** — an RPC
whose host is `virtual.<...>.rpc.tenderly.co`. The CLI **auto-detects** these (there is no `--tenderly`
flag) and uses Tenderly's state-control methods (`tenderly_setBalance`, `tenderly_impersonateAccount`,
time-travel) to fund and impersonate every account, so **no signer keys are needed**.

The main use is a **full dress rehearsal of a live network against a Tenderly live fork**: create a
Virtual TestNet that forks live Sepolia or mainnet (so the real v1 ENS state is present) and run the
whole migration against it in one command:

```bash
bun run migration -- fork full --direct --network sepolia \
  --rpc-url https://virtual.<...>.rpc.tenderly.co/<id> \
  --csv-file <fresh-sepolia.csv> \
  --deployer <address> --ur-manager <address> --owner <address>   # --owner required on sepolia
```

`--direct` targets the Tenderly RPC directly instead of spawning Anvil; because it can't derive
accounts from a Hardhat keystore, pass the signer **addresses** explicitly (`--deployer`,
`--ur-manager`, and `--owner` on sepolia). Mainnet works the same way (`--network mainnet`; it is a
bootstrap URP network). Individual [`phase`](#cli-commands) commands can likewise target a Tenderly RPC
using their `--impersonate-account` / `--impersonate-owner` / `--impersonate-v1-owner` flags instead of
keys.

> `clean-testnet` also runs against a Tenderly virtual testnet, but it deploys a **fresh** v1 stack
> (phase 0) rather than migrating the forked live v1 — use `fork full --direct` to rehearse the real
> v1 → v2 migration of live Sepolia or mainnet.

## Orchestration

The migration is driven by three pieces:

- **Operator CLI** — [`script/migration.ts`](../script/migration.ts), run as
  `bun run migration -- <command>` from `contracts/`. Each phase is an individual subcommand;
  `fork full` and `clean-testnet` run all phases end-to-end as rehearsals.
- **Hardhat plugin** — [`plugins/migration/index.ts`](../plugins/migration/index.ts), registering
  `migration <task>` tasks that wrap the same phase functions but derive signers from the configured
  Hardhat network/keystore: `bunx hardhat --network <net> migration <task>`.
- **Phased deploy scripts** — the scripts under [`deploy/`](../deploy/) carry migration tags
  (`migration:phase1:deploy-v2`, `migration:phase5:switch-urp-to-managed`,
  `migration:phase6:upgrade-managed-urp`, `migration:post-cutover:direct-urp-to-v2`) so each on-chain
  change is bound to a deploy step. (The tag strings predate the current numbering and are kept as
  stable identifiers.)

> **Ordering.** Renewal compatibility is enabled early (phase 4) so unmigrated v1 names stay renewable
> throughout the migration window, and the final pre-migration sync (phase 5) then picks up any
> renewed expiries. The Universal Resolver is cut over to v2 last (phase 7) so public resolution flips
> only once everything else is live.

## Deployment artifacts

Phase 1 reads and writes rocketh deployment artifacts under
[`deployments/`](../deployments/README.md), grouped into per-deployment **namespace** directories
selected with `--deployments-dir` / `--deployment-network` (v1 references via `--v1-deployments-dir` /
`--v1-deployment-network`).

`phase deploy-v2` **deploys fresh by default** — it archives the current namespace to
`deployments/<env>-<YYYYMMDD>-r<N>` and deploys into a clean one. Since phase 1 sends many
transactions and can be interrupted, re-run with `--resume` to continue into the existing namespace
instead (rocketh is idempotent, sending only the not-yet-deployed contracts). See
[`deployments/README.md`](../deployments/README.md) for the namespace layout, archiving, git-tracking,
and idempotency rules.

## Reference

### Common options

Most commands share these option groups. Run `bun run migration -- <command> --help` for the
authoritative per-command list — it is the source of truth for what each command accepts.

- **Network** (every on-chain command): `--network sepolia|mainnet` (required),
  `--rpc-url <url>` (falls back to `SEPOLIA_RPC_URL` / `MAINNET_RPC_URL`), `--chain-id <id>`.
- **Deployments**: `--deployments-dir <path>`, `--deployment-network <name>` (v2 addresses);
  `--v1-deployments-dir <path>`, `--v1-deployment-network <name>` (v1 addresses). Contract addresses
  default to the deployment JSON under these dirs; explicit address flags (e.g. `--registry`,
  `--batch-registrar`) override.
- **Owner-gated writes** (v1-owner and URP-admin phases): `--private-key <key>`, `--impersonate-owner`
  or `--impersonate-account <address>` (fork/Tenderly), `--calldata-only` (print the transaction
  target and calldata for multisig execution instead of broadcasting).

Two commands are **not** on-chain and intentionally omit the network options:

- **`premigration status`** reads the local checkpoint file only — its sole option is `--work-dir`. It
  does **not** accept `--network` / `--rpc-url`; passing them errors with `unknown option`.
- **`fetch-data`** queries TheGraph, not a chain — it has its own `--network` (default `mainnet`) and
  no `--rpc-url`.

### CLI commands

`bun run migration -- <command>` from `contracts/` (entrypoint
[`script/migration.ts`](../script/migration.ts), wired through `package.json`). The CLI auto-loads
`contracts/.env` (already-set environment variables win).

| Command | Purpose |
| --- | --- |
| `fetch-data` | Export ENS registrations from the TheGraph subgraph (mainnet or sepolia) into a pre-migration CSV |
| `premigration run` | Start pre-migration reservations from a fresh checkpoint (phases 2/5) |
| `premigration resume` | Resume pre-migration from the checkpoint |
| `premigration status` | Print the current pre-migration checkpoint JSON (local; `--work-dir` only) |
| `premigration verify` | Verify eligible CSV names were reserved or registered on v2 |
| `phase deploy-v2` | Phase 1: deploy the v2 migration contracts with the registrar deferred; archives any existing namespace and deploys fresh by default (`--resume` continues an interrupted deploy) |
| `phase reclaim-v1-registrar-ownership` | Re-migration only: reclaim v1 `BaseRegistrar` ownership from a prior deployment's `ETHRenewerV1` back to the v1 owner (run before the Phase 1 deferred-tx replay on an already-migrated chain) |
| `phase disable-v1-registrars` | Phase 3: disable v1 registrar controllers |
| `phase set-v1-reverse-default-resolver` | Point the v1 `ReverseRegistrar` default resolver at the v1 `PublicResolver` (v1-owner write) |
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
| `phase switch-urp-to-managed` | Phase 7 (bootstrap only): point the top URP at the managed URP |
| `phase upgrade-managed-urp` | Phase 7: upgrade the managed URP to `UniversalResolverV2` (resolution cutover) |
| `phase verify-urp` | Verify top and managed URP implementations |
| `fork full` | Run the full phased migration rehearsal against an Anvil fork (or a Tenderly fork with `--direct`) |
| `clean-testnet` | Deploy fresh testnet v1 contracts and run the full phased migration (sepolia only) |

### Hardhat plugin tasks

Registered by [`plugins/migration/index.ts`](../plugins/migration/index.ts); invoke as:

```bash
bunx hardhat --network <net> migration <task> [--options]
```

The tasks select the migration network with `--migration-network sepolia|mainnet` and use the Hardhat
network's RPC and configured signer (so private keys can come from the Hardhat keystore instead of
flags/env). See `bunx hardhat migration <task> --help` for options.

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

### Environment variables

Resolved by [`script/migration.ts`](../script/migration.ts) (the CLI also auto-loads `contracts/.env`):

| Variable | Used for |
| --- | --- |
| `SEPOLIA_RPC_URL` / `MAINNET_RPC_URL` | Default RPC when `--rpc-url` is omitted |
| `DEPLOYER_KEY` | Deployer key (`phase deploy-v2`); fallback for owner/urManager keys |
| `OWNER_KEY` | Owner / registry root-role admin (`phase deploy-v2`, `disable-batch-registrar`, `enable-v2-registrar`; falls back to `DEPLOYER_KEY`) |
| `UR_MANAGER_KEY` | Intermediate URP admin (`phase upgrade-managed-urp`; falls back to `DEPLOYER_KEY`) |
| `SEPOLIA_V1_OWNER_KEY` / `V1_OWNER_KEY` | v1 owner (`disable-v1-registrars` †, `set-v1-reverse-default-resolver`, `authorize-v1-renewer`, `activate-v1-*`, `authorize-testnet-v1-premigration-registrar`) |
| `SEPOLIA_TOP_URP_OWNER_KEY` / `TOP_URP_OWNER_KEY` | Top URP admin (`phase switch-urp-to-managed`, bootstrap networks only) |
| `OWNER_TX_KEY` | Generic signer for `phase execute-owner-txs` when no role-specific key matches |
| `<PREFIX>_MNEMONIC`, `<PREFIX>_MNEMONIC_PATH`, `<PREFIX>_MNEMONIC_INDEX`, `<PREFIX>_MNEMONIC_PASSPHRASE` | Mnemonic-backed signer alternatives for `phase execute-owner-txs`; prefixes `OWNER_TX`, `SEPOLIA_V1_OWNER` / `V1_OWNER`, `SEPOLIA_TOP_URP_OWNER` / `TOP_URP_OWNER` |
| `PREMIGRATION_PRIVATE_KEY`, `BATCH_REGISTRAR_OWNER_KEY`, `DEPLOYER_KEY` | BatchRegistrar owner key fallbacks for `premigration run` / `resume` |
| `THEGRAPH_API_KEY` / `GRAPH_API_KEY` | TheGraph Gateway key for `fetch-data` |
| `ETHERSCAN_API_KEY` | Etherscan v2 (multichain) API key for source-code verification (`bun run verify:<network>`); not needed for Sourcify |

† `phase disable-v1-registrars` takes the key via `--private-key`; the env fallbacks apply when it is
executed through `phase execute-owner-txs` with `--role v1Owner`. For `phase execute-owner-txs`, the
key is selected by the `--role` filter: `v1Owner` → the v1-owner variables, `sepolia-top-urp-owner` →
the top-URP-owner variables, `deployer` → `DEPLOYER_KEY`; with no role, `OWNER_TX_KEY` then the
role-specific variables are tried in order.

## Related docs

- [premigration.md](./premigration.md) — the `BatchRegistrar` seeding step in detail (phases 2 and 5):
  CSV format, continuity expiry, checkpoints, verification.
- [universalResolver.md](./universalResolver.md) — the URP proxy chain behind phase 7, and the
  post-cutover step.
- [prepareMigration.md](./prepareMigration.md) — the non-phased, all-at-once role hand-off script that
  phase 6 supersedes.
- [deployments/README.md](../deployments/README.md) — deployment artifact layout, namespace naming,
  and the idempotency rule for fresh re-deploys.