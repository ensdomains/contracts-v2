# Names and Nodes

The difference between names and nodes in ENS, and where each is used.

## Name (human-readable)

A **name** is the dotted string you see: `myname.eth`, `sub.myname.eth`, `eth`.

There are two encoded forms:

- **Dotted string**: `"myname.eth"` — used in UIs and some function parameters (e.g., `register("myname", ...)`).
- **DNS-encoded** (wire format): `0x066d796e616d650365746800` — length-prefixed labels terminated by `\x00`. Used by `setAlias`, `resolve`, `getAlias`, and the `grantNameRoles` / `grantTextRoles` / `grantAddrRoles` functions.

### DNS encoding

Each label is prefixed with its byte length, and the whole name is terminated by a zero byte:

| Human name | DNS-encoded (hex) | Breakdown |
|---|---|---|
| `eth` | `0x03657468 00` | `\x03` + "eth" + `\x00` |
| `myname.eth` | `0x066d796e616d65 03657468 00` | `\x06` + "myname" + `\x03` + "eth" + `\x00` |
| `sub.myname.eth` | `0x03737562 066d796e616d65 03657468 00` | `\x03` + "sub" + `\x06` + "myname" + `\x03` + "eth" + `\x00` |
| `` (root) | `0x00` | `\x00` |

## Node (bytes32 hash)

A **node** is the `bytes32` namehash of a name — a deterministic hash computed by recursively hashing labels from right to left:

```
namehash("")           = 0x0000000000000000000000000000000000000000000000000000000000000000
namehash("eth")        = keccak256(namehash("") + keccak256("eth"))
namehash("myname.eth") = keccak256(namehash("eth") + keccak256("myname"))
```

The result is a fixed-size 32-byte value. The hashing is **one-way** — you cannot recover the name from a node.

### Labelhash

A **labelhash** is a simpler hash of a single label: `keccak256("myname")`. It's used by registries for registration and unregistration, since registries only manage one level of the hierarchy at a time.

## Where each is used

| Context | Uses name | Uses node |
|---|---|---|
| Registry `register()` | `string label` (just the label, e.g. `"myname"`) | — |
| Registry `unregister()` | — | `uint256 anyId` (labelhash or tokenId) |
| Resolver read methods | — | `bytes32 node` (e.g. `addr(node)`, `text(node, key)`) |
| Resolver write methods | — | `bytes32 node` (e.g. `setAddr(node, ...)`, `setText(node, ...)`) |
| Aliases (`setAlias`, `getAlias`) | `bytes` DNS-encoded name | — |
| Role granting (`grantNameRoles`, `grantTextRoles`, `grantAddrRoles`) | `bytes` DNS-encoded name | — |
| `resolve(name, data)` | `bytes` DNS-encoded name | node is embedded in `data` |
| EAC resources | — | `resource(node, part)` — derived from node |
| `multicall` / `multicallWithNodeCheck` | — | node in individual call payloads |

## Converting between names and nodes

In viem / TypeScript:

```typescript
import { namehash, keccak256, toHex } from "viem";

// Name → node
const node = namehash("myname.eth");
// "0x6cbc8d..."

// Label → labelhash
const labelHash = keccak256(toHex("myname"));
// "0x..."
```

In Solidity (using `NameCoder` from the ENS contracts):

```solidity
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

// DNS-encoded name → node
bytes32 node = NameCoder.namehash(dnsEncodedName, 0);

// Single label → labelhash
bytes32 labelHash = keccak256(abi.encodePacked("myname"));
```

## Primary name (reverse resolution)

Setting a primary name requires two records that link the name and address in both directions:

1. **Forward**: set the name's addr record to point to the address.
   Call `setAddr(namehash("myname.eth"), 60, yourAddress)` on the **PermissionedResolver**.

2. **Reverse**: register the address → name mapping.
   Call `setName("myname.eth")` on the **ETHReverseRegistrar** (`L2ReverseRegistrar` / `StandaloneReverseRegistrar`).

Both must be in place for the `UniversalResolverV2.reverse(address, coinType)` to return a valid primary name. It checks the reverse mapping first, then verifies that forward resolution of that name points back to the same address.

| Step | Contract | Function | Purpose |
|---|---|---|---|
| 1 | PermissionedResolver | `setAddr(node, 60, address)` | Forward: name → address |
| 2 | ETHReverseRegistrar | `setName("myname.eth")` | Reverse: address → name |

The `PermissionedResolver.setName(node, name)` function is a **different thing** — it stores a `name` record on a node (used by `INameResolver.name(node)` for the old v1 reverse flow). In v2, the reverse mapping is handled by the standalone `ETHReverseRegistrar`, not the resolver.
