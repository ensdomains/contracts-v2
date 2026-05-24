# Enhanced Access Control (EAC)

The role system that underpins both `PermissionedRegistry` and `PermissionedResolver`.

**Contract**: `contracts/src/access-control/EnhancedAccessControl.sol`
**Interface**: `contracts/src/access-control/interfaces/IEnhancedAccessControl.sol`
**Libraries**: `EACBaseRolesLib`, `RegistryRolesLib`, `PermissionedResolverLib`

## Overview

EAC is a resource-scoped, bitmap-packed access control system. It provides:

- **Resource-based roles**: each resource has independent role assignments
- **ROOT_RESOURCE fallback**: roles on resource `0` apply globally
- **Admin roles**: each role has a corresponding admin role for delegation
- **Assignee counting**: tracks how many accounts hold each role (max 15)
- **Callbacks**: subclasses react to role changes (e.g. token regeneration in registry)

## Bitmap Layout

Roles are packed into a `uint256` bitmap with 64 nybbles (4 bits each):

```
Bit position:
255         128 127            0
┌──────────────┬───────────────┐
│ Admin Roles  │ Regular Roles │
│ (32 nybbles) │ (32 nybbles)  │
└──────────────┴───────────────┘
Nybble index:
63           32 31             0
```

Each role occupies one nybble (4 bits). A regular role at nybble index N occupies bits `N*4` to `N*4+3`, and its admin counterpart is at bits `N*4+128` to `N*4+131`.

### Defining roles

```solidity
uint256 constant MY_ROLE       = 1 << (N * 4);       // regular role at nybble N
uint256 constant MY_ROLE_ADMIN = MY_ROLE << 128;      // admin role at nybble N+32
```

### Why nybbles?

Each nybble holds a 4-bit value (0–15). The same layout is reused for assignee counting: in the `roleCount` bitmap, each nybble tracks how many accounts hold that role within a resource. This is why the maximum is 15 assignees per role.

### Key masks

Defined in `EACBaseRolesLib`:

| Constant | Value | Description |
|---|---|---|
| `ALL_ROLES` | `0x1111...1111` (64 nybbles) | Bit 0 of every nybble set — represents one unit in each role slot |
| `ADMIN_ROLES` | `0x1111...0000` (upper 32 nybbles only) | Masks just the 32 admin role slots |

## Resources

A resource is an arbitrary `uint256` identifier whose meaning is defined by the subclass:

- **Registry**: uses labelhash-derived IDs (`LibLabel.withVersion(labelhash, eacVersionId)`) — one resource per name
- **Resolver**: uses `keccak256(node, part)` — resources scoped to both name and record type

### `ROOT_RESOURCE` (0)

Resource `0` is special. Roles granted on `ROOT_RESOURCE` apply to **all** resources automatically:

```solidity
function hasRoles(uint256 resource, uint256 roleBitmap, address account) public view returns (bool) {
    return (_roles[ROOT_RESOURCE][account] | _roles[resource][account]) & roleBitmap == roleBitmap;
}
```

Role checks OR the root roles with resource-specific roles, so holding a role in either scope satisfies the check.

## Admin Mechanics

Each regular role at nybble N has a corresponding admin role at nybble N+32. Holding an admin role grants authority to:

1. **Grant** the corresponding regular role to other accounts
2. **Grant** the admin role itself to other accounts
3. **Revoke** the corresponding regular role from other accounts
4. **Revoke** the admin role itself from other accounts

The logic is:

```solidity
function _getSettableRoles(uint256 resource, address account) internal view returns (uint256) {
    uint256 adminRoleBitmap = (_roles[resource][account] | _roles[ROOT_RESOURCE][account])
        & ADMIN_ROLES;
    return (adminRoleBitmap >> 128) | adminRoleBitmap;
    // adminRoleBitmap >> 128 = the regular roles the admin can set
    // | adminRoleBitmap = plus the admin roles themselves
}
```

### Example

If account A holds `ROLE_SET_RESOLVER_ADMIN` (nybble 38, bit `1 << 152`):

- A can grant `ROLE_SET_RESOLVER` (nybble 6, bit `1 << 24`) to others
- A can grant `ROLE_SET_RESOLVER_ADMIN` to others
- A can revoke both from others
- A does **not** automatically hold `ROLE_SET_RESOLVER` (admins delegate, they don't implicitly have the role)

## Assignee Counting

Each resource has a `roleCount` bitmap that tracks how many accounts hold each role. The count uses the same nybble layout as the role bitmap, so each role's count is stored in 4 bits.

| Property | Limit |
|---|---|
| Maximum assignees per role per resource | 15 |
| Maximum distinct roles | 64 (32 regular + 32 admin) |

When granting a role to a 16th account, the transaction reverts with `EACMaxAssignees`.

### Reading counts

```typescript
const [counts, mask] = await publicClient.readContract({
  address: contractAddress,
  abi: [{
    name: 'getAssigneeCount',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'resource', type: 'uint256' },
      { name: 'roleBitmap', type: 'uint256' },
    ],
    outputs: [
      { name: 'counts', type: 'uint256' },
      { name: 'mask', type: 'uint256' },
    ],
  }],
  functionName: "getAssigneeCount",
  args: [resource, roleBitmap],
});
// Extract count for a specific role at nybble N:
// count = (counts >> (N * 4)) & 0xF
```

## Grant and Revoke Functions

### Writing roles

| Function | Target | Notes |
|---|---|---|
| `grantRoles(resource, roleBitmap, account)` | Specific resource | Reverts with `EACRootResourceNotAllowed` if `resource == 0` |
| `grantRootRoles(roleBitmap, account)` | `ROOT_RESOURCE` (0) | Grants globally-scoped roles |
| `revokeRoles(resource, roleBitmap, account)` | Specific resource | Reverts with `EACRootResourceNotAllowed` if `resource == 0` |
| `revokeRootRoles(roleBitmap, account)` | `ROOT_RESOURCE` (0) | Revokes globally-scoped roles |

All four require the caller to hold the admin role for every role being granted/revoked.

### Reading roles

| Function | Description |
|---|---|
| `roles(resource, account) → uint256` | Full role bitmap for an account on a resource |
| `hasRoles(resource, roleBitmap, account) → bool` | Check roles on resource OR ROOT_RESOURCE |
| `hasRootRoles(roleBitmap, account) → bool` | Check roles on ROOT_RESOURCE only |
| `roleCount(resource) → uint256` | Packed assignee count bitmap |
| `getAssigneeCount(resource, roleBitmap) → (counts, mask)` | Per-role assignee counts, masked |
| `hasAssignees(resource, roleBitmap) → bool` | Whether any of the specified roles has at least one assignee |

## Events

### `EACRolesChanged`

```solidity
event EACRolesChanged(
    uint256 indexed resource,
    address indexed account,
    uint256 oldRoleBitmap,
    uint256 newRoleBitmap
);
```

Emitted on every role grant or revoke. To determine what changed:

```typescript
const granted = newRoleBitmap & ~oldRoleBitmap;  // bits added
const revoked = oldRoleBitmap & ~newRoleBitmap;  // bits removed
```

## Errors

| Error | Selector | When |
|---|---|---|
| `EACUnauthorizedAccountRoles(resource, roleBitmap, account)` | `0x4b27a133` | Account doesn't have the required roles |
| `EACCannotGrantRoles(resource, roleBitmap, account)` | `0xd1a3b355` | Caller doesn't hold the admin role needed to grant |
| `EACCannotRevokeRoles(resource, roleBitmap, account)` | `0xa604e318` | Caller doesn't hold the admin role needed to revoke |
| `EACRootResourceNotAllowed()` | `0xc2842458` | Used `grantRoles()`/`revokeRoles()` with resource 0 (use `grantRootRoles()`/`revokeRootRoles()` instead) |
| `EACMaxAssignees(resource, role)` | `0xf9165348` | Would exceed 15 assignees for a role |
| `EACMinAssignees(resource, role)` | `0x1f80c19b` | Assignee count underflow (shouldn't occur in normal use) |
| `EACInvalidRoleBitmap(roleBitmap)` | `0x2a7b2d20` | Bitmap has bits set outside valid nybble positions |
| `EACInvalidAccount()` | `0xec3fc592` | Trying to grant roles to `address(0)` |

## How Registry and Resolver Use EAC Differently

Both `PermissionedRegistry` and `PermissionedResolver` inherit from `EnhancedAccessControl`, but they customize it in fundamentally different ways.

### PermissionedRegistry

**Resource scoping**: One resource per name, derived from `LibLabel.withVersion(labelhash, eacVersionId)`.

**`anyId` translation**: All EAC view and write functions accept `anyId` (labelhash, tokenId, or resource) and internally resolve to the canonical resource via `getResource()`.

**Admin role restriction**: Token admin roles (the upper 128 bits) **cannot** be granted after registration. The `_getSettableRoles` override strips admin bits for token resources (`roleBitmap >> 128` removes the upper half). Admin roles are only assigned at `register()` time. Root admin roles are unaffected.

**Roles on unregistered names**: Both granting and revoking return 0 (no-op revert) if the name is AVAILABLE or RESERVED.

**Token regeneration**: On every role grant or revoke, the `_onRolesGranted`/`_onRolesRevoked` callbacks burn the old ERC1155 token and mint a new one with an incremented `tokenVersionId`. This ensures the token ID reflects the current permission state.

**Role definitions**: See `RegistryRolesLib`:

| Role | Nybble | Value |
|---|---|---|
| `ROLE_REGISTRAR` | 0 | `1 << 0` |
| `ROLE_REGISTER_RESERVED` | 1 | `1 << 4` |
| `ROLE_SET_PARENT` | 2 | `1 << 8` |
| `ROLE_UNREGISTER` | 3 | `1 << 12` |
| `ROLE_RENEW` | 4 | `1 << 16` |
| `ROLE_SET_SUBREGISTRY` | 5 | `1 << 20` |
| `ROLE_SET_RESOLVER` | 6 | `1 << 24` |
| `ROLE_CAN_TRANSFER_ADMIN` | 7 | `(1 << 28) << 128` |
| `ROLE_UPGRADE` | 31 | `1 << 124` |

### PermissionedResolver

**Resource scoping**: Two-dimensional — `keccak256(node, part)` where `node` identifies the name and `part` identifies the record type. This creates a matrix of four permission levels:

| | Any part (`part=0`) | Specific part |
|---|---|---|
| **Any name** (`node=0`) | `resource(0, 0)` = ROOT_RESOURCE | `resource(0, part)` |
| **Specific name** | `resource(node, 0)` | `resource(node, part)` |

A setter checks four resources in order: `(node, part)`, `(0, part)`, then `(node, 0)` — granting access if any matches.

**`grantRoles()` is disabled**: The base `grantRoles()` function always reverts. Instead, the resolver provides typed grant functions that emit indexer-friendly events:

| Function | What it grants | Events |
|---|---|---|
| `grantNameRoles(toName, roleBitmap, account)` | Any roles on `resource(namehash, 0)` | `NamedResource` |
| `grantTextRoles(toName, key, account)` | `ROLE_SET_TEXT` on `resource(namehash, textPart(key))` | `NamedTextResource` |
| `grantAddrRoles(toName, coinType, account)` | `ROLE_SET_ADDR` on `resource(namehash, addrPart(coinType))` | `NamedAddrResource` |
| `grantRootRoles(roleBitmap, account)` | Any roles on `ROOT_RESOURCE` | `EACRolesChanged` |

These typed functions exist so off-chain indexers can associate opaque `uint256` resources with human-readable names and record keys.

**No token regeneration**: The resolver has no token concept, so `_onRolesGranted`/`_onRolesRevoked` are not overridden. Role changes don't have side effects beyond the `EACRolesChanged` event.

**No admin restriction**: Unlike the registry, the resolver does not strip admin bits from `_getSettableRoles`. If you hold an admin role on a resource, you can grant both the regular and admin role.

**Role definitions**: See `PermissionedResolverLib`:

| Role | Nybble | Value |
|---|---|---|
| `ROLE_SET_ADDR` | 0 | `1 << 0` |
| `ROLE_SET_TEXT` | 1 | `1 << 4` |
| `ROLE_SET_CONTENTHASH` | 2 | `1 << 8` |
| `ROLE_SET_PUBKEY` | 3 | `1 << 12` |
| `ROLE_SET_ABI` | 4 | `1 << 16` |
| `ROLE_SET_INTERFACE` | 5 | `1 << 20` |
| `ROLE_SET_NAME` | 6 | `1 << 24` |
| `ROLE_SET_ALIAS` | 7 | `1 << 28` |
| `ROLE_CLEAR` | 8 | `1 << 32` |
| `ROLE_UPGRADE` | 31 | `1 << 124` |

### Summary of differences

| Aspect | Registry | Resolver |
|---|---|---|
| Resource model | One per name (labelhash + version) | Two-dimensional (node × record type) |
| `grantRoles()` | Works (resolves `anyId` to resource) | Always reverts |
| Typed grant functions | None | `grantNameRoles`, `grantTextRoles`, `grantAddrRoles` |
| Admin roles on resources | Blocked after registration | Allowed |
| Token regeneration on role change | Yes | No |
| Roles on unregistered/missing data | Blocked | Allowed |

## Related

- [PermissionedRegistry](./permissioned-registry.md) — Registry-specific details, state management, token model
- [PermissionedResolver](./permissioned-resolver.md) — Resolver-specific details, record types, aliases
- [Name Registration](./name-registration.md) — How roles are assigned during registration
