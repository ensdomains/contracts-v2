# Migrating v1 Names

How ENS v1 names are migrated to v2 contracts.

**Contracts**:
- `contracts/src/migration/UnlockedMigrationController.sol`
- `contracts/src/migration/LockedMigrationController.sol`
- `contracts/src/migration/LockedWrapperReceiver.sol`
- `contracts/src/migration/AbstractWrapperReceiver.sol`
- `contracts/src/migration/libraries/LibMigration.sol`
- `contracts/src/registry/WrapperRegistry.sol`
- `contracts/src/registrar/BatchRegistrar.sol` (pre-migration)

## Overview

Migration moves names from ENS v1 (BaseRegistrar / NameWrapper) to v2 (PermissionedRegistry). The process has two phases:

1. **Pre-migration**: reserve names on v2 with their v1 expiry (batch operation by admin)
2. **User migration**: users transfer their v1 tokens to migration controllers, which promote the reservations to full registrations

## Pre-migration

Before users can migrate, names must be **reserved** on the v2 ETHRegistry. This is done in batch by the system admin using the `BatchRegistrar`:

```solidity
function batchRegister(
    IRegistry registry,
    address resolver,
    string[] calldata labels,
    uint64[] calldata expires
) external onlyOwner
```

For each label, this creates a `RESERVED` entry on the v2 registry with the v1 expiry. No owner is set and no token is minted. The script `contracts/script/preMigration.ts` automates this:

1. Reads a CSV of v1 registrations
2. Verifies each name's v1 status via `BaseRegistrar.nameExpires()`
3. Calls `BatchRegistrar.batchRegister()` to reserve or renew on v2
4. Uses checkpoints for resumable execution

After pre-migration, each name is `RESERVED` in v2, waiting for the user to claim it.

## Migration Paths

There are two migration controllers, depending on whether the v1 name is locked (wrapped with `CANNOT_UNWRAP`) or unlocked:

| v1 State | Controller | Token source |
|---|---|---|
| Unlocked (BaseRegistrar ERC721) | `UnlockedMigrationController` | `BaseRegistrar.safeTransferFrom()` |
| Unlocked (NameWrapper ERC1155) | `UnlockedMigrationController` | `NameWrapper.safeTransferFrom()` |
| Locked (NameWrapper with `CANNOT_UNWRAP`) | `LockedMigrationController` | `NameWrapper.safeTransferFrom()` |
| Locked subname (emancipated child) | `WrapperRegistry` (parent) | `NameWrapper.safeTransferFrom()` |

## Unlocked Migration

For names without the `CANNOT_UNWRAP` fuse, the user transfers their v1 token to the `UnlockedMigrationController`. The controller:

1. Validates the token matches the provided label
2. Clears the v1 resolver (to prevent stale resolution)
3. Registers the name in the v2 ETHRegistry (promoting from `RESERVED` to `REGISTERED`)

### From BaseRegistrar (ERC721)

```typescript
const migrationData = encodeFunctionData({
  // ABI-encode LibMigration.Data struct
});

// Transfer ERC721 token to the migration controller
await walletClient.writeContract({
  address: baseRegistrarAddress,
  abi: [{
    name: 'safeTransferFrom',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'from', type: 'address' },
      { name: 'to', type: 'address' },
      { name: 'tokenId', type: 'uint256' },
      { name: 'data', type: 'bytes' },
    ],
    outputs: [],
  }],
  functionName: "safeTransferFrom",
  args: [myAddress, unlockedMigrationControllerAddress, labelHash, migrationData],
});
```

### From NameWrapper (ERC1155, unlocked)

```typescript
await walletClient.writeContract({
  address: nameWrapperAddress,
  abi: [{
    name: 'safeTransferFrom',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'from', type: 'address' },
      { name: 'to', type: 'address' },
      { name: 'id', type: 'uint256' },
      { name: 'value', type: 'uint256' },
      { name: 'data', type: 'bytes' },
    ],
    outputs: [],
  }],
  functionName: "safeTransferFrom",
  args: [myAddress, unlockedMigrationControllerAddress, namehashOfName, 1n, migrationData],
});
```

### Migration data payload

The `data` parameter is an ABI-encoded `LibMigration.Data` struct:

```solidity
struct Data {
    string label;          // subdomain being migrated (e.g., "example")
    address owner;         // v2 owner address (cannot be address(0))
    IRegistry subregistry; // child registry (address(0) for leaf nodes)
    address resolver;      // v2 resolver address
}
```

```typescript
import { encodeAbiParameters, parseAbiParameters } from "viem";

const migrationData = encodeAbiParameters(
  parseAbiParameters("string label, address owner, address subregistry, address resolver"),
  ["example", myAddress, zeroAddress, permissionedResolverAddress],
);
```

### What happens internally

1. `UnlockedMigrationController` receives the token via `onERC721Received` or `onERC1155Received`
2. Decodes `LibMigration.Data` from the transfer payload
3. Clears the v1 resolver: `setResolver(node, address(0))`
4. Calls `ETH_REGISTRY.register(label, owner, subregistry, resolver, REGISTRATION_ROLE_BITMAP, 0)`:
   - `expiry = 0` means "use the reserved expiry" — inherits the pre-migration expiry
   - Reverts if the name was not pre-migrated (not `RESERVED`)
5. The name is now `REGISTERED` on v2 with the owner, resolver, and standard roles

## Locked Migration

For names with the `CANNOT_UNWRAP` fuse, migration preserves the v1 fuse restrictions by mapping them to v2 roles.

### How it works

1. User transfers their locked NameWrapper token to `LockedMigrationController`
2. The controller deploys a `WrapperRegistry` proxy for the name (as the subregistry)
3. Maps v1 fuses to v2 roles (removing capabilities the fuses restricted)
4. Registers the name in the v2 ETHRegistry

### Fuse-to-role mapping

v1 NameWrapper fuses restrict what the owner can do. The migration controller translates these restrictions into v2 roles by **omitting** the corresponding role:

| v1 Fuse | Effect in v2 |
|---|---|
| `CANNOT_TRANSFER` | `ROLE_CAN_TRANSFER_ADMIN` is NOT granted |
| `CANNOT_SET_RESOLVER` | `ROLE_SET_RESOLVER` + admin NOT granted, resolver from migration data is ignored |
| `CANNOT_CREATE_SUBDOMAIN` | `ROLE_REGISTRAR` is NOT granted on the WrapperRegistry |
| `CANNOT_BURN_FUSES` | Admin roles are NOT granted |
| `CAN_EXTEND_EXPIRY` | `ROLE_RENEW` + admin IS granted |

### Subname migration (WrapperRegistry)

Locked names can have emancipated subnames that also need migration. The `WrapperRegistry` extends `PermissionedRegistry` with `LockedWrapperReceiver`, allowing it to receive child tokens:

```
transfer("nick.eth") → LockedMigrationController
  └── ETHRegistry.subregistry("nick") = WrapperRegistry("nick.eth")
      transfer("sub.nick.eth") → WrapperRegistry("nick.eth")
        └── WrapperRegistry("nick.eth").subregistry("sub") = WrapperRegistry("sub.nick.eth")
            transfer("abc.sub.nick.eth") → WrapperRegistry("sub.nick.eth")
```

Each level creates a new `WrapperRegistry` proxy, maintaining the tree structure.

### WrapperRegistry behavior

The `WrapperRegistry` is a `PermissionedRegistry` that:
- Acts as a `LockedWrapperReceiver` for child token migration
- Overrides `getResolver()` to return the `V1_RESOLVER` for children that haven't migrated yet
- Blocks direct `register()` for children that still have v1 tokens (reverts with `NameRequiresMigration`)

## Migration Requirements

| Requirement | For unlocked | For locked |
|---|---|---|
| Name is `RESERVED` on v2 | Yes | Yes |
| Controller has `ROLE_REGISTER_RESERVED` on ETHRegistry | Yes | Yes |
| Name label matches token ID | Yes | Yes |
| Token is not locked (unlocked path) | Yes | N/A |
| Token has `CANNOT_UNWRAP` (locked path) | N/A | Yes |
| Owner in migration data is not `address(0)` | Yes | Yes |

## Errors

| Error | When |
|---|---|
| `NameIsLocked(tokenId)` | Unlocked controller received a locked token — use `LockedMigrationController` |
| `NameNotLocked(tokenId)` | Locked controller received an unlocked token — use `UnlockedMigrationController` |
| `NameDataMismatch(tokenId)` | Token ID doesn't match the label in migration data |
| `NameRequiresMigration()` | Trying to register directly on a WrapperRegistry for a name that has an unmigrated v1 token |
| `InvalidData()` | Migration data payload is too short or malformed |
| `FrozenTokenApproval(tokenId)` | Locked token has an existing approval with `CANNOT_APPROVE` burned |
| `InvalidOwner()` | Owner in migration data is `address(0)` |

## Migration Sequence Summary

```
Phase 1: Pre-migration (admin)
  preMigration.ts → BatchRegistrar.batchRegister()
  → Names become RESERVED on v2 with v1 expiry

Phase 2: User migration
  Unlocked:
    BaseRegistrar.safeTransferFrom(user, UnlockedMigrationController, tokenId, data)
    OR NameWrapper.safeTransferFrom(user, UnlockedMigrationController, id, 1, data)
    → UnlockedMigrationController clears v1 resolver, registers on v2

  Locked (.eth 2LD):
    NameWrapper.safeTransferFrom(user, LockedMigrationController, id, 1, data)
    → LockedMigrationController deploys WrapperRegistry, maps fuses to roles, registers on v2

  Locked (subname):
    NameWrapper.safeTransferFrom(user, WrapperRegistry(parent), id, 1, data)
    → WrapperRegistry deploys child WrapperRegistry, maps fuses, registers subname
```

## Related

- [Name Registration](./name-registration.md) — How names are registered in v2
- [Subnames](./subnames.md) — Subname creation and management
