# Deployments

Deployment artifacts written and read by [rocketh](https://github.com/wighawag/rocketh)
through the migration tooling ([`script/migrate.ts`](../script/migrate.ts),
[`docs/migration.md`](../docs/migration.md)) and the single-contract deploy
([`script/deployContract.ts`](../script/deployContract.ts), `bun run deploy:contract`).
Each contract a deploy script produces is recorded here as JSON so later runs and
the phase commands can resolve on-chain addresses without re-deploying.

## Layout

Artifacts are grouped into **namespaces**, one directory per deployment set:

```
deployments/
  README.md               # this file
  <namespace>/            # a single deployment set (v2 contracts)
    .chain                # { chainId, genesisHash } the set was deployed against
    .migrations.json      # rocketh's record of completed deploy scripts (id → unix-epoch-seconds)
    .deployment.json      # { environment, chainId, deployedAt, updatedAt } — first and latest deploy
    .premigration.json    # pre-migration counts sidecar (names reserved/renewed/skipped/…), no label strings
    <Contract>.json       # one file per deployed contract (address, abi, bytecode, receipt, buildInfoId, …)
    build-info/
      <buildInfoId>.json  # exact compiler input shared by every contract from that build
    addresses.md          # generated address table (see "Address pages")
    roles.md              # generated record of who controls the deployment (`phase verify-roles`)
    dao/                  # DAO proposal files from `phase build-dao-proposal`, where kept (mainnet)
  <network>-adhoc/        # contracts deployed one at a time with `deploy:contract`
  <namespace>-<kind>-<YYYYMMDD>[-r<N>]/
                          # records replaced in <namespace>; <kind> is `redeploy` or `root`
  <namespace>-<YYYYMMDD>-r<N>/
                          # a whole earlier deployment, archived by `phase deploy-v2`
  v1/
    <network>/            # local v1-reference overrides (searched before the bundled set)
      .chainId            # chain id of the referenced v1 set
      <Contract>.json
```

The `.chain`, `.migrations.json`, `.deployment.json`, and `.premigration.json`
dotfiles are metadata; rocketh loads only `.migrations.json` and the
`<Contract>.json` artifacts and ignores every other dotfile, so none of them are
mistaken for a contract. `.deployment.json` is created on the first deploy into a
namespace, so its `deployedAt` records the original deployment time and survives
idempotent re-runs. Each later migration deploy that changes the namespace sets
its `updatedAt`.

Compiled deployment artifacts record a `buildInfoId`. The matching file under
`build-info/` preserves the exact compiler version, settings, remappings, and
source text used to produce the deployed bytecode. It is copied once per build,
so contracts compiled together share one file. The much larger compiler output
is not committed because it can be regenerated from this input. Vendored
artifacts that were not produced by this Hardhat build may omit `buildInfoId`.

`.premigration.json` is the durable record of the v1→v2 pre-migration run(s) that
targeted this namespace. It holds counts only — never the reserved label strings
(the corpus is large) — with one entry per logical run (`initial`, `final-sync`,
or a standalone `run`, upserted by label) plus a `resolved` roll-up of the final
numbers: names pre-migrated, expiry re-syncs, names skipped because they were
never registered on v1 or lapsed past the v1 grace period, invalid labels, names
already on v2, and failures. It is written by the pre-migration command whenever
the target namespace persists (so `fork full` rehearsals without
`--save-deployments` leave it untouched).

A namespace is addressed by two inputs on every migration command:

- `--deployments-dir <path>` — the root (defaults to this `deployments/` directory).
- `--deployment-network <name>` — the namespace subdirectory. Defaults to the
  migration network name (`sepolia` / `mainnet`), i.e. `deployments/sepolia/`.

v1 references resolve independently via `--v1-deployments-dir`
(default `deployments/v1`, then the bundled `lib/ens-contracts/deployments`) and
`--v1-deployment-network` (default: the network name). The two roots are searched
in order and the first match wins, so `deployments/v1/<network>/` acts as a **local
override layer**: the bundled ens-contracts deployment supplies the canonical v1
contracts, and anything dropped under `deployments/v1/` takes precedence or adds a
contract the bundled set omits.

## Ad-hoc deployments and record archives

`bun run deploy:contract <Contract> --network <network>` records the contract in
`<network>-adhoc/` unless `--deployment-network` names another namespace. A record
that names this build's code on the chain, with the same constructor arguments, is
reused. Otherwise the contract is deployed again, and the old record moves to a
record archive.

A record archive keeps records that were replaced in a namespace, so their
addresses stay on record and their source can still be verified. It is named
`<namespace>-<kind>-<YYYYMMDD>`, with `-r<N>` added when the name is taken:

- `redeploy`: written by `deploy:contract` and the contract redeploy phases, for
  example `mainnet-redeploy-20261026` or `mainnet-adhoc-redeploy-20261109`.
- `root`: written by the root registry redeploy, for example `mainnet-root-20261013`.

Each archive holds the replaced `<Contract>.json` files and a copy of the
namespace's `.chain`, which the address pages need to read it. An archive written
by `deploy:contract` also holds the `build-info/` files its records name. To drop a
deployment that will not be used, archive its record by hand the same way; see
[`docs/migration.md`](../docs/migration.md).

A record archive is not the same as a whole-deployment archive
(`<namespace>-<YYYYMMDD>-r<N>`, below), which keeps an entire earlier deployment.

## Address pages

`<namespace>/addresses.md` lists the contracts of a deployment. For mainnet and
sepolia, the same table is published as
[`docs/addresses/<network>.md`](../docs/addresses). Each table gives the latest
deployed address of each contract, read from `<namespace>/` and
`<namespace>-adhoc/` and leaving out archived records. Below it, a changelog lists
every address of each contract deployed more than once or deployed ad hoc,
archived ones included, with the UTC time its block was mined.

The migration deploy writes the table of every namespace it persists. After a
deploy to a public chain, `deploy:contract` rewrites both tables of a network with
a published page. To rewrite them by hand, run
`bun run docs:addresses --network <network>` with `--rpc-url`, or with
`<NETWORK>_RPC_URL` set: the changelog's times are read from the chain.

## Namespace naming and `sepolia-official-v1-20260525-r2`

`sepolia-official-v1-20260525-r2` is the existing **v2** deployment on Sepolia
(chain `11155111`) — the name encodes that it was built against the official v1
references, dated `2026-05-25`, revision `r2`. Despite `v1` in the name its
contents are the v2 set (`ETHRegistry`, `ENSV2Resolver`, `ETHRegistrar`,
`UpgradableUniversalResolverProxy`, the migration controllers, …).

The date/revision suffix is deliberate: **a previous deployment is kept as a
standalone, immutable record** rather than being overwritten, and rocketh always
gets a clean folder to deploy into (see below). This folder was named by hand;
`phase deploy-v2` now produces the same shape automatically, archiving the prior
set to `<env>-<YYYYMMDD>-r<N>`.

Because this namespace is not the default (`sepolia`), routine commands and the
`fork full` rehearsal do not load it unless you pass
`--deployment-network sepolia-official-v1-20260525-r2`.

## Re-deploying: fresh by default, `--resume` to continue

`phase deploy-v2` deploys fresh by default — it archives the current namespace out
of the way and deploys into a clean one:

```bash
bun run migration -- phase deploy-v2 --network sepolia
```

- The existing `deployments/<env>/` is renamed to `deployments/<env>-<YYYYMMDD>-r<N>`,
  where the date is the archived deployment's `deployedAt` (from `.deployment.json`,
  falling back to the latest `.migrations.json` timestamp) and `<N>` auto-increments
  if a same-date archive already exists.
- A fresh deployment is then written into `deployments/<env>/` and a new
  `.deployment.json` is stamped.

This works identically for `--network mainnet` (the namespace defaults to the
network name). Manually moving or clearing the namespace directory first is
equivalent; the default archive just automates it with a dated name.

Phase 1 sends many transactions and can be interrupted partway. Re-run with
`--resume` to continue into the **existing** namespace instead of archiving:

```bash
bun run migration -- phase deploy-v2 --network sepolia --resume
```

rocketh is idempotent against the namespace folder — a deploy script that finds an
artifact of the same name **reuses it instead of redeploying** (scripts guard with
`getOrNull(name) ?? deploy(name, …)`, and `.migrations.json` lets the runner skip
scripts that already completed) — so `--resume` reloads the contracts already
deployed and sends only the not-yet-deployed ones.

The persistent `UpgradableUniversalResolverProxy` entry point
(`0xeEeE…EeEe`) is fixed by constant and is never re-deployed; a fresh run
re-points it at the newly deployed managed URP during phase 7. The previous
namespace's contracts remain on-chain but become orphaned once the entry point
is cut over.

## Saving artifacts

The rehearsal (`fork full`) deploys into its own `<network>-fork` namespace unless
`--deployment-network` names another, and persists there. It has to: phase 3's
controller audit reads the active deployment's handoff contracts off disk to tell
them apart from a superseded deployment's. That namespace is gitignored and
re-created by the next run, so a rehearsal still leaves the committed sets
untouched. Deploying a rehearsal into the live namespace instead would make phase 1
try to adopt and upgrade the real chain's proxies, which fails on a fork.

`phase deploy-v2` always persists its deployment into the chosen
`--deployment-network` (both a fresh run and a `--resume`).

## Git tracking

`.gitignore` tracks real deployment namespaces by default and ignores only the
local rehearsal/runtime ones, so committed sets are not dimmed by editors while
throwaway runs stay out of the repository:

```
deployments/*-fork/        # fork full --save-deployments rehearsal namespaces
deployments/*-clean-*/      # clean-testnet runtime namespaces
deployments/v1/*            # v1 references are ignored …
!deployments/v1/sepolia/    # … except the tracked sepolia v1 references
!deployments/v1/mainnet/    # … and the tracked mainnet v1 references
```

A live namespace (`deployments/sepolia/`), its ad-hoc namespace
(`deployments/sepolia-adhoc/`) and dated archives
(`deployments/sepolia-<YYYYMMDD>-r<N>/`, `deployments/mainnet-redeploy-<YYYYMMDD>/`)
are therefore committed automatically — no allow-list entry needed. To deliberately keep a namespace local-only, name it
with a `-fork` / `-clean-` suffix or add a matching ignore line.
