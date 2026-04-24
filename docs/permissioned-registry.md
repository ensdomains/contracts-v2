# PermissionedRegistry

A tokenized (ERC1155) registry with resource-scoped access control for managing names at one level of the ENS hierarchy.

**Contract**: `contracts/src/registry/PermissionedRegistry.sol`
**Interfaces**: `IPermissionedRegistry`, `IStandardRegistry`, `IRegistry`, `IEnhancedAccessControl`, `IERC1155Singleton`

## Overview

Every level of the ENS v2 name hierarchy is a `PermissionedRegistry`. The RootRegistry, ETHRegistry, and every UserRegistry for subnames are all instances of this contract (or inherit from it). Each registry:

- Manages one level of labels (e.g., the ETHRegistry manages `*.eth` labels)
- Stores metadata per label: subregistry, resolver, expiry
- Mints an ERC1155 token per registered name (ownership = name ownership)
- Controls access through the Enhanced Access Control (EAC) system

## The Three IDs: `anyId`

Every name in a registry can be referenced by three different identifiers. Most functions accept any of them as the `anyId` parameter:

```
labelhash = keccak256("example")

resource  = LibLabel.withVersion(labelhash, eacVersionId)
            ↑ stable for the lifetime of a registration
            ↑ changes on unregister/re-register (eacVersionId bumps)

tokenId   = LibLabel.withVersion(labelhash, tokenVersionId)
            ↑ changes on unregister, re-register, AND role changes
            ↑ the actual ERC1155 token identifier
```

| ID | Stable across role changes? | Stable across re-registration? | Primary use |
|---|---|---|---|
| **Labelhash** | Yes | Yes | Registration, unregistration, general queries |
| **Resource** | Yes | No | EAC role management, stable identifier for indexers |
| **Token ID** | No | No | ERC1155 ownership, transfer, `ownerOf()` |

Internally, `_entry(anyId)` zeroes the version bits via `LibLabel.withVersion(anyId, 0)` to resolve any of these to the canonical storage slot.

### Why token ID changes

When roles are granted or revoked on a name, the registry **regenerates** the ERC1155 token: it burns the old token and mints a new one with an incremented `tokenVersionId`. This prevents a scenario where someone revokes a role then immediately transfers the token — the new token ID ensures the transfer targets the correct permission state.

The `resource` stays stable so that role assignments remain valid.

## Entry Struct

Each registered label stores:

```solidity
struct Entry {
    uint32 eacVersionId;     // access control version (bumped on unregister)
    uint32 tokenVersionId;   // token version (bumped on unregister + role changes)
    IRegistry subregistry;   // child registry for subnames
    uint64 expiry;           // timestamp at or after which the name expires
    address resolver;        // resolver contract for this name
}
```

## State and Status

### `Status` enum

```solidity
enum Status {
    AVAILABLE,   // name doesn't exist or is expired
    RESERVED,    // name is locked but has no owner (no ERC1155 token)
    REGISTERED   // name has an owner with an ERC1155 token
}
```

### `State` struct

The full state of a label, returned by `getState()`:

```solidity
struct State {
    Status status;       // AVAILABLE, RESERVED, or REGISTERED
    uint64 expiry;       // expiry timestamp
    address latestOwner; // owner address (or zero)
    uint256 tokenId;     // current ERC1155 token ID
    uint256 resource;    // current EAC resource ID
}
```

## Read Methods

### State queries

| Method | Signature | Description |
|---|---|---|
| `getState(uint256 anyId)` | `→ State` | Full state: status, expiry, owner, tokenId, resource |
| `getStatus(uint256 anyId)` | `→ Status` | Registration status only |
| `getExpiry(uint256 anyId)` | `→ uint64` | Expiry timestamp |
| `getResource(uint256 anyId)` | `→ uint256` | Current EAC resource ID |
| `getTokenId(uint256 anyId)` | `→ uint256` | Current ERC1155 token ID |
| `latestOwnerOf(uint256 tokenId)` | `→ address` | Token owner (even if expired or burned) |
| `ownerOf(uint256 tokenId)` | `→ address` | Token owner; returns `address(0)` if expired or wrong tokenVersionId |

### Registry tree queries

| Method | Signature | Description |
|---|---|---|
| `getSubregistry(string label)` | `→ IRegistry` | Child registry for a label; `address(0)` if expired |
| `getResolver(string label)` | `→ address` | Resolver for a label; `address(0)` if expired |
| `getParent()` | `→ (IRegistry, string)` | Parent registry and this registry's label in the parent |

### Role queries

All EAC role query functions accept `anyId` and resolve to the resource internally:

| Method | Signature | Description |
|---|---|---|
| `roles(uint256 anyId, address account)` | `→ uint256` | Full role bitmap for an account on a name |
| `hasRoles(uint256 anyId, uint256 roleBitmap, address account)` | `→ bool` | Check specific roles (includes ROOT_RESOURCE fallback) |
| `hasRootRoles(uint256 roleBitmap, address account)` | `→ bool` | Check roles on ROOT_RESOURCE (global) |
| `roleCount(uint256 anyId)` | `→ uint256` | Assignee count bitmap for a name |
| `getAssigneeCount(uint256 anyId, uint256 roleBitmap)` | `→ (uint256, uint256)` | Per-role assignee counts |
| `hasAssignees(uint256 anyId, uint256 roleBitmap)` | `→ bool` | Whether any role has assignees |

## Write Methods

### Name lifecycle

| Method | Role required | Description |
|---|---|---|
| `register(label, owner, registry, resolver, roleBitmap, expiry)` | `ROLE_REGISTRAR` (root) or `ROLE_REGISTER_RESERVED` (root, for RESERVED→REGISTERED) | Register or reserve a label |
| `unregister(uint256 anyId)` | `ROLE_UNREGISTER` (root or token) | Delete a label, burn token, expire immediately |
| `renew(uint256 anyId, uint64 newExpiry)` | `ROLE_RENEW` (root or token) | Extend expiry (cannot reduce) |
| `setSubregistry(uint256 anyId, IRegistry)` | `ROLE_SET_SUBREGISTRY` (root or token) | Change child registry |
| `setResolver(uint256 anyId, address)` | `ROLE_SET_RESOLVER` (root or token) | Change resolver |
| `setParent(IRegistry, string)` | `ROLE_SET_PARENT` (root only) | Set parent registry reference |

### Role management

| Method | Description |
|---|---|
| `grantRoles(uint256 anyId, uint256 roleBitmap, address account)` | Grant roles on a name's resource (resolves `anyId` to resource) |
| `revokeRoles(uint256 anyId, uint256 roleBitmap, address account)` | Revoke roles on a name's resource |
| `grantRootRoles(uint256 roleBitmap, address account)` | Grant roles on ROOT_RESOURCE (global) |
| `revokeRootRoles(uint256 roleBitmap, address account)` | Revoke roles on ROOT_RESOURCE |

## ERC1155 Token Model

Each registered name is an ERC1155 token (`ERC1155Singleton` — supply of 1 per token ID).

### Ownership

- `ownerOf(tokenId)` returns the owner, but only if the token ID matches the current `tokenVersionId` and the name is not expired. Otherwise returns `address(0)`.
- `latestOwnerOf(tokenId)` returns the owner without expiry or version checks (useful for burned/expired tokens).

### Transfers

Transfers via `safeTransferFrom()` require `ROLE_CAN_TRANSFER_ADMIN` on the **token owner** (not the operator). On transfer, all roles on the name's resource are moved from the old owner to the new owner.

### Token regeneration

When roles change (grant or revoke), the token is regenerated:

1. Burn old token (`TransferSingle` with `to = address(0)`)
2. Increment `tokenVersionId`
3. Mint new token (`TransferSingle` with `from = address(0)`)
4. Emit `TokenRegenerated(oldTokenId, newTokenId)`

The `resource` stays the same. Indexers should use `resource` as the stable identifier and track `TokenRegenerated` to update the tokenId mapping.

## Registry Roles

Defined in `RegistryRolesLib` (`contracts/src/registry/libraries/RegistryRolesLib.sol`):

| Role | Nybble | Bit shift | Scope | Description |
|---|---|---|---|---|
| `ROLE_REGISTRAR` | 0 | `1 << 0` | Root only | Register and reserve labels |
| `ROLE_REGISTER_RESERVED` | 1 | `1 << 4` | Root only | Promote RESERVED to REGISTERED |
| `ROLE_SET_PARENT` | 2 | `1 << 8` | Root only | Set parent registry |
| `ROLE_UNREGISTER` | 3 | `1 << 12` | Root or token | Delete labels |
| `ROLE_RENEW` | 4 | `1 << 16` | Root or token | Extend expiry |
| `ROLE_SET_SUBREGISTRY` | 5 | `1 << 20` | Root or token | Change subregistry |
| `ROLE_SET_RESOLVER` | 6 | `1 << 24` | Root or token | Change resolver |
| `ROLE_CAN_TRANSFER_ADMIN` | 7 | `(1 << 28) << 128` | Root or token | Transfer ERC1155 token (admin-only, no regular role) |
| `ROLE_UPGRADE` | 31 | `1 << 124` | Root only | Upgrade registry implementation |

"Root only" means the role is only checked on `ROOT_RESOURCE`. "Root or token" means the role can be held globally (root) or on a specific name's resource.

`ROLE_CAN_TRANSFER_ADMIN` is special: it exists only as an admin role (nybble 7 in the upper half). There is no corresponding regular role. It's checked on the token owner, not the operator.

## Role Restrictions

The registry overrides the base EAC to enforce stricter rules:

### `_getSettableRoles` (what can be granted)

| Resource | Behavior |
|---|---|
| `ROOT_RESOURCE` | Full EAC behavior (admin roles can grant both regular + admin) |
| Token resource (REGISTERED) | Admin bits are stripped — only regular roles can be granted post-registration. Admin roles are assigned only at `register()` time. |
| Token resource (AVAILABLE/RESERVED) | Returns 0 — no roles can be granted to unregistered labels |

### `_getRevokableRoles` (what can be revoked)

| Resource | Behavior |
|---|---|
| `ROOT_RESOURCE` | Full EAC behavior |
| Token resource (REGISTERED) | Full EAC behavior (admin roles can revoke both regular + admin) |
| Token resource (AVAILABLE/RESERVED) | Returns 0 — no roles can be revoked from unregistered labels |

## Expiry Behavior

- A name is `AVAILABLE` when `block.timestamp >= expiry`
- `getSubregistry()` and `getResolver()` return `address(0)` for expired names
- `ownerOf()` returns `address(0)` for expired names
- Expired names can be re-registered (new `eacVersionId`, new `tokenVersionId`, fresh permission scope)
- The `resource` changes on re-registration because `eacVersionId` increments

## Events

| Event | When |
|---|---|
| `LabelRegistered(tokenId, labelHash, label, owner, expiry, sender)` | `register()` with owner |
| `LabelReserved(tokenId, labelHash, label, expiry, sender)` | `register()` with owner=0 |
| `LabelUnregistered(tokenId, sender)` | `unregister()` |
| `ExpiryUpdated(tokenId, newExpiry, sender)` | `renew()` |
| `SubregistryUpdated(tokenId, subregistry, sender)` | `setSubregistry()` or during `register()` |
| `ResolverUpdated(tokenId, resolver, sender)` | `setResolver()` or during `register()` |
| `TokenRegenerated(oldTokenId, newTokenId)` | Role grant/revoke triggers token regeneration |
| `TokenResource(tokenId, resource)` | `register()` — maps tokenId to stable resource |
| `ParentUpdated(parent, label, sender)` | `setParent()` |
| `EACRolesChanged(resource, account, oldRoleBitmap, newRoleBitmap)` | Any role grant/revoke |
| `TransferSingle(operator, from, to, id, value)` | ERC1155 mint, burn, or transfer |

## Errors

| Error | When |
|---|---|
| `LabelAlreadyRegistered(label)` | Trying to overwrite a REGISTERED name |
| `LabelAlreadyReserved(label)` | Trying to reserve an already RESERVED name |
| `LabelExpired(tokenId)` | Operating on an expired name |
| `CannotReduceExpiry(oldExpiry, newExpiry)` | `renew()` with a smaller expiry |
| `CannotSetPastExpiry(expiry)` | `register()` with an already-past expiry |
| `TransferDisallowed(tokenId, from)` | Transfer without `ROLE_CAN_TRANSFER_ADMIN` |

## Code Examples (viem / TypeScript)

### Query full state

```typescript
import { keccak256, toHex } from "viem";

const labelHash = keccak256(toHex("example"));

const state = await publicClient.readContract({
  address: registryAddress,
  abi: [{
    name: 'getState',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'anyId', type: 'uint256' }],
    outputs: [{
      type: 'tuple',
      components: [
        { name: 'status', type: 'uint8' },
        { name: 'expiry', type: 'uint64' },
        { name: 'latestOwner', type: 'address' },
        { name: 'tokenId', type: 'uint256' },
        { name: 'resource', type: 'uint256' },
      ],
    }],
  }],
  functionName: "getState",
  args: [labelHash],
});

// state.status: 0 = AVAILABLE, 1 = RESERVED, 2 = REGISTERED
// state.expiry: unix timestamp
// state.latestOwner: owner address
// state.tokenId: current ERC1155 token ID
// state.resource: stable EAC resource ID
```

### Check roles on a name

```typescript
const hasRole = await publicClient.readContract({
  address: registryAddress,
  abi: [{
    name: 'hasRoles',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'anyId', type: 'uint256' },
      { name: 'roleBitmap', type: 'uint256' },
      { name: 'account', type: 'address' },
    ],
    outputs: [{ type: 'bool' }],
  }],
  functionName: "hasRoles",
  args: [labelHash, 1n << 20n, myAddress],  // ROLE_SET_SUBREGISTRY
});
```

### Grant roles on a name

```typescript
await walletClient.writeContract({
  address: registryAddress,
  abi: [{
    name: 'grantRoles',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'anyId', type: 'uint256' },
      { name: 'roleBitmap', type: 'uint256' },
      { name: 'account', type: 'address' },
    ],
    outputs: [{ type: 'bool' }],
  }],
  functionName: "grantRoles",
  args: [labelHash, 1n << 24n, otherAddress],  // ROLE_SET_RESOLVER
});
```

## Related

- [Access Control](./access-control.md) — The EAC system that underpins the registry's permission model
- [Name Registration](./name-registration.md) — Registration flow and concepts
- [Subnames](./subnames.md) — Managing subnames in child registries
- [Unregistering Names](./unregistering-names.md) — Deleting names
