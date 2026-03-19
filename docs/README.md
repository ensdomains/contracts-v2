# ENS Contracts V2 — Documentation

Reference documentation for the ENS V2 contract system.

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
- [Subnames](./subnames.md) — Creating, managing, reserving, and deleting subnames: the full subname lifecycle.
- [Unregistering Names](./unregistering-names.md) — How to delete subnames using `IStandardRegistry.unregister()`.
- [Name Renewal](./name-renewal.md) — Extending expiry for `.eth` names and subnames: pricing, roles, and batch renewal.

### Migration
- [Migrating v1 Names](./migrating-v1-names.md) — Pre-migration, unlocked migration, locked migration, fuse-to-role mapping, and WrapperRegistry.

### Indexing
- [Indexing ENSv2 Events](./indexing-ensv2-events.md) — Complete event reference for building an indexer: registry, resolver, registrar, and access control events.
- [Indexing Test Names](./indexing-test-names.md) — Test data reference: what the devnet test script creates and which events to expect.
