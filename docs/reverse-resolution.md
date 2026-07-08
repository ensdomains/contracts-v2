# Reverse Resolution

How an address is resolved back to a name using the reverse registrar system.

**Contracts**:
- `contracts/src/reverse-registrar/StandaloneReverseRegistrar.sol` (abstract base)
- `contracts/src/reverse-registrar/L2ReverseRegistrar.sol` (implementation)
- `contracts/src/reverse-registrar/interfaces/IL2ReverseRegistrar.sol`
- `contracts/src/universalResolver/UniversalResolverV2.sol`

## Overview

Reverse resolution maps an address to its primary ENS name. Unlike forward resolution which walks the registry tree, reverse resolution uses a dedicated **reverse registrar** that stores `address → name` mappings.

The reverse registrar is a standalone contract, detached from the main ENS registry hierarchy. It lives under the `reverse` TLD (e.g., `60.reverse` for Ethereum mainnet).

## Architecture

```
UniversalResolverV2.reverse(address, coinType)
  │
  │  Looks up: <addressHex>.60.reverse
  ▼
ETHReverseRegistrar (L2ReverseRegistrar)
  │
  │  _names[node] → "myname.eth"
  │
  │  Then verifies forward resolution:
  ▼
PermissionedResolver.addr(namehash("myname.eth"), 60)
  │
  │  → must match the queried address
  ▼
Returns: ("myname.eth", address, resolverAddress)
```

## How the Reverse Registrar Works

### Node computation

The reverse registrar computes a unique node for each address:

```
PARENT_NODE = namehash("60.reverse")    // for Ethereum mainnet (coin type 60)

addressLabel = lowercase hex of address (no 0x prefix)
              e.g., "d8da6bf26964af9d7eed9e03e53415d37aa96045"

reverseNode = keccak256(abi.encodePacked(PARENT_NODE, keccak256(addressLabel)))
```

### Storage

The primary name is stored in a simple mapping:

```solidity
mapping(bytes32 node => string name) internal _names;
```

### Setting a name

When `setName("myname.eth")` is called:

1. Converts `msg.sender` to lowercase hex string (the label)
2. Computes `node = keccak256(PARENT_NODE, keccak256(label))`
3. Stores `_names[node] = "myname.eth"`
4. Emits ENSIP-16 registry events: `LabelRegistered`, `ResolverUpdated`, `NameChanged`

### Reading a name

Two ways to read:

```solidity
// By address (convenience)
function nameForAddr(address addr) external view returns (string memory);

// By reverse node (INameResolver, used by UniversalResolverV2)
function name(bytes32 node) external view returns (string memory);
```

## The ETHReverseRegistrar

The `ETHReverseRegistrar` is deployed from `L2ReverseRegistrar` with coin type 60. Despite the "L2" in the name, it's used on all chains (L1 and L2).

### Write methods

| Method | Who can call | Description |
|---|---|---|
| `setName(string)` | Anyone (sets for `msg.sender`) | Set your own primary name |
| `setNameForAddr(address, string)` | The address itself, or the Ownable owner | Set primary name for another address |
| `setNameForAddrWithSignature(NameClaim, bytes)` | Anyone (relayer) | Set name via signed message (ERC-1271 / ERC-6492) |
| `setNameForOwnableWithSignature(NameClaim, address, bytes)` | Anyone (relayer) | Set name for Ownable contract via owner's signature |
| `syncName(address)` | Anyone | Copy name from `IContractName(addr).contractName()` |

### Read methods

| Method | Description |
|---|---|
| `nameForAddr(address)` | Primary name for an address |
| `name(bytes32 node)` | Primary name by reverse node |
| `resolve(bytes name, bytes data)` | ENSIP-10 extended resolution for reverse names |
| `inceptionOf(address)` | Replay-protection timestamp |

### Signature-based claims

The `NameClaim` struct for gasless name setting:

```solidity
struct NameClaim {
    string name;        // the primary name to set
    address addr;       // the address to set it for
    uint256[] chainIds; // chain IDs this claim is valid for
    uint256 signedAt;   // timestamp (must be > inceptionOf(addr))
}
```

Supports EOA signatures, ERC-1271 (smart contract wallets), and ERC-6492 (counterfactual signatures).

## Using `UniversalResolverV2.reverse()`

The universal resolver handles the full reverse resolution flow:

```typescript
// DNS-encode the reverse lookup address
// Format: <hex address>.60.reverse in DNS wire format
const lookupAddress = dnsEncode(
  `${myAddress.slice(2).toLowerCase()}.60.reverse`
);

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
  args: [lookupAddress, 60n],
});
// name = "myname.eth"
// resolvedAddress = the address that myname.eth resolves to (must match)
// resolverAddress = the resolver used for forward verification
```

The universal resolver performs **bidirectional verification**:
1. Looks up reverse record for the address → gets the name
2. Forward-resolves the name → gets the address
3. Only returns the name if both directions match

## Direct Reverse Lookup (without UniversalResolverV2)

```typescript
// Read primary name directly from the reverse registrar
const name = await publicClient.readContract({
  address: ethReverseRegistrarAddress,
  abi: [{
    name: 'nameForAddr',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'addr', type: 'address' }],
    outputs: [{ name: '', type: 'string' }],
  }],
  functionName: "nameForAddr",
  args: [myAddress],
});
```

This returns the stored name without bidirectional verification. Use `UniversalResolverV2.reverse()` for verified primary names.

## Events

When `setName` is called, these events are emitted:

| Event | Source | Description |
|---|---|---|
| `LabelRegistered(tokenId, labelHash, label, addr, expiry, sender)` | `IRegistryEvents` | ENSIP-16 compatible registration event |
| `ResolverUpdated(tokenId, resolver, sender)` | `IRegistryEvents` | Resolver is `address(this)` (the reverse registrar itself) |
| `NameChanged(node, name)` | `INameResolver` | The primary name for this reverse node |

The reverse registrar acts as both a registry and a resolver — it stores the name and resolves it.

## Chain-Specific Reverse Registrars

Each chain has its own reverse registrar under a chain-specific label:

| Chain | Label | Parent node |
|---|---|---|
| Ethereum (coin type 60) | `60` | `namehash("60.reverse")` |
| Other L2s | chain-specific | `namehash("<label>.reverse")` |

The label is derived from the coin type (e.g., `60` for Ethereum). The `L2ReverseRegistrarWithMigration` variant can batch-migrate names from a v1 reverse registrar.

## Related

- [Setting a Primary Name](./primary-name.md) — Step-by-step setup guide
- [Forward Resolution](./forward-resolution.md) — How names resolve to records
- [Names and Nodes](./names-and-nodes.md) — Name encoding and namehash
