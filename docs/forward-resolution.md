# Forward Resolution

How a name like `sub.example.eth` is resolved to an address (or other record) by walking the registry tree.

**Contracts**:
- `contracts/src/universalResolver/UniversalResolverV2.sol`
- `contracts/src/universalResolver/libraries/LibRegistry.sol`
- `contracts/src/registry/PermissionedRegistry.sol`
- `contracts/src/resolver/PermissionedResolver.sol`

## Overview

Forward resolution takes a name and returns its records (ETH address, text records, contenthash, etc.). The process has two phases:

1. **Find the resolver** — walk the registry tree from root to leaf
2. **Query the resolver** — call the resolver with the name and record type

The `UniversalResolverV2` handles both phases automatically.

## The Registry Tree Walk

ENS v2 uses a hierarchy of registries. Each registry manages one level:

```
RootRegistry
  └── "eth" → ETHRegistry
                └── "example" → UserRegistry
                                  └── "sub" → (no subregistry)
```

To resolve `sub.example.eth`, the system walks top-down:

```
1. RootRegistry.getSubregistry("eth")    → ETHRegistry
2. ETHRegistry.getSubregistry("example") → UserRegistry
3. ETHRegistry.getResolver("example")    → PermissionedResolver (stored!)
4. UserRegistry.getSubregistry("sub")    → address(0)  (leaf node)
5. UserRegistry.getResolver("sub")       → address(0)  (no resolver)
```

The resolver found at step 3 is used because step 5 returned nothing. The rule is: **use the last non-zero resolver encountered while walking from root to leaf**.

This is the "wildcard" behavior — a parent's resolver handles all its subnames unless a child explicitly sets its own resolver.

### Implementation: `LibRegistry.findResolver()`

```solidity
function findResolver(
    IRegistry rootRegistry,
    bytes memory name,      // DNS-encoded
    uint256 offset
) internal view returns (
    IRegistry exactRegistry,
    address resolver,
    bytes32 node,
    uint256 resolverOffset
)
```

Recursively walks the registry tree label by label (right-to-left from the DNS-encoded name). At each level, calls `getSubregistry(label)` and `getResolver(label)`, keeping the most recent non-zero resolver.

## Querying the Resolver

Once the resolver is found, the `UniversalResolverV2` calls it. There are two paths:

### Direct call (non-extended resolver)

For resolvers that don't support `IExtendedResolver`, the call goes directly:

```
resolver.addr(node)       → address
resolver.text(node, key)  → string
```

The `node` is the namehash of the full name being resolved.

### Extended resolution (ENSIP-10)

If the resolver supports `IExtendedResolver` (detected via ERC-165), the call is wrapped:

```solidity
resolver.resolve(dnsEncodedName, abi.encodeCall(addr, (node)))
```

This allows the resolver to:
- Apply aliases (rewrite the name before lookup)
- Handle names it doesn't have direct records for
- Support CCIP-Read (off-chain lookups via EIP-3668)

The `PermissionedResolver` uses this path to support aliasing — when you resolve `sub.alias.eth` and there's an alias `alias.eth → test.eth`, the resolver rewrites it to `sub.test.eth` and returns those records.

### CCIP-Read (off-chain lookups)

If a resolver reverts with `OffchainLookup(sender, urls, callData, callback, extraData)`:

1. The `UniversalResolverV2` catches the revert
2. The client fetches data from the provided gateway URLs
3. The client calls back with the gateway response
4. The resolver verifies and returns the final result

This enables resolvers that store data off-chain (e.g., L2 bridges, DNS, external databases).

## Using `UniversalResolverV2`

### `resolve(name, data)` — Single record lookup

```typescript
import { namehash, encodeFunctionData, toHex } from "viem";

const dnsName = dnsEncode("myname.eth");
const calldata = encodeFunctionData({
  abi: [{ name: 'addr', type: 'function', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'address' }], stateMutability: 'view' }],
  functionName: "addr",
  args: [namehash("myname.eth")],
});

const [result, resolverAddress] = await publicClient.readContract({
  address: universalResolverAddress,
  abi: [{
    name: 'resolve',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'name', type: 'bytes' },
      { name: 'data', type: 'bytes' },
    ],
    outputs: [
      { name: '', type: 'bytes' },
      { name: '', type: 'address' },
    ],
  }],
  functionName: "resolve",
  args: [dnsName, calldata],
});
```

### Helper functions on `UniversalResolverV2`

| Method | Returns | Description |
|---|---|---|
| `resolve(bytes name, bytes data)` | `(bytes, address)` | Resolve a single record |
| `findResolver(bytes name)` | `(address, bytes32, uint256)` | Find resolver without querying it |
| `findExactRegistry(bytes name)` | `IRegistry` | Find the registry that directly manages this name |
| `findRegistries(bytes name)` | `IRegistry[]` | Full ancestry chain of registries |
| `findCanonicalName(IRegistry)` | `bytes` | DNS-encoded canonical name for a registry |
| `reverse(bytes addr, uint256 coinType)` | `(string, address, address)` | Reverse resolution (see [Reverse Resolution](./reverse-resolution.md)) |

### `findRegistries` — Registry ancestry

```typescript
// Returns: [subRegistry or null, UserRegistry, ETHRegistry, RootRegistry]
const registries = await universalResolver.read.findRegistries([
  dnsEncode("sub.example.eth"),
]);
```

## Direct Resolution (without UniversalResolverV2)

If you already know the resolver address for a name, you can query it directly:

```typescript
import { namehash } from "viem";

const node = namehash("myname.eth");

// Direct addr lookup
const addr = await publicClient.readContract({
  address: resolverAddress,
  abi: [{ name: 'addr', type: 'function', inputs: [{ type: 'bytes32' }, { type: 'uint256' }], outputs: [{ type: 'bytes' }], stateMutability: 'view' }],
  functionName: "addr",
  args: [node, 60n],  // coinType 60 = ETH
});

// Direct text lookup
const avatar = await publicClient.readContract({
  address: resolverAddress,
  abi: [{ name: 'text', type: 'function', inputs: [{ type: 'bytes32' }, { type: 'string' }], outputs: [{ type: 'string' }], stateMutability: 'view' }],
  functionName: "text",
  args: [node, "avatar"],
});
```

Direct calls bypass aliasing. To get alias-aware resolution, use `resolve(dnsName, data)` on the resolver.

## Resolution with Aliases

When a `PermissionedResolver` has an alias set (e.g., `alias.eth → test.eth`), the extended `resolve()` function:

1. Calls `getAlias(fromName)` to follow the alias chain
2. Rewrites the node in the calldata to match the destination name
3. Calls itself with the rewritten data
4. Returns records from the aliased name transparently

```
resolve("sub.alias.eth", addr(namehash("sub.alias.eth")))
  → alias rewrites to "sub.test.eth"
  → returns addr(namehash("sub.test.eth"))
```

See [Aliases](./aliases.md) for details on setting up aliases.

## Expired Names

If a name is expired, the registry returns `address(0)` from both `getSubregistry()` and `getResolver()`. This breaks the tree walk — the name and all its subnames become unresolvable even if child registries still exist.

## Key Interfaces

| Interface | Contract | Purpose |
|---|---|---|
| `IRegistry` | All registries | `getSubregistry(label)`, `getResolver(label)`, `getParent()` |
| `IExtendedResolver` | PermissionedResolver | `resolve(name, data)` — alias-aware resolution |
| `IUniversalResolver` | UniversalResolverV2 | `resolve(name, data)`, `reverse(addr, coinType)` |
| `IERC7996` | PermissionedResolver | `supportsFeature(feature)` — optimizes resolution path |
