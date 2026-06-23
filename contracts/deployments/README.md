# Deployments

Deployment artifacts written and read by [rocketh](https://github.com/wighawag/rocketh)
through the migration tooling ([`script/migration.ts`](../script/migration.ts),
[`docs/migration.md`](../docs/migration.md)). Each contract a deploy script
produces is recorded here as JSON so later runs and the phase commands can resolve
on-chain addresses without re-deploying.

## Layout

Artifacts are grouped into **namespaces**, one directory per deployment set:

```
deployments/
  README.md               # this file
  <namespace>/            # a single deployment set (v2 contracts)
    .chain                # { chainId, genesisHash } the set was deployed against
    .migrations.json      # rocketh's record of completed deploy scripts (id → unix-epoch-seconds)
    .deployment.json      # { environment, chainId, deployedAt } — when this set was first deployed
    <Contract>.json       # one file per deployed contract (address, abi, bytecode, receipt, …)
  v1/
    <network>/            # local v1-reference overrides (searched before the bundled set)
      .chainId            # chain id of the referenced v1 set
      <Contract>.json
```

The `.chain`, `.migrations.json`, and `.deployment.json` dotfiles are metadata;
rocketh loads only `.migrations.json` and the `<Contract>.json` artifacts and
ignores every other dotfile, so `.deployment.json` is never mistaken for a
contract. `.deployment.json` is written once, on the first deploy into a
namespace, so its `deployedAt` records the original deployment time and survives
idempotent re-runs.

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

## Namespace naming and `sepolia-official-v1-20260525-r2`

`sepolia-official-v1-20260525-r2` is the existing **v2** deployment on Sepolia
(chain `11155111`) — the name encodes that it was built against the official v1
references, dated `2026-05-25`, revision `r2`. Despite `v1` in the name its
contents are the v2 set (`ETHRegistry`, `ENSV2Resolver`, `ETHRegistrar`,
`UpgradableUniversalResolverProxy`, the migration controllers, …).

The date/revision suffix is deliberate: **a previous deployment is kept as a
standalone, immutable record** rather than being overwritten, and rocketh always
gets a clean folder to deploy into (see below). This folder predates the `--fresh`
flag and was named by hand; `--fresh` now produces the same shape automatically,
archiving the prior set to `<env>-<YYYYMMDD>-r<N>`.

Because this namespace is not the default (`sepolia`), routine commands and the
`fork full` rehearsal do not load it unless you pass
`--deployment-network sepolia-official-v1-20260525-r2`.

## Re-deploying: idempotent by default, `--fresh` to replace

rocketh deploys are idempotent against the namespace folder. A deploy script that
finds an artifact of the same name **reuses it instead of redeploying** (scripts
guard with `getOrNull(name) ?? deploy(name, …)`, and `.migrations.json` lets the
runner skip scripts that already completed). So pointing a second deploy at a
populated namespace does **not** produce fresh contracts — it reloads the existing
addresses and re-runs only the wiring around them. This is the default and is what
you want for resuming or re-verifying a deployment.

To deploy genuinely fresh, pass `--fresh` to `phase deploy-v2`:

```bash
bun run migration -- phase deploy-v2 --network sepolia --fresh
```

`--fresh` archives the current namespace out of the way and deploys into a clean
one:

- The existing `deployments/<env>/` is renamed to `deployments/<env>-<YYYYMMDD>-r<N>`,
  where the date is the archived deployment's `deployedAt` (from `.deployment.json`,
  falling back to the latest `.migrations.json` timestamp) and `<N>` auto-increments
  if a same-date archive already exists.
- A fresh deployment is then written into `deployments/<env>/` and a new
  `.deployment.json` is stamped.
- `--fresh` **implies `--save-deployments`** — archiving without persisting the
  replacement would be pointless, so it always saves.

This works identically for `--network mainnet` (the namespace defaults to the
network name). Manually moving or clearing the namespace directory first is
equivalent; `--fresh` just automates it with a dated archive name.

The persistent `UpgradableUniversalResolverProxy` entry point
(`0xeEeE…EeEe`) is fixed by constant and is never re-deployed; a fresh run
re-points it at the newly deployed managed URP during phase 7. The previous
namespace's contracts remain on-chain but become orphaned once the entry point
is cut over.

## Saving artifacts

The rehearsal (`fork full`) does not persist artifacts unless `--save-deployments`
is passed, so a fork run leaves `deployments/` untouched by default. A real deploy
that should be recorded must run with `--save-deployments` (or `--fresh`, which
implies it) and a deliberately chosen `--deployment-network`.

## Git tracking

`.gitignore` ignores everything under `deployments/` except this `README.md` and
an explicit allow-list of namespaces, so throwaway rehearsal and `--fresh` archive
runs do not clutter the repository:

```
deployments/*
!deployments/README.md
!deployments/sepolia-official-v1-20260525-r2/   # the tracked canonical v2 set
!deployments/v1/
deployments/v1/*
!deployments/v1/sepolia/                         # the tracked v1 references
```

To commit a new deployment (e.g. a fresh set, or an archived predecessor worth
keeping), add a matching `!deployments/<namespace>/` allow-list line. Everything
else stays local-only by design.
