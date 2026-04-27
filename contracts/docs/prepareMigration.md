# ENS Prepare-Migration Script

## Overview

The prepare-migration script (`contracts/script/prepareMigration.ts`) rewires role grants on the `.eth` `PermissionedRegistry` to flip the registry from its **seeding** configuration (only `BatchRegistrar` can register names) to its **live** configuration (`ETHRegistrar` handles new registrations and renewals; `UnlockedMigrationController` and `LockedMigrationController` promote reserved names to registered as ENSv1 owners migrate in). `BatchRegistrar` retains no roles after this script runs — it is fully decommissioned on hand-off.

Run this once, after all pre-migration seeding via [`preMigration.ts`](./premigration.md) has completed and before opening registration traffic to users. The script is idempotent at the role level — re-running it against a registry that is already in the live configuration will show every planned op as already satisfied and simply broadcast the same grants/revokes again.

## Role changes

The script performs exactly four root-level role operations on the target registry:

| Target | Op | Roles | Expected prior state |
|---|---|---|---|
| `BatchRegistrar` | **REVOKE** | `ROLE_REGISTRAR` · `ROLE_REGISTRAR_ADMIN` · `ROLE_REGISTER_RESERVED` · `ROLE_REGISTER_RESERVED_ADMIN` · `ROLE_RENEW` · `ROLE_RENEW_ADMIN` | Holds `ROLE_REGISTRAR \| ROLE_RENEW` on a canonically-deployed registry. The four admin bits and `ROLE_REGISTER_RESERVED` are revoked defensively and are no-ops on a canonical deploy — they exist in the bitmap to guarantee the post-state is unambiguously "no roles" regardless of what the registry looked like going in. |
| `ETHRegistrar` | **GRANT** | `ROLE_REGISTRAR` · `ROLE_RENEW` | None of the granted bits. |
| `UnlockedMigrationController` | **GRANT** | `ROLE_REGISTER_RESERVED` | None of the granted bit. |
| `LockedMigrationController` | **GRANT** | `ROLE_REGISTER_RESERVED` | None of the granted bit. |

> **Note for devnet users.** The canonical devnet deploy scripts (`deploy/03_ETHRegistrar.ts`, `deploy/02_UnlockedMigrationController.ts`, `deploy/04_LockedMigrationController.ts`) *already* pre-grant the roles this script would otherwise grant, as a convenience for local dev. That means running this script against a fresh devnet will show every GRANT op as already satisfied and only the `BatchRegistrar` revoke will produce observable state change. The test fixture `revertPrePrepareMigrationRoles` in `test/utils/mockPrepareMigration.ts` undoes those pre-grants so the grant paths can be exercised end-to-end in the e2e tests.

For background on these roles and the EAC admin/base pairing used by registry contracts, see the [EAC section of the contracts README](../README.md#access-control) and [`RegistryRolesLib.sol`](../src/registry/libraries/RegistryRolesLib.sol).

### Why these specific roles

- `ROLE_REGISTRAR` is checked by `PermissionedRegistry.register()` when the entry is expired or never existed. `BatchRegistrar` seeds names via this path (`owner = address(0)`, entering the expired branch), so it holds the role during pre-migration. After hand-off, `ETHRegistrar` holds it to handle live new registrations.
- `ROLE_REGISTER_RESERVED` is checked by the same `register()` entry point when the entry is currently **reserved** (owner zero, not expired) and an actual owner is being set. This is the promotion path the migration controllers use to flip a pre-seeded reserved name into a registered name owned by its ENSv1 claimant — hence both controllers receive it here.
- `ROLE_RENEW` gates `PermissionedRegistry.renew()`. During pre-migration `BatchRegistrar` uses it to bump expiries on reserved names; afterwards the live renewal path runs through `ETHRegistrar.renew()` (see `src/registrar/ETHRegistrar.sol`), so the role moves from `BatchRegistrar` to `ETHRegistrar`.

## Prerequisites

- **Bun** runtime installed
- **Forge artifacts** compiled (`forge build` in `contracts/`) — the script loads the `PermissionedRegistry` ABI from `contracts/out/`
- **Deployed contracts:**
  - `PermissionedRegistry` (the `.eth` registry)
  - `BatchRegistrar` — currently holding the seeding roles
  - `ETHRegistrar` — will receive `ROLE_REGISTRAR`
  - `UnlockedMigrationController` — will receive `ROLE_REGISTER_RESERVED`
  - `LockedMigrationController` — will receive `ROLE_REGISTER_RESERVED`
- **Signer** holding the admin-role counterparts for every role being moved. In practice this means holding `ROLE_REGISTRAR_ADMIN`, `ROLE_REGISTER_RESERVED_ADMIN`, and `ROLE_RENEW_ADMIN` at the registry root. The script runs a pre-flight check against the signer's root roles and aborts with a clear error if any required admin bits are missing — no transactions are broadcast.
- **RPC endpoint** for the chain the registry is deployed on. The chain ID is auto-detected from the RPC.

`--execute` additionally requires `--private-key`; without it the script stays in dry-run mode.

## CLI Reference

Run from the `contracts/` directory:

```bash
bun run script/prepareMigration.ts [options]
```

### Required Options

| Option | Description |
|---|---|
| `--rpc-url <url>` | JSON-RPC endpoint for the target chain |
| `--registry <address>` | `.eth` `PermissionedRegistry` address |
| `--batch-registrar <address>` | `BatchRegistrar` address (roles revoked from this target) |
| `--eth-registrar <address>` | `ETHRegistrar` address (receives `ROLE_REGISTRAR`) |
| `--unlocked-migration-controller <address>` | `UnlockedMigrationController` address (receives `ROLE_REGISTER_RESERVED`) |
| `--locked-migration-controller <address>` | `LockedMigrationController` address (receives `ROLE_REGISTER_RESERVED`) |

### Optional

| Option | Default | Description |
|---|---|---|
| `--private-key <hex>` | — | Signer private key. Required when `--execute` is passed; enables the admin-role pre-flight check when running dry. |
| `--execute` | `false` | Broadcast transactions. Without this flag the script performs a dry run and never sends anything on-chain. |

## How It Works

1. **Parse CLI options** and build viem clients via `createV2Clients` in `scriptUtils.ts`. When no private key is supplied the script runs with a read-only public client.
2. **Load the `PermissionedRegistry` ABI** from the forge artifact under `contracts/out/`.
3. **Build the op list** — the fixed four-entry sequence shown in the [Role changes](#role-changes) table.
4. **Preview each op.** For every target the script reads the current root-role bitmap from the registry and prints it next to the planned change, so the diff is visible before anything is broadcast.
5. **Signer admin-role pre-flight** (when a signer is configured). The script computes the admin bits required for each planned grant/revoke and checks the signer's root roles on the registry. Any missing admin bit aborts the run with a description of which op needs which missing admin role.
6. **Dry-run exit.** If `--execute` is not set (or no wallet client is available) the script stops here after printing a "Dry run complete" summary.
7. **Execute.** If `--execute` is set, the script submits `grantRootRoles` / `revokeRootRoles` transactions sequentially, waiting for each receipt before moving on. After the last op it re-reads the role bitmap for every target and prints the final state.

## Dry Run vs. Execute

**Dry run is the default.** Running without `--execute` always produces the full preview — planned operations, the current on-chain state for every target, and (if a signer is supplied) the admin pre-flight result. No transactions are broadcast.

Passing `--execute` along with `--private-key` broadcasts the role changes. Transactions run **sequentially, one per op**, so an interruption part-way through leaves the registry in a partially-applied state. Re-running the script with `--execute` is safe: ops that have already been applied simply re-issue the same grant/revoke, and the preview will show the current state matching the desired state before each re-broadcast.

## Examples

### Dry run without a signer

Prints planned ops and current on-chain state for each target. No admin pre-flight (nothing to check against).

```bash
bun run script/prepareMigration.ts \
  --rpc-url https://v2-rpc.example.com \
  --registry 0x1234...abcd \
  --batch-registrar 0x5678...ef01 \
  --eth-registrar 0xaaaa...1111 \
  --unlocked-migration-controller 0xbbbb...2222 \
  --locked-migration-controller 0xcccc...3333
```

### Dry run with a signer (admin pre-flight)

Same preview, plus the pre-flight check that the signer holds every admin bit the execute phase would need.

```bash
bun run script/prepareMigration.ts \
  --rpc-url https://v2-rpc.example.com \
  --registry 0x1234...abcd \
  --batch-registrar 0x5678...ef01 \
  --eth-registrar 0xaaaa...1111 \
  --unlocked-migration-controller 0xbbbb...2222 \
  --locked-migration-controller 0xcccc...3333 \
  --private-key 0xabc...def
```

### Execute

Broadcasts the full role swap. Prints the final on-chain role state for every target on completion.

```bash
bun run script/prepareMigration.ts \
  --rpc-url https://v2-rpc.example.com \
  --registry 0x1234...abcd \
  --batch-registrar 0x5678...ef01 \
  --eth-registrar 0xaaaa...1111 \
  --unlocked-migration-controller 0xbbbb...2222 \
  --locked-migration-controller 0xcccc...3333 \
  --private-key 0xabc...def \
  --execute
```
