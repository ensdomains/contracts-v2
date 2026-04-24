# Subnames

How to create, manage, and delete subnames in ENS v2.

## What is a Subname?

A subname is a name that lives under another name. If you own `example.eth`, you can create subnames like `sub.example.eth`, `mail.example.eth`, etc. Each subname is a separate registration in a child registry.

In ENS v2, every level of the hierarchy is a separate **registry**:

```
ETHRegistry (manages *.eth)
  └── "example" → UserRegistry (manages *.example.eth)
                    ├── "sub"  → (leaf node, no subregistry)
                    ├── "mail" → (leaf node)
                    └── "app"  → UserRegistry (manages *.app.example.eth)
                                   └── "api" → (leaf node)
```

To have subnames, the parent name needs a **subregistry** — a child registry contract that manages the next level.

## Prerequisites

Before creating subnames under `example.eth`, you need:

1. **Own `example.eth`** — have the ERC1155 token with `ROLE_SET_SUBREGISTRY`
2. **A subregistry** — a `UserRegistry` (or `PermissionedRegistry`) deployed for your name
3. **`ROLE_REGISTRAR`** on the subregistry — to register subnames in it

## Step-by-Step: Creating Subnames

### Step 1: Deploy a UserRegistry

The `UserRegistry` is an upgradeable `PermissionedRegistry` deployed via the `VerifiableFactory`. The factory uses CREATE2 for deterministic addresses.

```typescript
import { encodeFunctionData } from "viem";

// Deploy a UserRegistry proxy via the VerifiableFactory
const salt = BigInt(keccak256(toHex("my-unique-salt")));

const tx = await walletClient.writeContract({
  address: verifiableFactoryAddress,
  abi: VerifiableFactoryABI,
  functionName: "deployProxy",
  args: [
    userRegistryImplAddress,  // the UserRegistry implementation
    salt,
    encodeFunctionData({
      abi: UserRegistryABI,
      functionName: "initialize",
      args: [
        myAddress,            // admin of the new registry
        ROLES_ALL,            // grant all roles to admin
      ],
    }),
  ],
});
```

The `initialize(admin, roleBitmap)` call grants the admin `roleBitmap` on the `ROOT_RESOURCE` of the new registry — giving them control over all subnames.

### Step 2: Link the subregistry to the parent name

Tell the parent registry that `example.eth` has a subregistry:

```typescript
// On the ETHRegistry (parent)
await ethRegistry.write.setSubregistry([
  labelHashOrTokenId,       // labelhash of "example", or the tokenId
  userRegistryAddress,      // the new UserRegistry address
]);
```

Requires `ROLE_SET_SUBREGISTRY` on the name's resource (granted to owner at registration by the ETHRegistrar).

### Step 3: Register subnames

Now register subnames in the child UserRegistry:

```typescript
// On the UserRegistry (child)
await userRegistry.write.register([
  "sub",                    // label
  ownerAddress,             // who owns this subname
  zeroAddress,              // subregistry (address(0) for leaf nodes)
  resolverAddress,          // resolver (or address(0) to set later)
  roleBitmap,               // roles to grant to owner
  expiry,                   // unix timestamp
]);
```

Requires `ROLE_REGISTRAR` on the UserRegistry's `ROOT_RESOURCE`.

### Step 4 (optional): Set a resolver

If you didn't set a resolver during registration, set it afterward:

```typescript
await userRegistry.write.setResolver([
  labelHashOrTokenId,       // labelhash of "sub"
  resolverAddress,          // PermissionedResolver address
]);
```

Requires `ROLE_SET_RESOLVER` on the name's resource.

### Step 5 (optional): Set records

Once a resolver is assigned, set records on it:

```typescript
const node = namehash("sub.example.eth");
await permissionedResolver.write.setText([node, "avatar", "https://..."]);
await permissionedResolver.write.setAddr([node, myAddress]);
```

See [Setting Records](./setting-records.md) for full details.

## Roles for Subname Management

### On the parent registry (e.g. ETHRegistry)

| Role | Purpose |
|---|---|
| `ROLE_SET_SUBREGISTRY` | Link/change the subregistry on the parent name |
| `ROLE_SET_RESOLVER` | Set the resolver on the parent name |

These are granted to the name owner at registration time (via `REGISTRATION_ROLE_BITMAP`).

### On the child registry (UserRegistry)

| Role | Purpose | Who typically has it |
|---|---|---|
| `ROLE_REGISTRAR` | Register new subnames | Parent name owner (admin) |
| `ROLE_REGISTER_RESERVED` | Promote RESERVED to REGISTERED | Parent name owner (admin) |
| `ROLE_UNREGISTER` | Delete subnames | Parent name owner (admin) |
| `ROLE_RENEW` | Extend subname expiry | Parent name owner (admin) |
| `ROLE_SET_SUBREGISTRY` | Set subregistry on a subname | Subname owner |
| `ROLE_SET_RESOLVER` | Set resolver on a subname | Subname owner |
| `ROLE_CAN_TRANSFER_ADMIN` | Transfer a subname token | Subname owner |
| `ROLE_UPGRADE` | Upgrade the UserRegistry impl | Registry admin |

Root-level roles (on `ROOT_RESOURCE`) apply to all subnames.
Token-level roles apply to individual subnames.

## Subname Lifecycle

```
                     register()
                  +ROLE_REGISTRAR
       ┌───────────────────────────────────────────┐
       │                                           │
       │                 renew()                   │    renew()
       │               +ROLE_RENEW                 │  +ROLE_RENEW
       │                ┌──────┐                   │   ┌──────┐
       │                │      │                   │   │      │
       ▽                ▽      │                   ▼   ▼      │
   AVAILABLE ─────────► RESERVED ───────────────► REGISTERED ►─┘
     ▲   ▲  register(0)   │       register()         │
     │   │ +ROLE_REGISTRAR │  +ROLE_REGISTRAR         │
     │   │                 │  +ROLE_REGISTER_RESERVED │
     │   └─────────────────┘                          │
     │       unregister()                             │
     │    +ROLE_UNREGISTER                            │
     │                                                │
     └────────────────────────────────────────────────┘
                      unregister()
                    +ROLE_UNREGISTER
```

## Reserving Subnames

You can reserve a subname without assigning an owner — useful for protecting names before they're needed. Reservation is done by calling `register()` with `owner = address(0)`:

```typescript
await userRegistry.write.register([
  "protected",              // label
  zeroAddress,              // owner = address(0) means RESERVED
  zeroAddress,              // no subregistry
  resolverAddress,          // resolver (or address(0))
  0n,                       // no roles (owner is zero)
  expiry,                   // when the reservation expires
]);
```

Requires `ROLE_REGISTRAR` on `ROOT_RESOURCE`.

A reserved name:
- Has no owner (no ERC1155 token minted)
- Cannot be promoted to REGISTERED without `ROLE_REGISTER_RESERVED`
- Can be renewed
- Can be unregistered (back to AVAILABLE)
- Can be converted to REGISTERED by someone with both `ROLE_REGISTRAR` and `ROLE_REGISTER_RESERVED`

## Deleting Subnames

See [Unregistering Names](./unregistering-names.md) for the full reference.

**Quick summary:**

```typescript
// On the UserRegistry that contains the subname
const labelHash = keccak256(toHex("sub"));
await userRegistry.write.unregister([labelHash]);
```

Requires `ROLE_UNREGISTER` on the name's resource or on `ROOT_RESOURCE`.

What happens:
1. Burns the ERC1155 token
2. Invalidates all roles (version bump)
3. Sets expiry to `block.timestamp` (immediately AVAILABLE)
4. Emits `LabelUnregistered(tokenId, sender)`

After unregistering, the subname is `AVAILABLE` and can be re-registered.

**Important**: Unregistering a subname does NOT delete:
- The subregistry linked to it (if any) — that contract still exists
- Records on the resolver — the resolver doesn't know the name was unregistered
- Deeper subnames — they may still exist in the child registry

To fully clean up, you'd also want to clear resolver records and unregister any deeper subnames.

## Nesting: Subnames of Subnames

The pattern repeats for deeper levels. To create `api.app.example.eth`:

1. Register `app` in the `example.eth` UserRegistry
2. Deploy a new UserRegistry for `app.example.eth`
3. Set it as the subregistry for `app`
4. Register `api` in the `app.example.eth` UserRegistry

Each level is an independent registry with its own roles and admin.

## Expiry Rules

- A subname's expiry is set at registration and can be extended via `renew()`
- Subname expiry is independent of the parent name's expiry
- However, resolution walks the tree top-down — if `example.eth` expires, `sub.example.eth` becomes unresolvable even if it hasn't expired in its own registry
- The parent registry returns `address(0)` for expired names from `getSubregistry()`, breaking the chain

## Events to Watch

| Event | Contract | When |
|---|---|---|
| `LabelRegistered(tokenId, labelHash, label, owner, expiry, sender)` | UserRegistry | Subname created |
| `LabelReserved(tokenId, labelHash, label, expiry, sender)` | UserRegistry | Subname reserved |
| `LabelUnregistered(tokenId, sender)` | UserRegistry | Subname deleted |
| `ExpiryUpdated(tokenId, newExpiry, sender)` | UserRegistry | Subname renewed |
| `SubregistryUpdated(tokenId, subregistry, sender)` | Parent registry | Subregistry linked/changed |
| `ResolverUpdated(tokenId, resolver, sender)` | Parent or child registry | Resolver set |
| `TokenRegenerated(oldTokenId, newTokenId)` | UserRegistry | Token regenerated (role change) |
| `EACRolesChanged(resource, account, oldRoles, newRoles)` | UserRegistry | Roles granted/revoked |

## Full Example: Create and Delete a Subname (viem / TypeScript)

```typescript
import { keccak256, toHex, namehash, zeroAddress, encodeFunctionData } from "viem";

// ── Setup: deploy a UserRegistry for example.eth ──

const salt = BigInt(keccak256(toHex("example-eth-registry")));
const tx = await walletClient.writeContract({
  address: verifiableFactoryAddress,
  abi: VerifiableFactoryABI,
  functionName: "deployProxy",
  args: [
    userRegistryImpl,
    salt,
    encodeFunctionData({
      abi: UserRegistryABI,
      functionName: "initialize",
      args: [myAddress, ROLES_ALL],
    }),
  ],
});

// Link it to example.eth
const exampleLabelHash = keccak256(toHex("example"));
await ethRegistry.write.setSubregistry([exampleLabelHash, userRegistryAddress]);

// ── Create subname: sub.example.eth ──

await userRegistry.write.register([
  "sub",                        // label
  recipientAddress,             // owner
  zeroAddress,                  // no subregistry (leaf node)
  permissionedResolverAddress,   // resolver
  REGISTRATION_ROLE_BITMAP,     // standard roles
  BigInt(Math.floor(Date.now() / 1000) + 365 * 24 * 3600), // 1 year
]);

// Set records
const node = namehash("sub.example.eth");
await permissionedResolver.write.setAddr([node, recipientAddress]);
await permissionedResolver.write.setText([node, "avatar", "https://example.com/pic.png"]);

// ── Delete subname: sub.example.eth ──

const subLabelHash = keccak256(toHex("sub"));
await userRegistry.write.unregister([subLabelHash]);
```
