# ENSv2 Dune Analytics Guide

This document explains how to query ENSv2 registration data on Dune for the `ens_v2_02042026` Sepolia deployment.

## Key Dune Queries

| Query | ID | Description |
|-------|----|-------------|
| All Names + Resolved Addresses + Method (3-level subnames) | [#6959375](https://dune.com/queries/6959375) | Full table: 2LDs + up to 3-level subnames with owner, ETH address, registration method |
| Decoded Table Sync Latency | [#6954236](https://dune.com/queries/6954236) | Measures lag between chain head and decoded tables |

## Architecture Overview

### ENSv2 Contract Addresses (Sepolia)

| Contract | Address | Role |
|----------|---------|------|
| RootRegistry | `0x3a3e15a5d27ff6f05c844313312f2e72096d3ed3` | Root of the registry tree |
| ETHRegistry | `0x796fff2e907449be8d5921bcc215b1b76d89d080` | Manages `.eth` 2LDs |
| ETHRegistrar | `0x68586418353b771cf2425ed14a07512aa880c532` | Commit-reveal registration for .eth names |
| UnlockedMigrationController | `0x76ae358d9ad91651b78463ae609dadc9e7ce4402` | V1→V2 migration |
| PermissionedResolverImpl | `0xe566a1fbaf30ff7c39828fe99f955fc55544cb9c` | Resolver implementation |
| UserRegistryImpl | `0xea93aff7375e8176053ab6ab36b57cab53cbf702` | Subregistry implementation |
| VerifiableFactory | `0x9240c5f31d747d60b3d9aed2f57995094342b1ed` | Deploys proxy contracts |
| ENSV2Resolver | `0x18cb116a1c88531a4bb2996e4fef136a31e11a80` | Universal resolver entry point |
| MockUSDC | `0x302edecc2b8d1f3f4625b8a825a42f9adc102e65` | Payment token (testnet) |

### Data Sources

ENSv2 data in Dune comes from two layers:

1. **Decoded tables** (`ens_v2_02042026_sepolia.*`) — ABI-decoded events from known contracts. Subject to indexing lag (can be days behind on Sepolia).
2. **Raw logs** (`sepolia.logs`) — Near real-time. Used for data not available in decoded tables (subname registrations, address records).

### Key Event Signatures

| Event | topic0 | Emitted By |
|-------|--------|------------|
| `LabelRegistered` | `0x2fe093918572373e9f1f0368f414dffd0043a74ae8c9fd7b0e390b26a0d20b6e` | ETHRegistry, UserRegistry |
| `SubregistryUpdated` | `0xca9c8d517128edd416adf5719242ca6ff93ce234442d95234da53c0ae8a10540` | ETHRegistry, UserRegistry |
| `AddressChanged` | `0x65412581168e88a1e60c6459d7f44ae83ad0832e670826c05a4e2476b57af752` | PermissionedResolver |
| `ProxyDeployed` | *(from VerifiableFactory)* | VerifiableFactory |

### Resolver Architecture

- The **PermissionedResolver** is a shared resolver per account (not per name).
- Address records are keyed by `namehash(fullName)`, so multiple names can share one resolver.
- The registry stores the resolver address per name; address records are set separately via `setAddr()`.
- `AddressChanged(bytes32 indexed node, uint256 coinType, bytes newAddress)` — only `node` is indexed. `coinType` and `newAddress` are ABI-encoded in `data`.

### Registration Methods

The `sender` field (topic3) in `LabelRegistered` identifies how a name was registered:

| Sender Address | Method |
|----------------|--------|
| `0x76ae358d9ad91651b78463ae609dadc9e7ce4402` | `migrated_from_v1` (UnlockedMigrationController) |
| `0x68586418353b771cf2425ed14a07512aa880c532` | `direct_v2` (ETHRegistrar) |
| `0x5bbaf30bb44dbf3e23e6df7bb4a73908ed1e68de` | `batch_registrar` (BatchRegistrar) |
| *(owner address on UserRegistry)* | `subname` |

## Query Logic: All Names + Owners + Resolved Addresses (3-level subnames)

The main query ([#6959375](https://dune.com/queries/6959375)) combines multiple data sources to produce a unified table. It supports `.eth` 2LDs and up to 3 levels of subnames (e.g. `a.b.c.parent.eth`).

### Step 1: Find all UserRegistry proxies

UserRegistry contracts are deployed via `VerifiableFactory` as UUPS proxies. We identify them by filtering `ProxyDeployed` events where the implementation matches `UserRegistryImpl`.

```sql
user_registries AS (
    SELECT substr(topic2, 13, 20) as registry_address
    FROM sepolia.logs
    WHERE contract_address = 0x9240c5f31d747d60b3d9aed2f57995094342b1ed  -- VerifiableFactory
      AND block_date >= DATE '2026-03-17'
      AND substr(data, 45, 20) = 0xea93aff7375e8176053ab6ab36b57cab53cbf702  -- UserRegistryImpl
)
```

### Step 2: Get .eth 2LD registrations from decoded table

Pull registered `.eth` names from the decoded `ethregistry_evt_labelregistered` table, and classify the registration method by the `sender` address.

```sql
eth_names AS (
    SELECT
        label, owner, tokenId, expiry,
        evt_block_time as registered_at,
        sender,
        contract_address as registry
    FROM ens_v2_02042026_sepolia.ethregistry_evt_labelregistered
)
```

### Step 3: Collect all SubregistryUpdated events

`SubregistryUpdated` events are emitted by **both** ETHRegistry and UserRegistries when a name sets its subregistry. We collect them from all relevant contracts to support multi-level subname chaining.

```sql
all_subregistry_updates AS (
    SELECT
        l.contract_address as parent_registry,
        bytearray_to_uint256(l.topic1) as tokenId,
        substr(topic2, 13, 20) as subregistry_address
    FROM sepolia.logs l
    WHERE l.block_date >= DATE '2026-03-17'
      AND l.topic0 = 0xca9c8d517128edd416adf5719242ca6ff93ce234442d95234da53c0ae8a10540
      AND (
          l.contract_address = 0x796fff2e907449be8d5921bcc215b1b76d89d080  -- ETHRegistry
          OR l.contract_address IN (SELECT registry_address FROM user_registries)
      )
)
```

### Step 4: Collect all subname LabelRegistered events from raw logs

Subnames are registered on UserRegistry contracts which are **not decoded** in Dune. We parse `LabelRegistered` events from raw logs.

The `LabelRegistered` event has:
- `topic1`: tokenId (indexed)
- `topic2`: labelHash (indexed)
- `topic3`: sender (indexed)
- `data`: ABI-encoded `(string label, address owner, uint64 expiry)`
  - bytes 1-32: offset to string (0x60 = 96)
  - bytes 33-64: owner (address, left-padded)
  - bytes 65-96: expiry (uint64, left-padded)
  - bytes 97-128: string length
  - bytes 129+: string bytes

```sql
all_subname_events AS (
    SELECT
        l.contract_address as registry,
        from_utf8(substr(l.data, 129,
            CAST(bytearray_to_uint256(substr(l.data, 97, 32)) AS integer))) as label,
        substr(l.data, 45, 20) as owner,
        bytearray_to_uint256(l.topic1) as tokenId,
        bytearray_to_uint256(substr(l.data, 65, 32)) as expiry,
        l.block_time as registered_at,
        substr(l.topic3, 13, 20) as sender
    FROM sepolia.logs l
    WHERE l.topic0 = 0x2fe093918572373e9f1f0368f414dffd0043a74ae8c9fd7b0e390b26a0d20b6e
      AND l.block_date >= DATE '2026-03-17'
      AND l.contract_address IN (SELECT registry_address FROM user_registries)
)
```

### Step 5: Build subname levels by chaining SubregistryUpdated joins

Each level joins the subname events with the `SubregistryUpdated` mapping to find the parent, then chains upward:

**Level 1** (`sub.parent.eth`): UserRegistry → SubregistryUpdated on ETHRegistry → eth_names

```sql
level1 AS (
    SELECT
        s.label,
        s.label || '.' || en.label || '.eth' as full_name,
        s.owner, s.tokenId, s.expiry, s.registered_at, s.sender, s.registry,
        en.label as parent_label,
        'subname_l1' as source
    FROM all_subname_events s
    JOIN all_subregistry_updates su ON su.subregistry_address = s.registry
    JOIN eth_names en ON en.tokenId = su.tokenId
    WHERE su.parent_registry = 0x796fff2e907449be8d5921bcc215b1b76d89d080
)
```

**Level 2** (`sub2.sub1.parent.eth`): UserRegistry → SubregistryUpdated on level1's UserRegistry → level1

```sql
level2 AS (
    SELECT
        s.label,
        s.label || '.' || l1.label || '.' || l1.parent_label || '.eth' as full_name,
        s.owner, s.tokenId, s.expiry, s.registered_at, s.sender, s.registry,
        l1.label as parent_label,
        l1.parent_label as grandparent_label,
        'subname_l2' as source
    FROM all_subname_events s
    JOIN all_subregistry_updates su ON su.subregistry_address = s.registry
    JOIN level1 l1 ON l1.tokenId = su.tokenId AND l1.registry = su.parent_registry
)
```

**Level 3** (`sub3.sub2.sub1.parent.eth`): Same pattern, chaining from level2.

```sql
level3 AS (
    SELECT
        s.label,
        s.label || '.' || l2.label || '.' || l2.parent_label
            || '.' || l2.grandparent_label || '.eth' as full_name,
        s.owner, s.tokenId, s.expiry, s.registered_at, s.sender, s.registry,
        'subname_l3' as source
    FROM all_subname_events s
    JOIN all_subregistry_updates su ON su.subregistry_address = s.registry
    JOIN level2 l2 ON l2.tokenId = su.tokenId AND l2.registry = su.parent_registry
)
```

### Step 6: Combine all levels

```sql
all_names AS (
    SELECT label, label || '.eth' as full_name, ..., 'eth_2ld' as source FROM eth_names
    UNION ALL
    SELECT label, full_name, ..., source FROM level1
    UNION ALL
    SELECT label, full_name, ..., source FROM level2
    UNION ALL
    SELECT label, full_name, ..., source FROM level3
)
```

### Step 7: Compute namehash

DuneSQL has a `keccak()` function. Namehash is computed iteratively — one `keccak(concat(...))` per label depth:

```
namehash("") = 0x00...00
namehash("eth") = keccak(namehash("") || keccak("eth"))
namehash("parent.eth") = keccak(namehash("eth") || keccak("parent"))
namehash("sub.parent.eth") = keccak(namehash("parent.eth") || keccak("sub"))
namehash("sub2.sub1.parent.eth") = keccak(namehash("sub1.parent.eth") || keccak("sub2"))
```

We use `split_part(full_name, '.', N)` to extract each label and nest `keccak()` calls per depth level:

```sql
names_with_hash AS (
    SELECT n.*,
        CASE n.source
            WHEN 'eth_2ld' THEN
                keccak(concat(eth_hash, keccak(to_utf8(label))))
            WHEN 'subname_l1' THEN
                keccak(concat(
                    keccak(concat(eth_hash, keccak(to_utf8(split_part(full_name, '.', 2))))),
                    keccak(to_utf8(label))
                ))
            WHEN 'subname_l2' THEN
                keccak(concat(
                    keccak(concat(
                        keccak(concat(eth_hash, keccak(to_utf8(split_part(full_name, '.', 3))))),
                        keccak(to_utf8(split_part(full_name, '.', 2)))
                    )),
                    keccak(to_utf8(label))
                ))
            WHEN 'subname_l3' THEN
                keccak(concat(
                    keccak(concat(
                        keccak(concat(
                            keccak(concat(eth_hash, keccak(to_utf8(split_part(full_name, '.', 4))))),
                            keccak(to_utf8(split_part(full_name, '.', 3)))
                        )),
                        keccak(to_utf8(split_part(full_name, '.', 2)))
                    )),
                    keccak(to_utf8(label))
                ))
        END as name_hash
    FROM all_names n
)
```

### Step 8: Join with AddressChanged events

Address records are set on PermissionedResolver contracts via `setAddr()`, which emits `AddressChanged`. The event data is:

- `topic0`: event signature
- `topic1`: node (namehash, indexed)
- `data`: ABI-encoded `(uint256 coinType, bytes newAddress)`
  - bytes 1-32: coinType (60 = ETH)
  - bytes 33-64: offset to bytes (0x40 = 64)
  - bytes 65-96: length of address bytes (20)
  - bytes 97-128: address bytes (left-aligned, 20 bytes + 12 zero padding)

We filter for `coinType = 60` (ETH) and take the latest event per node.

```sql
latest_addr AS (
    SELECT
        topic1 as node,
        contract_address as resolver_contract,
        substr(data, 97, 20) as resolved_address,
        block_time as addr_set_time,
        ROW_NUMBER() OVER (PARTITION BY topic1 ORDER BY block_time DESC) as rn
    FROM sepolia.logs
    WHERE topic0 = 0x65412581168e88a1e60c6459d7f44ae83ad0832e670826c05a4e2476b57af752
      AND block_date >= DATE '2026-03-17'
      AND bytearray_to_uint256(substr(data, 1, 32)) = 60
)
```

### Step 9: Final SELECT

Join names with their resolved addresses via the computed namehash. The `source` column indicates the depth level.

```sql
SELECT
    n.label as name,
    n.full_name,
    n.source,       -- eth_2ld, subname_l1, subname_l2, subname_l3
    n.reg_method,   -- migrated_from_v1, direct_v2, subname, etc.
    n.owner,
    la.resolver_contract as permissioned_resolver,
    la.resolved_address as eth_address,
    CASE 
        WHEN la.resolved_address IS NOT NULL 
             AND la.resolved_address != 0x0000000000000000000000000000000000000000
        THEN true ELSE false 
    END as has_eth_address,
    from_unixtime(CAST(n.expiry AS BIGINT)) as expiry_date,
    n.registered_at,
    la.addr_set_time as last_addr_update
FROM names_with_hash n
LEFT JOIN latest_addr la
    ON la.node = n.name_hash AND la.rn = 1
ORDER BY n.registered_at DESC
```

## Limitations

- **Decoded table lag**: The `ens_v2_02042026_sepolia.*` decoded tables can be days behind the chain head. Use [query #6954236](https://dune.com/queries/6954236) to check current lag.
- **Subname depth**: The current query supports up to 3 levels of subnames (`a.b.c.parent.eth`). Deeper subnames would require additional level CTEs and nested `keccak()` calls. DuneSQL supports `WITH RECURSIVE` which could enable arbitrary depth in the future.
- **V1 names**: Names registered only on ENS V1 do not appear in this query. They must be migrated via `UnlockedMigrationController` or `LockedMigrationController` to show up.
- **PermissionedResolver not decoded**: Address records come from raw `AddressChanged` events in `sepolia.logs`, not from decoded tables.

## Related Scripts

| Script | Purpose |
|--------|---------|
| `contracts/script/registerV2.ts` | Register a .eth name directly on V2 (commit-reveal + resolver + addr record) |
| `contracts/script/registerSubnameV2.ts` | Register a subname under an existing .eth name (deploys UserRegistry if needed) |
