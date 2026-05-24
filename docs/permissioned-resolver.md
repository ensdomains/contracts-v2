# PermissionedResolver

A resolver that supports many profiles, multiple names, internal aliasing, and fine-grained permissions.

**Contract**: `contracts/src/resolver/PermissionedResolver.sol`
**Interface**: `contracts/src/resolver/interfaces/IPermissionedResolver.sol`

## Overview

The PermissionedResolver stores ENS records (addresses, text, contenthash, etc.) and controls write access through a resource-based role system (Enhanced Access Control). It also supports internal aliasing, where one DNS-encoded name can redirect to another.

The `IPermissionedResolver` interface defines the resolver-specific events (`AliasChanged`), errors (`UnsupportedResolverProfile`, `InvalidEVMAddress`, `InvalidContentType`), and functions (`initialize`, `setAlias`, `getAlias`). It extends `IExtendedResolver` and `IEnhancedAccessControl`.

Supported profiles and standards: ENSIP-1/EIP-137 (addr), ENSIP-3/EIP-181 (name), ENSIP-4/EIP-205 (ABI), EIP-619 (pubkey), ENSIP-5/EIP-634 (text), ENSIP-7/EIP-1577 (contenthash), ENSIP-8 (interfaceImplementer), ENSIP-9/EIP-2304 (addr with coinType), ENSIP-19 (addr default), IERC7996 (supportsFeature), IVersionableResolver (version), IHasAddrResolver (hasAddr).

## Read Methods — Records

Records are keyed by `(node, version)` where `node` is a namehash and `version` is auto-incremented when records are cleared.

| Method | Signature | Description |
|---|---|---|
| `addr(bytes32 node)` | `→ address payable` | ETH address for a node |
| `addr(bytes32 node, uint256 coinType)` | `→ bytes` | Address for any coin type (ENSIP-19 fallback to default) |
| `hasAddr(bytes32 node, uint256 coinType)` | `→ bool` | Whether an address record exists |
| `text(bytes32 node, string key)` | `→ string` | Text record by key |
| `name(bytes32 node)` | `→ string` | Primary name (reverse resolution) |
| `contenthash(bytes32 node)` | `→ bytes` | Content hash |
| `ABI(bytes32 node, uint256 contentTypes)` | `→ (uint256, bytes)` | ABI data |
| `pubkey(bytes32 node)` | `→ (bytes32 x, bytes32 y)` | SECP256k1 public key |
| `interfaceImplementer(bytes32 node, bytes4 iface)` | `→ address` | Interface implementer |
| `recordVersions(bytes32 node)` | `→ uint64` | Current record version |
| `resolve(bytes name, bytes data)` | `→ bytes` | Extended resolution (handles aliasing + multicall) |

None of these are enumerable. Discovery of all populated nodes/keys requires indexing events.

## Read Methods — Aliases

```solidity
getAlias(bytes memory fromName) → bytes memory toName
```

- `setAlias(fromName, toName)` stores `aliases[namehash(fromName)] = toName`.
- `getAlias` walks the name suffix-first, finds the longest matching alias, applies it, and recursively follows chains (cycle-safe for length 1).
- Returns empty bytes if no alias exists.

Aliases use DNS-encoded names (length-prefixed labels, e.g. `\x03eth\x00` = `eth`).

Not enumerable — index `AliasChanged` events to build a full picture.

## Read Methods — Roles

The PermissionedResolver inherits from `EnhancedAccessControl`, which provides a 2-dimensional role system: **resource** × **account**.

### Querying roles

| Method | Signature | Description |
|---|---|---|
| `roles(uint256 resource, address account)` | `→ uint256` | Full role bitmap for an account on a resource |
| `hasRoles(uint256 resource, uint256 rolesBitmap, address account)` | `→ bool` | Check specific roles (also checks ROOT_RESOURCE fallback) |
| `hasRootRoles(uint256 rolesBitmap, address account)` | `→ bool` | Check roles on ROOT_RESOURCE (global) |
| `roleCount(uint256 resource)` | `→ uint256` | Role count bitmap for a resource |
| `getAssigneeCount(uint256 resource, uint256 roleBitmap)` | `→ (uint256 counts, uint256 mask)` | Assignee counts per role |
| `hasAssignees(uint256 resource, uint256 roleBitmap)` | `→ bool` | Whether any role has assignees |

### Computing the `resource` parameter

Resources are computed from `PermissionedResolverLib.resource(node, part)` = `keccak256(node, part)`:

| Scope | Resource |
|---|---|
| Global (any name, any part) | `0` (ROOT_RESOURCE) |
| Specific name, any part | `resource(namehash, 0)` |
| Any name, specific part | `resource(0, part)` |
| Specific name + specific part | `resource(namehash, part)` |

Where `part` is:
- `0` — any record type
- `addrPart(coinType)` = `keccak256(0x01 ++ coinType)` — specific coin type
- `textPart(key)` = `keccak256(0x02 ++ keccak256(key))` — specific text key

### Role constants

Defined in `PermissionedResolverLib` (`contracts/src/resolver/libraries/PermissionedResolverLib.sol`):

| Role | Bit | Value | Admin (bit + 128) |
|---|---|---|---|
| `ROLE_SET_ADDR` | 0 | `1 << 0` | `1 << 128` |
| `ROLE_SET_TEXT` | 4 | `1 << 4` | `1 << 132` |
| `ROLE_SET_CONTENTHASH` | 8 | `1 << 8` | `1 << 136` |
| `ROLE_SET_PUBKEY` | 12 | `1 << 12` | `1 << 140` |
| `ROLE_SET_ABI` | 16 | `1 << 16` | `1 << 144` |
| `ROLE_SET_INTERFACE` | 20 | `1 << 20` | `1 << 148` |
| `ROLE_SET_NAME` | 24 | `1 << 24` | `1 << 152` |
| `ROLE_SET_ALIAS` | 28 | `1 << 28` | `1 << 156` |
| `ROLE_CLEAR` | 32 | `1 << 32` | `1 << 160` |
| `ROLE_UPGRADE` | 124 | `1 << 124` | `1 << 252` |

Not enumerable by account — you cannot list "all accounts with roles on resource X". Index `EACRolesChanged` events.

## Granting Roles

The raw `grantRoles(resource, roleBitmap, account)` function is **disabled** — calling it always reverts with `EACCannotGrantRoles`. Instead, use the typed grant functions that accept DNS-encoded names:

### `grantNameRoles(bytes toName, uint256 roleBitmap, address account)`

Grants roles for a specific name. Pass `NameCoder.encode("")` (DNS-encoded empty string = `0x00`) for any name, which is equivalent to `grantRootRoles()`.

- **Authorization**: caller must be able to grant roles on `resource(namehash(toName), 0)`
- **Event**: `NamedResource(resource, toName)` + `EACRolesChanged(...)`

### `grantTextRoles(bytes toName, string key, address account)`

Grants `ROLE_SET_TEXT` for a specific text `key` on a name.

- **Authorization**: caller must have `ROLE_SET_TEXT` admin on `resource(namehash(toName), 0)`
- **Event**: `NamedTextResource(resource, toName, keccak256(key), key)` + `EACRolesChanged(...)`

### `grantAddrRoles(bytes toName, uint256 coinType, address account)`

Grants `ROLE_SET_ADDR` for a specific `coinType` on a name.

- **Authorization**: caller must have `ROLE_SET_ADDR` admin on `resource(namehash(toName), 0)`
- **Event**: `NamedAddrResource(resource, toName, coinType)` + `EACRolesChanged(...)`

## Indexer Events

To fully reconstruct PermissionedResolver state, an indexer must capture these 14 event types:

### Record events

| Event | Signature | Emitted by |
|---|---|---|
| `AddrChanged(bytes32 indexed node, address a)` | Legacy ETH address | `setAddr(node, addr)` |
| `AddressChanged(bytes32 indexed node, uint256 coinType, bytes newAddress)` | Any coin address | `setAddr(node, coinType, bytes)` |
| `TextChanged(bytes32 indexed node, string indexed indexedKey, string key, string value)` | Text record | `setText` |
| `ContenthashChanged(bytes32 indexed node, bytes hash)` | Content hash | `setContenthash` |
| `NameChanged(bytes32 indexed node, string name)` | Primary name | `setName` |
| `ABIChanged(bytes32 indexed node, uint256 indexed contentType)` | ABI data (no data in event) | `setABI` |
| `PubkeyChanged(bytes32 indexed node, bytes32 x, bytes32 y)` | Public key | `setPubkey` |
| `InterfaceChanged(bytes32 indexed node, bytes4 indexed interfaceID, address implementer)` | Interface impl | `setInterface` |
| `VersionChanged(bytes32 indexed node, uint64 newVersion)` | Records cleared | `clearRecords` |

### Alias events

| Event | Signature | Emitted by |
|---|---|---|
| `AliasChanged(bytes indexed indexedFromName, bytes indexed indexedToName, bytes fromName, bytes toName)` | Alias set | `setAlias` |

### Role events

| Event | Signature | Emitted by |
|---|---|---|
| `EACRolesChanged(uint256 indexed resource, address indexed account, uint256 oldRoleBitmap, uint256 newRoleBitmap)` | Role grant/revoke | `grantNameRoles`, `grantTextRoles`, `grantAddrRoles`, `revokeRoles`, `revokeRootRoles` |

### Resource mapping events (new)

These events map opaque EAC resource IDs back to human-readable names and record types. Essential for indexers to decode what a resource ID refers to.

| Event | Signature | Emitted by |
|---|---|---|
| `NamedResource(uint256 indexed resource, bytes name)` | Resource → name mapping | `grantNameRoles` |
| `NamedTextResource(uint256 indexed resource, bytes name, bytes32 indexed keyHash, string key)` | Resource → name + text key | `grantTextRoles` |
| `NamedAddrResource(uint256 indexed resource, bytes name, uint256 indexed coinType)` | Resource → name + coin type | `grantAddrRoles` |

### Notes

- `AddrChanged` and `AddressChanged` fire together for ETH addresses — deduplicate or prefer `AddressChanged`.
- `ABIChanged` does not include the ABI data — the indexer needs an RPC call to `ABI(node, contentType)` or must parse calldata.
- `VersionChanged` means all records for that node are wiped (new version = clean slate).
- `AliasChanged` names are DNS-encoded wire format; decode to dotted names for display.
- `EACRolesChanged` with `resource = 0` is a ROOT_RESOURCE (global) change.
- `NamedResource` / `NamedTextResource` / `NamedAddrResource` let indexers associate a resource ID with its DNS-encoded name (and optionally key or coinType) without recomputing the hash.

## Example GraphQL Query

```graphql
query PermissionedResolverState($resolver: String!) {
  domains(where: { resolver: $resolver }) {
    node
    version
    records {
      addresses { coinType, value }
      texts { key, value }
      contenthash
      name
      pubkey { x, y }
      interfaces { interfaceId, implementer }
    }
  }

  aliases(where: { resolver: $resolver }) {
    fromName
    toName
  }

  roleAssignments(where: { resolver: $resolver }) {
    resource
    account
    roleBitmap
    namedResource {
      name
      key
      coinType
    }
  }
}
```

## Example Transaction History Query

```graphql
query ResolverHistory($resolver: String!, $first: Int, $skip: Int) {
  resolverEvents(
    where: { resolver: $resolver }
    orderBy: blockNumber
    orderDirection: desc
    first: $first
    skip: $skip
  ) {
    transactionHash
    blockNumber
    blockTimestamp
    sender
    eventType        # ADDR_CHANGED | ADDRESS_CHANGED | TEXT_CHANGED | ...
    node
    coinType
    newAddress
    key
    value
    hash
    name
    contentType
    x
    y
    interfaceId
    implementer
    newVersion
    fromName
    toName
    resource
    account
    oldRoleBitmap
    newRoleBitmap
  }
}
```
