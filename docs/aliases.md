# Aliases

How to create, read, delete, and use internal aliases on the PermissionedResolver.

**Contract**: `contracts/src/resolver/PermissionedResolver.sol`

## Overview

An alias redirects resolution from one name to another inside the same resolver. When a name (or any subdomain of it) is resolved, the resolver swaps the matching suffix and looks up records under the destination name instead — without duplicating data.

## Functions

### `setAlias(bytes fromName, bytes toName)`

Creates or updates an alias.

- **Role**: `ROLE_SET_ALIAS` (`1 << 28`) on `ROOT_RESOURCE` only — global operation, not per-name
- **Parameters**: Both names must be **DNS-encoded** (wire format)
- **Event**: `AliasChanged(bytes indexed indexedFromName, bytes indexed indexedToName, bytes fromName, bytes toName)`
- **Storage**: `aliases[namehash(fromName)] = toName`

### `getAlias(bytes fromName) → bytes toName`

Reads the alias chain for a name. Returns empty bytes if no alias exists.

- Walks the name suffix-first and finds the longest matching alias
- Recursively follows chains (cycle-safe for length 1; cycles of length 2+ result in OOG)
- Subdomains are automatically rewritten (prefix preserved, suffix swapped)

### Deleting an alias

Set `toName` to empty bytes:

```solidity
setAlias(dnsEncode("a.eth"), "");
```

## DNS Encoding

Both `fromName` and `toName` must be DNS wire format — length-prefixed labels terminated by a zero byte:

| Human name | DNS-encoded (hex) | Breakdown |
|---|---|---|
| `eth` | `0x03657468 00` | `\x03` + "eth" + `\x00` |
| `test.eth` | `0x04746573740365746800` | `\x04` + "test" + `\x03` + "eth" + `\x00` |
| `sub.test.eth` | `0x037375620474657374036574 6800` | `\x03` + "sub" + `\x04` + "test" + `\x03` + "eth" + `\x00` |
| `` (root) | `0x00` | `\x00` |

In viem, use `toHex(stringToBytes(...))` or the ENS `dnsEncodeName` utility.

## Alias Behavior — Suffix Matching

The alias replaces the **longest matching suffix**. Subdomains of the source are automatically rewritten:

```
setAlias("a.eth", "b.eth")

getAlias("a.eth")       → "b.eth"         // exact match
getAlias("sub.a.eth")   → "sub.b.eth"     // prefix preserved, suffix swapped
getAlias("x.y.a.eth")   → "x.y.b.eth"    // multi-level prefix
getAlias("abc.eth")     → ""              // no match (different name)
```

## Recursive Aliasing

Aliases chain automatically:

```
setAlias("ens.xyz", "com")
setAlias("com", "eth")

getAlias("test.ens.xyz") → "test.eth"    // ens.xyz → com → eth
```

**Cycle protection:**
- Cycles of length 1 apply once and stop
- Cycles of length 2+ will run out of gas (OOG)

## How Aliases Work During Resolution

When `resolve(name, data)` is called on the PermissionedResolver:

1. `getAlias(name)` follows the alias chain
2. If an alias is found, the `node` (namehash) in the calldata is rewritten to match the destination name
3. The rewritten call is executed via `staticcall` on the resolver itself
4. The caller gets records from the aliased name transparently

This means you store records under one name and have other names serve those same records.

## Use Cases

| Use case | Alias | Effect |
|---|---|---|
| TLD aliasing | `setAlias("com", "eth")` | All `*.com` queries resolve as `*.eth` |
| Name migration | `setAlias("old.eth", "new.eth")` | Old name transparently serves new name's records |
| Shared records | `setAlias("brand.eth", "main.eth")` | Multiple names point to one set of records |
| Wildcard subdomains | `setAlias("", "base.eth")` | Root alias so everything resolves under `base.eth` |

## ABI Snippets

```typescript
export const permissionedResolverAliasSnippet = [
  {
    name: 'setAlias',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'fromName', type: 'bytes' },
      { name: 'toName', type: 'bytes' },
    ],
    outputs: [],
  },
  {
    name: 'getAlias',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'fromName', type: 'bytes' }],
    outputs: [{ name: 'toName', type: 'bytes' }],
  },
] as const
```

## Examples (viem / TypeScript)

### DNS encoding helper

```typescript
function dnsEncode(name: string): Uint8Array {
  if (name === "") return new Uint8Array([0]);
  const labels = name.split(".");
  const parts: number[] = [];
  for (const label of labels) {
    const encoded = new TextEncoder().encode(label);
    parts.push(encoded.length, ...encoded);
  }
  parts.push(0);
  return new Uint8Array(parts);
}
```

### Create an alias

```typescript
import { toHex } from "viem";

// a.eth → b.eth
// Resolving sub.a.eth will return records for sub.b.eth
await walletClient.writeContract({
  address: permissionedResolverAddress,
  abi: permissionedResolverAliasSnippet,
  functionName: "setAlias",
  args: [toHex(dnsEncode("a.eth")), toHex(dnsEncode("b.eth"))],
});
```

### Read an alias

```typescript
const result = await publicClient.readContract({
  address: permissionedResolverAddress,
  abi: permissionedResolverAliasSnippet,
  functionName: "getAlias",
  args: [toHex(dnsEncode("sub.a.eth"))],
});
// result = dns-encoded bytes for "sub.b.eth"
```

### Delete an alias

```typescript
await walletClient.writeContract({
  address: permissionedResolverAddress,
  abi: permissionedResolverAliasSnippet,
  functionName: "setAlias",
  args: [toHex(dnsEncode("a.eth")), "0x"],
});
```

### Create a recursive alias chain

```typescript
// ens.xyz → com → eth
await walletClient.writeContract({
  address: permissionedResolverAddress,
  abi: permissionedResolverAliasSnippet,
  functionName: "setAlias",
  args: [toHex(dnsEncode("ens.xyz")), toHex(dnsEncode("com"))],
});
await walletClient.writeContract({
  address: permissionedResolverAddress,
  abi: permissionedResolverAliasSnippet,
  functionName: "setAlias",
  args: [toHex(dnsEncode("com")), toHex(dnsEncode("eth"))],
});
// Now resolving test.ens.xyz returns records for test.eth
```

## Indexer Events

| Event | Signature |
|---|---|
| `AliasChanged(bytes indexed indexedFromName, bytes indexed indexedToName, bytes fromName, bytes toName)` | Emitted on every `setAlias` call |

The indexed params are keccak256 hashes of the DNS-encoded names. The actual names are in the non-indexed `fromName` and `toName` fields. When `toName` is empty, the alias was deleted.

## Important Notes

- Aliases are **not enumerable** on-chain. To list all aliases, index `AliasChanged` events.
- Aliases only affect resolution via `resolve()` (the `IExtendedResolver` path). Direct calls to `addr(node)`, `text(node, key)`, etc. are NOT aliased — they read from the exact node you pass.
- The caller needs `ROLE_SET_ALIAS` on `ROOT_RESOURCE`. This cannot be scoped per-name — anyone with this role can alias any name.
- Aliases are stored on the resolver, not the registry. They only apply within a single PermissionedResolver instance.
