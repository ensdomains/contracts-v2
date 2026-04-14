# ENSv2 Migration Plan

## Overview

The deployment of ENSv2 will require migrating existing names to new smart contracts on Ethereum Mainnet. This document outlines timelines, processes, and verification steps for each category of ENSv1 name.

ENSv1 names will continue to function on ENSv1 until expiration, without requiring migration. Migrating will allow users to take advantage of new ENSv2 functionality. There is no fixed end time for the migration process — some names may remain on ENSv1 indefinitely but will continue to resolve as expected via the `ENSV1Resolver` fallback.

## Timeline & Prerequisites

ENSv2 is currently slated for launch EOY 2025 – Q1 2026, which will enable migration.

Key prerequisites before migration can begin:

- ENSv2 contracts deployed and verified on Ethereum Mainnet
- All active .eth 2LDs premigrated (reserved) in `ETHRegistry`
- Short-expiry names extended in ENSv1
- ENSv1 .eth registration disabled
- Migration controllers granted `ROLE_REGISTER_RESERVED`
- ENS Manager App updated with migration UI

## ENSv1 Token Types

1. **Unwrapped** — `BaseRegistrar` ERC-721 (2LD only)
2. **Unlocked** — `NameWrapper` ERC-1155 without `CANNOT_UNWRAP`
3. **Locked** — `NameWrapper` ERC-1155 with `CANNOT_UNWRAP`

### Key Definitions

- Migration only supports descendants of `"eth"`
- **Locked** status is determined by `CANNOT_UNWRAP` (which requires `PARENT_CANNOT_CONTROL` — every Locked token is emancipated by construction)
- A child of a Locked token can only be migrated if the parent has migrated and the child is Locked
- `ETHRegistry` is the registry for `"eth"` in ENSv2
- `ETHRegistrar` is the registrar for `ETHRegistry`

## Migration Receivers

| Receiver | Accepts | Source |
|---|---|---|
| `UnlockedMigrationController` | Unwrapped 2LDs (`IERC721Receiver` from `BaseRegistrar`) | `BaseRegistrar` |
| `UnlockedMigrationController` | Unlocked 2LDs (`AbstractWrapperReceiver`) | `NameWrapper` |
| `LockedMigrationController` | Locked 2LDs (`LockedWrapperReceiver`) | `NameWrapper` |
| `WrapperRegistry` | Locked 3LD+ (`LockedWrapperReceiver`) | `NameWrapper` |

- `AbstractWrapperReceiver` is `IERC1155Receiver` and only accepts `NameWrapper` tokens
- `LockedWrapperReceiver` extends `AbstractWrapperReceiver` and only accepts Locked tokens
- Each name has exactly one valid receiver — sending to the wrong one reverts with a descriptive error (`NameIsLocked`, `NameNotLocked`, `NameDataMismatch`)

## Migration Process

### Phase 1: Premigration

1. **Deploy ENSv2 contracts** on Ethereum Mainnet: `ETHRegistry`, `RegistryDatastore`, `ETHRegistrar`, migration controllers, `ENSV1Resolver`, `UniversalResolverV2`, etc.
2. **Reserve all active .eth 2LDs** in `ETHRegistry`: each name is marked `RESERVED` with its ENSv1 expiry synced, owner set to `address(0)`, and resolver set to `ENSV1Resolver` (which performs wildcard fallback to ENSv1).
3. **Extend short-expiry names** in ENSv1: names expiring too close to the migration launch are extended so users have adequate time to migrate.
4. **Disable ENSv1 .eth registration** by removing all .eth registrar controllers. Existing names continue to resolve normally.
5. **Grant `ROLE_REGISTER_RESERVED`** to `UnlockedMigrationController` and `LockedMigrationController` on `ETHRegistry`. Note: `ETHRegistrar` does NOT have this role, so `RESERVED` (unmigrated) names cannot be freshly registered until they expire.

#### Premigration Verification

| Check | Method |
|---|---|
| Contracts deployed and wired | `ETHRegistry.getParent()` returns RootRegistry |
| Names are RESERVED | `ETHRegistry.getStatus(labelHash)` == `RESERVED` for every 2LD |
| Expiry matches ENSv1 | `ETHRegistry.getExpiry(labelHash)` == `BaseRegistrar.nameExpires(tokenId)` |
| Owner is zero | `ETHRegistry.latestOwnerOf(tokenId)` == `address(0)` |
| Resolver is ENSV1Resolver | `ETHRegistry.getResolver(labelHash)` == `ENSV1Resolver` address |
| Count matches | Total `LabelReserved` events == total active ENSv1 .eth registrations |
| Resolution still works | Resolve a known name — `ENSV1Resolver` returns same records as ENSv1 |
| No short-expiry names | All `BaseRegistrar.nameExpires()` values are beyond the cutoff date |
| V1 registration disabled | `ETHRegistrarController.commit()` / `register()` reverts |
| Migration roles set | Both controllers have `ROLE_REGISTER_RESERVED` on `ETHRegistry` |
| ETHRegistrar cannot register reserved | `ETHRegistrar.isAvailable(reservedLabel)` returns `false` |

### Phase 2: Migration

Once premigration is complete, users migrate names by transferring their ENSv1 tokens to the appropriate receiver with encoded migration data.

#### Unwrapped .eth 2LDs (852,260)

1. User calls `BaseRegistrar.safeTransferFrom()` to `UnlockedMigrationController` with `data = abi.encode(LibMigration.Data)`.
2. Controller validates: `tokenId` must match `keccak256(bytes(Data.label))` or reverts `NameDataMismatch`.
3. Controller reclaims the name on `BaseRegistrar` (becomes `ENSRegistry` owner of the 2LD).
4. ENSv1 resolver is cleared.
5. `Data.label` is registered in `ETHRegistry`: the `RESERVED` entry is converted to `REGISTERED` with `Data.owner`, `Data.resolver`, and `Data.subregistry`. Token roles match those of `ETHRegistrar.register()`.

**Verification:**

| Check | Method |
|---|---|
| V1 token transferred | `BaseRegistrar.ownerOf(tokenId)` == `UnlockedMigrationController` |
| V2 name registered | `ETHRegistry.getStatus(labelHash)` == `REGISTERED` |
| Correct owner | `ETHRegistry.latestOwnerOf(newTokenId)` == specified owner |
| Correct resolver | `ETHRegistry.getResolver(labelHash)` == specified resolver |
| Correct subregistry | `ETHRegistry.getSubregistry(labelHash)` == specified subregistry |
| Expiry preserved | `ETHRegistry.getExpiry(labelHash)` unchanged |
| Event emitted | `LabelRegistered` with correct parameters |
| V2 resolution works | Resolve the name through ENSv2 — returns records from new resolver |

#### Unlocked .eth 2LDs (323,283)

1. User calls `NameWrapper.safeTransferFrom()` (or `safeBatchTransferFrom()`) to `UnlockedMigrationController` with `data = abi.encode(LibMigration.Data)` (or `LibMigration.Data[]` for batch).
2. Controller validates: token must NOT be Locked or reverts `NameIsLocked`. `tokenId` must match `namehash("{Data.label}.eth")` or reverts `NameDataMismatch`.
3. Token is NOT unwrapped — `UnlockedMigrationController` holds the NameWrapper token until expiry. `NameWrapper` remains the `ENSRegistry` owner.
4. ENSv1 resolver is cleared (note: `CANNOT_SET_RESOLVER` cannot be burned while Unlocked).
5. `Data.label` is registered in `ETHRegistry` identically to the Unwrapped case.

**Note:** Unlocked 3LD+ subnames cannot be migrated. They must be registered directly in ENSv2 by the parent name owner after migration.

**Verification:** Same as Unwrapped, except V1 token check uses `NameWrapper.ownerOf(tokenId)` and additionally verify ENSv1 resolver is cleared via `ENSRegistry.resolver(node)` == `address(0)`.

#### Locked .eth 2LDs (657)

1. User calls `NameWrapper.safeTransferFrom()` (or `safeBatchTransferFrom()`) to `LockedMigrationController` with `data = abi.encode(LibMigration.Data)` (or `LibMigration.Data[]` for batch).
2. Controller validates: token must be Locked or reverts `NameNotLocked`. `tokenId` must match `namehash("{Data.label}.eth")`. `getApproved()` must be null or reverts `FrozenTokenApproval`.
3. Token is NOT unwrapped — `LockedMigrationController` holds it until expiry.
4. Resolver handling depends on fuses:
   - If `CANNOT_SET_RESOLVER` is burned: `Data.resolver` is replaced with the current ENSv1 resolver (preserving the restriction).
   - Otherwise: `Data.resolver` is used as specified.
5. `Data.label` is registered in `ETHRegistry`. A new `WrapperRegistry` is deployed as the subregistry.
6. Fuses are mapped to ENSv2 roles on the `WrapperRegistry` and token (see Fuse Mapping below).

**Verification:**

| Check | Method |
|---|---|
| V1 token transferred | `NameWrapper.ownerOf(tokenId)` == `LockedMigrationController` |
| WrapperRegistry deployed | `ETHRegistry.getSubregistry(labelHash)` returns non-zero `WrapperRegistry` |
| WrapperRegistry initialized | `WrapperRegistry.getWrappedName()` returns correct DNS-encoded name; `WrapperRegistry.getParent()` returns `ETHRegistry` |
| Fuse→role mapping correct | Check roles on `WrapperRegistry` resource match fuse state (see table below) |
| Resolver preserved if CANNOT_SET_RESOLVER | `ETHRegistry.getResolver(labelHash)` == original ENSv1 resolver |
| Same registration checks | Status, owner, expiry, event |

#### Locked 3LD+ Subnames (14,140 emancipated + 1,894 unemancipated)

1. User calls `NameWrapper.safeTransferFrom()` to the parent's `WrapperRegistry`. The parent **must** have already migrated (otherwise there is no `WrapperRegistry` to receive the token).
2. Controller validates: token must be Locked. `tokenId` must match `namehash("{Data.label}.{getWrappedName()}")`. `getApproved()` must be null.
3. The child is registered in the parent `WrapperRegistry` via `_inject()` (no `ROLE_REGISTER` needed). Expiry is copied from the Locked token.
4. A new `WrapperRegistry` is deployed as the child's subregistry with fuse-mapped roles.

**Verification:**

| Check | Method |
|---|---|
| Parent migrated | `ETHRegistry.getSubregistry(parentLabelHash)` returns parent's `WrapperRegistry` |
| V1 token transferred | `NameWrapper.ownerOf(tokenId)` == parent's `WrapperRegistry` |
| Child registered | `WrapperRegistry.getStatus(childLabelHash)` == `REGISTERED` |
| Child subregistry deployed | `WrapperRegistry.getSubregistry(childLabelHash)` returns child's `WrapperRegistry` |
| Expiry matches V1 | `WrapperRegistry.getExpiry(childLabelHash)` matches NameWrapper expiry |

#### Unlocked Subnames (169,283 unwrapped + 1,220 wrapped unlocked)

Unlocked subnames (both unwrapped and wrapped) **cannot be migrated directly**. After the parent 2LD is migrated, the parent owner can register these subnames fresh in ENSv2. Unmigrated subnames cease to exist in ENSv2 — their ENSv1 records remain but no longer affect ENSv2 resolution.

#### Unmigratable Names

The following names cannot be migrated under any circumstances:

1. **Unwrapped or Unlocked** names that are not transferable (owner cannot or will not transfer)
2. **Locked** names with `CANNOT_TRANSFER = true` (token cannot be moved)
3. **Locked** names with `CANNOT_APPROVE = true` and non-null `getApproved()` (frozen approval blocks transfer validation)
4. **Locked 3LD+** whose parent has not yet migrated (no `WrapperRegistry` to receive the token — must wait for parent)

## NameWrapper Fuse → ENSv2 Role Mapping

| Fuse | ENSv2 Effect |
|---|---|
| `CANNOT_UNWRAP` | Determines **Locked** status (migration path) |
| `CANNOT_BURN_FUSES` | If false: owner gets admin-equivalent roles. If true: no admin roles granted |
| `CANNOT_TRANSFER` | If false: token gets `ROLE_CAN_TRANSFER_ADMIN` |
| `CANNOT_SET_RESOLVER` | If false: token gets `ROLE_SET_RESOLVER` |
| `CANNOT_CREATE_SUBDOMAIN` | If false: owner gets `ROLE_REGISTRAR` on subregistry |
| `CANNOT_APPROVE` | Reverts migration if `getApproved()` is non-null |
| `CAN_EXTEND_EXPIRY` | If true: token gets `ROLE_RENEW` |
| `CANNOT_SET_TTL` | Ignored |
| `PARENT_CANNOT_CONTROL` | See Locked definition (required for `CANNOT_UNWRAP`) |
| `IS_DOT_ETH` | Ignored by construction |
| `CAN_DO_EVERYTHING` | Equivalent to Unlocked |

## Onchain DNS Names (1,581)

A new DNS Registrar contract is deployed that implements a new syntax for DNSSEC TXT records (prefixed `ENS2`). Names with this prefix can be imported using the standard claim process. Names that continue to use the `ENS1` prefix can be imported using the legacy process. The registrar falls back to looking up names in ENSv1 if no name is found in ENSv2.

**Verification:** Import a test DNS name with `ENS2` prefix and verify it resolves correctly via ENSv2. Verify `ENS1`-prefixed names still resolve via fallback.

## Offchain DNS Names

A new DNS resolver contract is deployed with identical functionality to the ENSv1 version. All offchain DNS names resolve using this contract.

**Verification:** Resolve an offchain DNS name and confirm records match ENSv1.

## Reverse Records (931,138)

New reverse registry contracts are deployed. Users can claim a reverse record in ENSv2 in the same fashion as ENSv1. The contracts fall back to checking ENSv1 if no ENSv2 reverse record is found.

**Verification:** Claim a reverse record in ENSv2, verify it resolves. Verify an unclaimed address falls back to its ENSv1 reverse record.

### Phase 3: Post-Migration (Steady State)

After migration is enabled, the system enters steady state:

- **New registrations**: `ETHRegistrar.register()` works for non-RESERVED names.
- **Renewals of migrated names**: `ETHRegistrar.renew()` works normally.
- **Renewals of unmigrated names**: `ETHRegistrar` can renew unmigrated names at cost, extending both the ENSv2 RESERVED expiry and the ENSv1 expiry. This allows users to preserve names without migrating.
- **Unmigrated resolution**: `ENSV1Resolver` continues to resolve unmigrated names via wildcard fallback to ENSv1 until the ENSv2 expiry lapses.
- **Expiry**: Unmigrated names that are not renewed will eventually expire, at which point they become `AVAILABLE` for fresh registration on ENSv2 by anyone.

#### Post-Migration Verification

| Check | Method |
|---|---|
| New registration works | `ETHRegistrar.register()` succeeds for a fresh name |
| RESERVED names blocked | `ETHRegistrar.isAvailable(reservedLabel)` returns `false`; `register()` reverts |
| Unmigrated renewal works | `ETHRegistrar.renew()` for a RESERVED name succeeds; `ExpiryUpdated` emitted |
| Migrated renewal works | `ETHRegistrar.renew()` for a REGISTERED name succeeds |
| Unmigrated resolution | Resolve unmigrated name — returns ENSv1 records via `ENSV1Resolver` fallback |
| Migrated resolution | Resolve migrated name — returns records from ENSv2 resolver |
| Expired names become available | After expiry: `ETHRegistry.getStatus(labelHash)` == `AVAILABLE`, `ETHRegistrar.isAvailable()` returns `true` |

## Considerations

### Renewing Unmigrated Locked Names

While `ETHRegistrar` can renew unmigrated names by extending the ENSv2 expiry, Locked (wrapped) names present a challenge: the `NameWrapper` maintains its own expiration date, which is only updated via the wrapper's `renew()` method. The ability to update the registrar controller used by the wrapper has been revoked, so post-migration it is not possible to renew wrapped ENSv1 names in a way that extends the wrapper expiry.

This means:
- **Unwrapped/Unlocked unmigrated names** can be renewed indefinitely via `ETHRegistrar` without migrating.
- **Locked unmigrated names** will eventually expire in the NameWrapper even if the ENSv2 expiry is renewed, making migration the only path to long-term preservation.

### Migration is Voluntary but Encouraged

There is no deadline for migration. However, migrating provides:
- Access to ENSv2 features (new resolver capabilities, role-based access control)
- Unified resolution without `ENSV1Resolver` fallback
- For Locked names: the only reliable path to long-term preservation (see above)
