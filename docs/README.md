# ENS Contracts V2 — Documentation

Reference documentation for the ENS V2 contract system.

> **Last updated:** 2026-02-26 — synced to contract commit `9e5b67d3` (`add StrictERC1155Holder`).
> If new features have been merged since this date, re-run the documentation update process to catch contract changes.

## Contents

### Getting Started
- [Names and Nodes](./names-and-nodes.md) — The difference between names, nodes, labelhashes, and DNS encoding.
- [Name Registration](./name-registration.md) — What are registries, resolvers, and registrars? How the name hierarchy works and how to register a name.
- [ETH Registrar](./eth-registrar.md) — The commit-reveal flow for `.eth` names: payment, pricing, and the full registration lifecycle.

### Resolution
- [Forward Resolution](./forward-resolution.md) — How names resolve to records: the registry tree walk, UniversalResolverV2, wildcards, and CCIP-Read.
- [Reverse Resolution](./reverse-resolution.md) — How addresses resolve back to names: the reverse registrar, `nameForAddr()`, and bidirectional verification.
- [Setting a Primary Name](./primary-name.md) — Two-step setup for primary names: forward record + reverse mapping, signature-based claims, and clearing.

### Resolver
- [PermissionedResolver](./permissioned-resolver.md) — Resolver architecture, read methods, roles, aliases, records, and indexer events.
- [Setting Records](./setting-records.md) — How to create, update, and clear records: write methods, authorization model, roles, batching, and storage layout.
- [Aliases](./aliases.md) — Internal name aliasing: how to create, read, delete, and chain aliases with DNS-encoding examples.

### Registry Operations
- [PermissionedRegistry](./permissioned-registry.md) — Registry architecture: the anyId system, State struct, token regeneration, ERC1155 model, role restrictions, and read/write methods.
- [Subnames](./subnames.md) — Creating, managing, reserving, and deleting subnames: the full subname lifecycle.
- [Unregistering Names](./unregistering-names.md) — How to delete subnames using `IStandardRegistry.unregister()`.
- [Name Renewal](./name-renewal.md) — Extending expiry for `.eth` names and subnames: pricing, roles, and batch renewal.

### Access Control
- [Enhanced Access Control (EAC)](./access-control.md) — Bitmap layout, ROOT_RESOURCE fallback, admin mechanics, assignee counting, grant/revoke functions, events, errors, and how registry vs resolver use EAC differently.

### Migration
- [Migrating v1 Names](./migrating-v1-names.md) — Pre-migration, unlocked migration, locked migration, fuse-to-role mapping, and WrapperRegistry.

### Indexing
- [Indexing ENSv2 Events](./indexing-ensv2-events.md) — Complete event reference for building an indexer: registry, resolver, registrar, and access control events.
- [Indexing Test Names](./indexing-test-names.md) — Test data reference: what the devnet test script creates and which events to expect.
