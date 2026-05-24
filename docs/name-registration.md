# Name Registration

A guide to how names work in ENS v2 — from the concepts to the actual registration flow.

## Core Concepts

### What is a Registry?

A **Registry** is a contract that manages a single level of the name hierarchy. It tracks:

- **Ownership** — who owns each subdomain (as an ERC1155 token)
- **Expiry** — when the registration expires
- **Subregistry** — a pointer to the child registry that manages the next level down
- **Resolver** — a pointer to the contract that stores records for this name

Think of it like a folder in a filesystem. The root folder manages TLDs, the "eth" folder manages `.eth` names, and each name's folder manages its subnames.

**Contract**: `PermissionedRegistry` (`contracts/src/registry/PermissionedRegistry.sol`)

### What is a Resolver?

A **Resolver** is a separate contract that stores the actual data associated with a name — addresses, text records, content hashes, etc. The registry doesn't store records; it just points to the resolver that does.

**Contract**: `PermissionedResolver` (`contracts/src/resolver/PermissionedResolver.sol`)

See [PermissionedResolver](./permissioned-resolver.md) for full details on records and roles.

### What is a Registrar?

A **Registrar** is a controller contract that sits on top of a registry and handles the business logic of registration — payment, duration validation, and the commit-reveal anti-frontrunning scheme. Users interact with the registrar, not the registry directly.

**Contract**: `ETHRegistrar` (`contracts/src/registrar/ETHRegistrar.sol`)

See [ETH Registrar](./eth-registrar.md) for the full commit-reveal flow.

### How they fit together

```
User
  │
  │  commit() + register()
  ▼
ETHRegistrar  ─────────────────────── handles payment, commit-reveal
  │
  │  register(label, owner, subregistry, resolver, roles, expiry)
  ▼
ETHRegistry (PermissionedRegistry) ── manages "example.eth" ownership
  │
  │  getSubregistry("example")
  ▼
UserRegistry (PermissionedRegistry) ─ manages "sub.example.eth" ownership
  │
  │  getResolver("example") → PermissionedResolver
  ▼
PermissionedResolver ──────────────── stores addresses, text, contenthash...
```

## The Registry Tree

ENS v2 uses a hierarchy of registries, each managing one name level:

```
RootRegistry (manages "")
│
├── "eth"  → ETHRegistry (manages *.eth)
│              ├── "example" → UserRegistry (manages *.example.eth)
│              │                 ├── "sub" → UserRegistry (manages *.sub.example.eth)
│              │                 └── "mail" → (no subregistry, leaf node)
│              └── "test" → UserRegistry (manages *.test.eth)
│
├── "box"  → BoxRegistry (manages *.box)
│
└── "xyz"  → ...
```

Each entry in a registry stores:

```solidity
struct Entry {
    uint32 eacVersionId;     // access control version (bumped on unregister)
    uint32 tokenVersionId;   // token version (bumped on role changes)
    IRegistry subregistry;   // child registry for subdomains
    uint64 expiry;           // when this name expires
    address resolver;        // where records are stored
}
```

### Name resolution walkthrough

To resolve `sub.example.eth`:

1. Start at `RootRegistry`
2. `RootRegistry.getSubregistry("eth")` → `ETHRegistry`
3. `ETHRegistry.getSubregistry("example")` → `UserRegistry`
4. `UserRegistry.getResolver("sub")` → `PermissionedResolver` (or walk up to find nearest resolver)
5. Call `PermissionedResolver.addr(namehash("sub.example.eth"))` → the ETH address

The resolver is found by walking up the tree until one is set. If "sub" doesn't have a resolver but "example" does, that resolver handles "sub" too (wildcard resolution via `resolve()`).

## Are Registry and Resolver Mandatory?

| Component | Mandatory? | When needed |
|---|---|---|
| **Registry** | Yes, always | Registration requires a parent registry. A name must be registered in a registry to exist. |
| **Subregistry** | No | Only needed if the name will have subdomains. Can be `address(0)` for leaf nodes. |
| **Resolver** | No | Only needed for name resolution (looking up addresses, text records, etc.). Can be `address(0)` at registration and set later. |

A name with no resolver is "owned but unresolvable" — it exists on-chain as an ERC1155 token, but nobody can look up records for it. You can add a resolver at any time via `setResolver()`.

A name with no subregistry is a "leaf node" — it can't have subdomains. You can add a subregistry later via `setSubregistry()`.

## Registration Flow

### For `.eth` names (via ETHRegistrar)

Users don't call the registry directly. They go through the ETHRegistrar which handles payment and anti-frontrunning.

**Step 1: Commit** (anti-frontrunning)

```
commitment = keccak256(label, owner, secret, subregistry, resolver, duration, referrer)
ETHRegistrar.commit(commitment)
```

Wait for `MIN_COMMITMENT_AGE` (e.g. 60 seconds).

**Step 2: Register** (reveal + pay)

```
ETHRegistrar.register(label, owner, secret, subregistry, resolver, duration, paymentToken, referrer)
```

This:
1. Validates the commitment is old enough but not expired
2. Checks the name is `AVAILABLE`
3. Calculates the price via the rent price oracle
4. Transfers payment (ERC20) from caller to beneficiary
5. Calls `Registry.register()` which:
   - Mints an ERC1155 token to `owner`
   - Sets `subregistry`, `resolver`, and `expiry`
   - Grants the owner a set of default roles (see below)

**Roles granted to owner at registration:**

| Role | Purpose |
|---|---|
| `ROLE_SET_SUBREGISTRY` + admin | Change the subregistry |
| `ROLE_SET_RESOLVER` + admin | Change the resolver |
| `ROLE_CAN_TRANSFER_ADMIN` | Transfer the name to another address |

Note: the owner does NOT get `ROLE_UNREGISTER` or `ROLE_REGISTRAR` — those stay with the registrar/registry admin.

### For subnames (direct registry call)

Subnames are registered directly on a `UserRegistry` by the parent name's owner (or anyone with `ROLE_REGISTRAR` on that registry).

```solidity
parentRegistry.register(
    "sub",                    // label
    ownerAddress,             // who owns it
    subregistry,              // child registry (or address(0))
    resolverAddress,          // resolver (or address(0))
    roleBitmap,               // roles to grant to owner
    expiry                    // unix timestamp
);
```

No commit-reveal, no payment — the parent name owner controls subname registration.

### Registration parameters explained

| Parameter | Type | Required | Description |
|---|---|---|---|
| `label` | `string` | Yes | The subdomain label (e.g. `"example"` for `example.eth`) |
| `owner` | `address` | Yes | The address that will own the name (receives ERC1155 token). Pass `address(0)` to reserve a name without an owner. |
| `registry` | `IRegistry` | No | The subregistry for subdomains. Pass `address(0)` for leaf nodes. |
| `resolver` | `address` | No | The resolver contract. Pass `address(0)` to set later. |
| `roleBitmap` | `uint256` | Yes | Which roles to grant to the owner on this name's resource. |
| `expiry` | `uint64` | Yes | Unix timestamp when the name expires. Must be in the future. |

### What gets created

After a successful `register()`:

1. **ERC1155 token** minted to `owner` — this IS the name. Owning the token = owning the name.
2. **Entry** stored with subregistry, resolver, expiry.
3. **Roles** granted to owner on the name's resource.
4. **Events emitted**: `LabelRegistered`, `SubregistryUpdated` (if registry != 0), `ResolverUpdated` (if resolver != 0), `TokenResource`.

## Name Lifecycle

```
                    register()
                 +ROLE_REGISTRAR
       ┌──────────────────────────────────────────┐
       │                                          │
       │                renew()                   │    renew()
       │              +ROLE_RENEW                 │  +ROLE_RENEW
       │               ┌──────┐                   │   ┌──────┐
       │               │      │                   │   │      │
       ▽               ▽      │                   ▼   ▼      │
   AVAILABLE ────────► RESERVED ──────────────► REGISTERED ►──┘
     ▲   ▲  register(0)  │       register()        │
     │   │ +ROLE_REGISTRAR│  +ROLE_REGISTRAR        │
     │   │                │  +ROLE_REGISTER_RESERVED│
     │   └────────────────┘                         │
     │       unregister()                           │
     │    +ROLE_UNREGISTER                          │
     │                                              │
     └──────────────────────────────────────────────┘
                     unregister()
                   +ROLE_UNREGISTER
```

- **AVAILABLE**: Name doesn't exist or has expired. Can be registered.
- **RESERVED**: Name is locked (no owner) but cannot be promoted to REGISTERED without `ROLE_REGISTER_RESERVED`. Useful for protecting names before launch.
- **REGISTERED**: Name has an owner, an ERC1155 token, and optionally a subregistry + resolver.

## Registry Roles

Defined in `RegistryRolesLib` (`contracts/src/registry/libraries/RegistryRolesLib.sol`):

| Role | Nybble | Bit shift | Who typically has it | Purpose |
|---|---|---|---|---|
| `ROLE_REGISTRAR` | 0 | `1 << 0` | ETHRegistrar or parent owner | Register and reserve labels |
| `ROLE_REGISTER_RESERVED` | 1 | `1 << 4` | Registry admin | Promote RESERVED to REGISTERED |
| `ROLE_SET_PARENT` | 2 | `1 << 8` | Registry admin | Set parent registry |
| `ROLE_UNREGISTER` | 3 | `1 << 12` | Registry admin | Delete labels |
| `ROLE_RENEW` | 4 | `1 << 16` | ETHRegistrar or parent owner | Extend expiry |
| `ROLE_SET_SUBREGISTRY` | 5 | `1 << 20` | Name owner | Change the subregistry |
| `ROLE_SET_RESOLVER` | 6 | `1 << 24` | Name owner | Change the resolver |
| `ROLE_CAN_TRANSFER_ADMIN` | 7 (admin only) | `(1 << 28) << 128` | Name owner | Transfer the ERC1155 token |
| `ROLE_UPGRADE` | 31 | `1 << 124` | Registry admin | Upgrade registry implementation |

Root-level roles (on `ROOT_RESOURCE`) apply to all names in that registry.
Token-level roles apply to a specific name.

## Typical Setup for a New Name

After registering `example.eth`, a typical setup looks like:

1. **Register** `example.eth` via ETHRegistrar (commit + register + pay)
2. **Deploy a UserRegistry** for subnames (via VerifiableFactory)
3. **Set the subregistry**: `ethRegistry.setSubregistry(labelHash, userRegistry)`
4. **Deploy/assign a PermissionedResolver**
5. **Set the resolver**: `ethRegistry.setResolver(labelHash, permissionedResolver)`
6. **Set records** on the resolver: `permissionedResolver.setAddr(node, myAddress)`, etc.

Steps 2-3 are only needed if you want subdomains.
Steps 4-6 are only needed if you want the name to resolve to something.

For the simplest case (just own the name, no records, no subdomains), only step 1 is needed.
