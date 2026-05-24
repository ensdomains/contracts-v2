# Setting a Primary Name

How to configure a primary name (reverse resolution) so that an address resolves back to a human-readable name.

## What is a Primary Name?

A primary name is the canonical ENS name for an address. When a dApp shows `myname.eth` next to your wallet address, it's using primary name resolution. This requires both directions to be configured:

- **Forward**: the name's address record points to the address
- **Reverse**: the reverse registrar maps the address back to the name

If only one direction is set, the primary name is considered invalid.

## Two-Step Setup

### Step 1: Set the forward record (name → address)

Set the name's `addr` record to point to your address on the **PermissionedResolver**:

```typescript
import { namehash } from "viem";

const node = namehash("myname.eth");

await walletClient.writeContract({
  address: permissionedResolverAddress,
  abi: [{
    name: 'setAddr',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'node', type: 'bytes32' },
      { name: 'coinType', type: 'uint256' },
      { name: 'addressBytes', type: 'bytes' },
    ],
    outputs: [],
  }],
  functionName: "setAddr",
  args: [node, 60n, myAddress],  // coinType 60 = ETH
});
```

- **Role required**: `ROLE_SET_ADDR` on the resolver
- **Event**: `AddressChanged(node, 60, addressBytes)` + `AddrChanged(node, addr)`

### Step 2: Set the reverse record (address → name)

Call `setName()` on the **ETHReverseRegistrar** to register your address → name mapping:

```typescript
await walletClient.writeContract({
  address: ethReverseRegistrarAddress,
  abi: [{
    name: 'setName',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'name', type: 'string' }],
    outputs: [],
  }],
  functionName: "setName",
  args: ["myname.eth"],
});
```

- **Authorization**: `msg.sender` is the address being registered (no roles needed)
- **Events**: `LabelRegistered(...)`, `ResolverUpdated(...)`, `NameChanged(node, name)`

## Verification

The `UniversalResolverV2.reverse(address, coinType)` verifies both directions:

1. Looks up the reverse record for the address → finds `"myname.eth"`
2. Forward-resolves `myname.eth` → checks the ETH address matches the queried address
3. Returns the name only if both match

```typescript
const [name, resolvedAddress, resolverAddress] = await publicClient.readContract({
  address: universalResolverAddress,
  abi: [{
    name: 'reverse',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'lookupAddress', type: 'bytes' },
      { name: 'coinType', type: 'uint256' },
    ],
    outputs: [
      { name: '', type: 'string' },
      { name: '', type: 'address' },
      { name: '', type: 'address' },
    ],
  }],
  functionName: "reverse",
  args: [dnsEncodedReverseAddress, 60n],
});
```

## Alternative `setName` Methods

The `L2ReverseRegistrar` (which the `ETHReverseRegistrar` implements) supports several ways to set the primary name:

| Method | Description |
|---|---|
| `setName(string)` | Sets name for `msg.sender` |
| `setNameForAddr(address, string)` | Sets name for a different address (requires `authorized(addr)` — you must be the addr or its Ownable owner) |
| `setNameForAddrWithSignature(NameClaim, bytes)` | Relayer sets name using a signed message from the address (supports ERC-1271 and ERC-6492) |
| `setNameForOwnableWithSignature(NameClaim, address, bytes)` | Relayer sets name for an Ownable contract using the owner's signature |
| `syncName(address)` | Copies the name from `IContractName(addr).contractName()` — callable by anyone |

### Signature-based claim

For gasless or relayed primary name setting, use `setNameForAddrWithSignature`:

```typescript
const claim = {
  name: "myname.eth",
  addr: myAddress,
  chainIds: [1n],          // chain IDs this claim is valid for
  signedAt: BigInt(Math.floor(Date.now() / 1000)),
};

// Sign the claim off-chain, then submit via relayer
await walletClient.writeContract({
  address: ethReverseRegistrarAddress,
  abi: IL2ReverseRegistrarABI,
  functionName: "setNameForAddrWithSignature",
  args: [claim, signature],
});
```

The `signedAt` must be greater than `inceptionOf(addr)` to prevent replay attacks.

## Clearing a Primary Name

To remove the reverse mapping, set the name to an empty string:

```typescript
await walletClient.writeContract({
  address: ethReverseRegistrarAddress,
  abi: IL2ReverseRegistrarABI,
  functionName: "setName",
  args: [""],
});
```

To fully clean up, also clear the forward record:

```typescript
const node = namehash("myname.eth");
await permissionedResolver.write.setAddr([node, 60n, "0x"]);
```

## Important: `PermissionedResolver.setName()` vs `ETHReverseRegistrar.setName()`

These are two **different functions** on different contracts:

| | PermissionedResolver | ETHReverseRegistrar |
|---|---|---|
| **Signature** | `setName(bytes32 node, string name)` | `setName(string name)` |
| **Purpose** | Stores a `name` record on a node (INameResolver) | Sets the address → name reverse mapping |
| **Used for** | Legacy v1-style reverse, or arbitrary name records | Primary name setup in v2 |
| **Scope** | Per-node record on a specific resolver | Global for `msg.sender` |

For v2 primary names, always use the **ETHReverseRegistrar**.

## Summary

| Step | Contract | Function | Purpose |
|---|---|---|---|
| 1 | PermissionedResolver | `setAddr(node, 60, address)` | Forward: name → address |
| 2 | ETHReverseRegistrar | `setName("myname.eth")` | Reverse: address → name |

Both must be set for a valid primary name. The `UniversalResolverV2.reverse()` verifies the bidirectional link.
