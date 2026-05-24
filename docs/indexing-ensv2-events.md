# Indexing ENSv2: Contracts, Functions, and Events

This document describes the ENSv2 contract events and functions relevant to building an indexer. It covers the full lifecycle of names — registration, transfer, renewal, subname creation, resolver record changes, role management, and aliasing.

## Contract Hierarchy

ENSv2 uses a hierarchical registry model. There is no single registry contract that holds all names. Instead:

```
RootRegistry (PermissionedRegistry)
  └── ETHRegistry (PermissionedRegistry) — manages *.eth
        ├── name.eth (token in ETHRegistry)
        │     └── UserRegistry — manages *.name.eth
        │           ├── sub.name.eth (token in UserRegistry)
        │           │     └── UserRegistry — manages *.sub.name.eth
        │           │           └── ...
        │           └── ...
        └── ...
```

Each registry is a `PermissionedRegistry` (or `UserRegistry` for subnames), implementing `IRegistry`, `IStandardRegistry`, `IPermissionedRegistry`, and `IEnhancedAccessControl`. Tokens are ERC1155 (one token per name, via `ERC1155Singleton`).

Resolvers are separate contracts (`PermissionedResolver`) deployed per-owner, not per-name. Multiple names can share the same resolver, and aliases (`setAlias`) allow one name to reuse another's resolver records by rewriting the name suffix during resolution (e.g., `sub.alias.eth` → `sub.test.eth`).

---

## Registry Events

These events are emitted by any registry contract (`PermissionedRegistry` / `UserRegistry`).

### LabelRegistered

```solidity
event LabelRegistered(
    uint256 indexed tokenId,
    bytes32 indexed labelHash,
    string label,
    address owner,
    uint64 expiry,
    address indexed sender
);
```

**Emitted by**: `IRegistryEvents` (on `PermissionedRegistry`, `UserRegistry`)

**When**: A new label is registered via `register()`. The full name is constructed by appending the parent name (e.g., label `"test"` under ETHRegistry = `"test.eth"`). The registry contract address that emitted this event identifies which level of the hierarchy this label belongs to.

---

### LabelReserved

```solidity
event LabelReserved(
    uint256 indexed tokenId,
    bytes32 indexed labelHash,
    string label,
    uint64 expiry,
    address indexed sender
);
```

**Emitted by**: `IRegistryEvents` (on `PermissionedRegistry`)

**When**: A label is reserved via `register()` with `owner = address(0)` and `roleBitmap = 0`. No token is minted and no owner is set. A reserved label can be promoted to REGISTERED by calling `register()` again with a real owner, which requires `ROLE_REGISTER_RESERVED`.

---

### LabelUnregistered

```solidity
event LabelUnregistered(uint256 indexed tokenId, address indexed sender);
```

**Emitted by**: `IRegistryEvents` (on `PermissionedRegistry`, `UserRegistry`)

**When**: A label is explicitly deleted via `unregister()`. The ERC1155 token is burned and the expiry is set to `block.timestamp`.

---

### ExpiryUpdated

```solidity
event ExpiryUpdated(uint256 indexed tokenId, uint64 newExpiry, address indexed sender);
```

**Emitted by**: `IRegistry` (on `PermissionedRegistry`, `UserRegistry`)

**When**: A name's expiry is extended via `renew()` on the registry.

---

### SubregistryUpdated

```solidity
event SubregistryUpdated(
    uint256 indexed tokenId,
    IRegistry subregistry,
    address indexed sender
);
```

**Emitted by**: `IRegistry` (on `PermissionedRegistry`, `UserRegistry`)

**When**: A name's child registry is set or changed via `setSubregistry()`. This also fires during `register()` if a subregistry is provided. New subregistry addresses indicate dynamically deployed `UserRegistry` contracts for subnames.

---

### ResolverUpdated

```solidity
event ResolverUpdated(uint256 indexed tokenId, address resolver, address indexed sender);
```

**Emitted by**: `IRegistry` (on `PermissionedRegistry`, `UserRegistry`)

**When**: A name's resolver is set or changed via `setResolver()`. Also fires during `register()`. New resolver addresses indicate dynamically deployed `PermissionedResolver` contracts.

---

### TokenRegenerated

```solidity
event TokenRegenerated(uint256 indexed oldTokenId, uint256 indexed newTokenId);
```

**Emitted by**: `IRegistry` (on `PermissionedRegistry`, `UserRegistry`)

**When**: A name's EAC roles are modified via `grantRoles()` or `revokeRoles()`. The ERC1155 token ID changes to encode the new role configuration, while the underlying name (canonical ID / resource) remains the same. Always accompanied by ERC1155 `TransferSingle` events (burn old + mint new).

---

### ParentUpdated

```solidity
event ParentUpdated(IRegistry indexed parent, string label, address indexed sender);
```

**Emitted by**: `IRegistry` (on `PermissionedRegistry`, `UserRegistry`)

**When**: A registry's parent reference is set via `setParent()`. This establishes the upward link in the registry hierarchy, complementing `SubregistryUpdated` (which links parent→child) by establishing the child→parent direction.

---

### TokenResource

```solidity
event TokenResource(uint256 indexed tokenId, uint256 indexed resource);
```

**Emitted by**: `IPermissionedRegistry`

**When**: A token is created or regenerated. Maps a `tokenId` to its stable `resource` (canonical ID). The `resource` is derived from the `labelHash` and remains constant across token regenerations, making it the stable identifier for a name within a registry.

---

## ERC1155 Transfer Events

These standard ERC1155 events are emitted by all registries (which extend `ERC1155Singleton`).

### TransferSingle

```solidity
event TransferSingle(
    address indexed operator,
    address indexed from,
    address indexed to,
    uint256 id,
    uint256 value
);
```

**When**:
- **Registration (mint)**: `from = address(0)`, `to = owner` — a new name token is minted
- **Transfer**: `from = previousOwner`, `to = newOwner` — ownership changes via `safeTransferFrom()`
- **Unregistration (burn)**: `from = owner`, `to = address(0)` — name token is burned
- **Token regeneration**: Two events fire — burn old tokenId + mint new tokenId. Correlate with `TokenRegenerated` to avoid treating it as a separate domain.

### TransferBatch

```solidity
event TransferBatch(
    address indexed operator,
    address indexed from,
    address indexed to,
    uint256[] ids,
    uint256[] values
);
```

**When**: Batch transfers of multiple name tokens. Same semantics as `TransferSingle` but for multiple tokens at once.

---

## Registrar Events

These events are emitted by the `ETHRegistrar` contract, which is the user-facing entry point for `.eth` name registration (with commit-reveal and pricing).

### CommitmentMade

```solidity
event CommitmentMade(bytes32 commitment);
```

**Emitted by**: `IETHRegistrar`

**When**: Step 1 of the commit-reveal registration via `commit()`. The commitment hash can be matched to the subsequent registration.

---

### NameRegistered (Registrar)

```solidity
event NameRegistered(
    uint256 indexed tokenId,
    string label,
    address owner,
    IRegistry subregistry,
    address resolver,
    uint64 duration,
    IERC20 paymentToken,
    bytes32 referrer,
    uint256 base,
    uint256 premium
);
```

**Emitted by**: `IETHRegistrar`

**When**: Step 2 of the commit-reveal registration via `register()`. This is distinct from the registry's `LabelRegistered` event — the registrar emits its own event with pricing information, and the underlying `ETHRegistry` also emits `LabelRegistered`.

> **Note**: Both events fire for the same registration. The registrar event has pricing data; the registry event has the canonical registration data.

---

### NameRenewed

```solidity
event NameRenewed(
    uint256 indexed tokenId,
    string label,
    uint64 duration,
    uint64 newExpiry,
    IERC20 paymentToken,
    bytes32 referrer,
    uint256 base
);
```

**Emitted by**: `IETHRegistrar`

**When**: A `.eth` name is renewed via `renew()`. The registrar also calls `renew()` on the ETHRegistry, which emits `ExpiryUpdated`.

---

## Resolver Events

These events are emitted by resolver contracts (`PermissionedResolver`) and any contract implementing the standard resolver profile interfaces. Resolvers are keyed by `node` (namehash of the full name).

### AddressChanged

```solidity
event AddressChanged(bytes32 indexed node, uint256 coinType, bytes newAddress);
```

**Emitted by**: `IAddressResolver` (on `PermissionedResolver`)

**When**: An address record is set via `setAddr(node, coinType, address)`. `coinType = 60` is ETH. Other coin types follow [SLIP-44](https://github.com/AdrianSimionov/slip-0044/blob/main/slip-0044.md) (e.g., 0 = BTC, 501 = SOL). The `node` maps to a domain via namehash.

---

### TextChanged

```solidity
event TextChanged(
    bytes32 indexed node,
    string indexed indexedKey,
    string key,
    string value
);
```

**Emitted by**: `ITextResolver` (on `PermissionedResolver`)

**When**: A text record is set via `setText(node, key, value)`. Common keys: `avatar`, `url`, `description`, `com.twitter`, `com.github`, `email`, etc.

---

### ContenthashChanged

```solidity
event ContenthashChanged(bytes32 indexed node, bytes hash);
```

**Emitted by**: `IContentHashResolver` (on `PermissionedResolver`)

**When**: A content hash is set via `setContenthash(node, hash)`. Supports IPFS, Arweave, Swarm, etc.

---

### ABIChanged

```solidity
event ABIChanged(bytes32 indexed node, uint256 indexed contentType);
```

**Emitted by**: `IABIResolver` (on `PermissionedResolver`)

**When**: An ABI record is set.

---

### PubkeyChanged

```solidity
event PubkeyChanged(bytes32 indexed node, bytes32 x, bytes32 y);
```

**Emitted by**: `IPubkeyResolver` (on `PermissionedResolver`)

**When**: A public key record is set (secp256k1 x,y coordinates).

---

### NameChanged

```solidity
event NameChanged(bytes32 indexed node, string name);
```

**Emitted by**: `INameResolver` (on `PermissionedResolver`)

**When**: A reverse name record is set.

---

### InterfaceChanged

```solidity
event InterfaceChanged(
    bytes32 indexed node,
    bytes4 indexed interfaceID,
    address implementer
);
```

**Emitted by**: `IInterfaceResolver` (on `PermissionedResolver`)

**When**: An EIP-165 interface implementer is set.

---

### VersionChanged

```solidity
event VersionChanged(bytes32 indexed node, uint64 newVersion);
```

**Emitted by**: `IVersionableResolver` (on `PermissionedResolver`)

**When**: All records for a node are cleared via `clearRecords(node)`. The version counter is incremented, invalidating all previously stored records for that node.

---

### AliasChanged

```solidity
event AliasChanged(
    bytes indexed indexedFromName,
    bytes indexed indexedToName,
    bytes fromName,
    bytes toName
);
```

**Emitted by**: `IPermissionedResolver` (on `PermissionedResolver`)

**When**: An alias is set via `setAlias(fromName, toName)`. Names are DNS-encoded. Setting `toName` to empty bytes removes the alias. The resolver rewrites the suffix during resolution (e.g., if `alias.eth -> test.eth`, then `sub.alias.eth` resolves records for `sub.test.eth`). Aliases are resolver-level constructs — the registry does not know about them.

---

### NamedResource

```solidity
event NamedResource(uint256 indexed resource, bytes name);
```

**Emitted by**: `PermissionedResolver`

**When**: An EAC resource is associated with a name for fine-grained permission control on the resolver.

---

### NamedTextResource

```solidity
event NamedTextResource(uint256 indexed resource, bytes name, bytes32 indexed keyHash, string key);
```

**Emitted by**: `PermissionedResolver`

**When**: An EAC resource is associated with a specific text record key for a name, allowing fine-grained permission to modify only a specific text record (e.g., only the `avatar` key).

---

### NamedAddrResource

```solidity
event NamedAddrResource(uint256 indexed resource, bytes name, uint256 indexed coinType);
```

**Emitted by**: `PermissionedResolver`

**When**: An EAC resource is associated with a specific address coin type for a name, allowing fine-grained permission to modify only a specific address record (e.g., only the ETH address).

---

## Access Control Events

ENSv2 uses Enhanced Access Control (EAC) with bitmap-based roles. Role changes emit `EACRolesChanged` and trigger `TokenRegenerated` (documented above). For full details on the role system, see [Access Control](https://github.com/ensdomains/contracts-v2/tree/main/contracts#access-control).

---

## Key Concepts for Indexers

### Dynamic Contract Discovery

An indexer cannot know all contract addresses at startup. The core pattern is:

1. Start by watching the **RootRegistry** and **ETHRegistry** (known addresses from deployment).
2. When a `SubregistryUpdated` event fires with a new subregistry address, add that address to the watch list.
3. When a `ResolverUpdated` event fires with a new resolver address, add that address to the watch list for resolver events.

This creates a self-expanding set of monitored contracts.

### TokenId vs Resource (Canonical ID)

- **tokenId**: The ERC1155 token ID. Changes when roles are modified (`TokenRegenerated`). Encodes role configuration.
- **resource**: The stable canonical identifier for a name within a registry. Derived from the `labelHash`. Does not change across role modifications or re-registrations.

Use the `TokenResource` event to maintain the mapping. The `resource` should be the primary key for domain lookups.

### Name Construction

The indexer must track the registry hierarchy to construct full names:

1. **ETHRegistry** emits `LabelRegistered` with `label = "test"` -> full name is `"test.eth"`
2. A `SubregistryUpdated` on `test.eth` points to `UserRegistry` at address `0xABC`
3. That `UserRegistry` emits `LabelRegistered` with `label = "sub"` -> full name is `"sub.test.eth"`

The indexer must map each registry address to its parent name to build the complete DNS name.

### Shared Subregistries (Linked Names)

Multiple parent names can point to the same subregistry via `setSubregistry()`. For example:

- `sub1.sub2.parent.eth` has subregistry at `0xABC`
- `linked.parent.eth` also has subregistry at `0xABC`

Children registered in `0xABC` appear under both parents. The token `wallet` in registry `0xABC` is simultaneously `wallet.sub1.sub2.parent.eth` and `wallet.linked.parent.eth` — they share the same tokenId.

### Alias Resolution

Aliases are a resolver-level concept, not a registry-level one:

- `alias.eth` and `test.eth` may share the same resolver
- The resolver stores: `alias.eth -> test.eth` alias mapping
- When resolving `sub.alias.eth`, the resolver rewrites it to `sub.test.eth` and returns those records
- The registry hierarchy knows nothing about aliases — they exist only in the resolver's storage

### Registration Status

Names can be in one of three states (from `IPermissionedRegistry.Status`):

| Status | Value | Description |
|--------|-------|-------------|
| `AVAILABLE` | 0 | Name can be registered |
| `RESERVED` | 1 | Name is reserved (cannot be registered until expiry, unless caller has `ROLE_REGISTER_RESERVED`) |
| `REGISTERED` | 2 | Name is actively registered with an owner |

After expiry, names return to `AVAILABLE`. Re-registration creates a new `tokenId` but keeps the same `resource`.

### Event Processing Order

For a single registration via `ETHRegistrar.register()`, events fire in this order:

1. `IETHRegistrar.NameRegistered` — registrar-level event with pricing
2. `IRegistryEvents.LabelRegistered` — registry-level event with registration details
3. `TokenResource` — tokenId-to-resource mapping
4. `TransferSingle` (mint) — ERC1155 token creation
5. `SubregistryUpdated` — if a subregistry was provided
6. `ResolverUpdated` — if a resolver was provided

For a direct `IStandardRegistry.register()` call (e.g., on a UserRegistry):

1. `IRegistryEvents.LabelRegistered`
2. `TokenResource`
3. `TransferSingle` (mint)
4. `SubregistryUpdated` — if a subregistry was provided
5. `ResolverUpdated` — if a resolver was provided

---

## Contract Address Summary

| Contract | Role | Events to Watch |
|----------|------|----------------|
| `PermissionedRegistry` (ETHRegistry) | Manages `.eth` names | All `IRegistryEvents` events (incl. `ParentUpdated`), `TokenResource`, ERC1155 transfers |
| `PermissionedRegistry` (RootRegistry) | Manages TLDs | Same as above |
| `UserRegistry` | Manages subnames (dynamically deployed) | Same as above |
| `ETHRegistrar` | User-facing `.eth` registration | `CommitmentMade`, `NameRegistered`, `NameRenewed` |
| `PermissionedResolver` | Stores resolver records (dynamically deployed) | `AddressChanged`, `TextChanged`, `ContenthashChanged`, `ABIChanged`, `PubkeyChanged`, `NameChanged`, `InterfaceChanged`, `VersionChanged`, `AliasChanged`, `NamedResource`, `NamedTextResource`, `NamedAddrResource` |

---

## Read Functions for State Verification

These view functions are useful for verifying indexed state or backfilling data:

### Registry State

```solidity
// Get full state of a name (status, expiry, owner, tokenId, resource)
function getState(uint256 anyId) external view returns (State memory);

// Get the subregistry for a label
function getSubregistry(string calldata label) external view returns (IRegistry);

// Get the resolver for a label
function getResolver(string calldata label) external view returns (address);

// Get the owner of a token
function ownerOf(uint256 tokenId) external view returns (address);

// Get the stable resource ID
function getResource(uint256 anyId) external view returns (uint256);

// Get the current tokenId (may change after role modifications)
function getTokenId(uint256 anyId) external view returns (uint256);

// Get the expiry
function getExpiry(uint256 anyId) external view returns (uint64);
```

### Registrar State

```solidity
// Check if a name is available for registration
function isAvailable(string memory label) external view returns (bool);

// Get rental price
function rentPrice(string memory label, address buyer, uint64 duration, IERC20 paymentToken)
    external view returns (uint256 base, uint256 premium);
```

### Resolver State

```solidity
// Get address record
function addr(bytes32 node, uint256 coinType) external view returns (bytes memory);

// Get text record
function text(bytes32 node, string calldata key) external view returns (string memory);

// Get content hash
function contenthash(bytes32 node) external view returns (bytes memory);

// Get alias
function getAlias(bytes calldata name) external view returns (bytes memory);
```

