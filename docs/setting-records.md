# Setting Records

How to create, update, and clear records on the PermissionedResolver.

**Contract**: `contracts/src/resolver/PermissionedResolver.sol`
**Library**: `contracts/src/resolver/libraries/PermissionedResolverLib.sol`

## Interfaces Implemented

The PermissionedResolver implements these write-side interfaces (from `@ens/contracts/resolvers/profiles/`):

| Interface | Write method |
|---|---|
| `IAddrResolver` | `setAddr(bytes32 node, address addr)` |
| `IAddressResolver` | `setAddr(bytes32 node, uint256 coinType, bytes addressBytes)` |
| `ITextResolver` | `setText(bytes32 node, string key, string value)` |
| `IContentHashResolver` | `setContenthash(bytes32 node, bytes hash)` |
| `INameResolver` | `setName(bytes32 node, string name)` |
| `IABIResolver` | `setABI(bytes32 node, uint256 contentType, bytes data)` |
| `IPubkeyResolver` | `setPubkey(bytes32 node, bytes32 x, bytes32 y)` |
| `IInterfaceResolver` | `setInterface(bytes32 node, bytes4 interfaceId, address implementer)` |
| `IVersionableResolver` | `clearRecords(bytes32 node)` |
| `IMulticallable` | `multicall(bytes[] calls)` |
| `IExtendedResolver` | `resolve(bytes name, bytes data)` (read-only) |

## Authorization Model

Every write method (except `setAlias`) goes through the `onlyPartRoles` modifier:

```
onlyPartRoles(bytes32 node, bytes32 part, uint256 roleBitmap)
```

This checks **three resources in order**, passing on the first match:

1. `resource(node, part)` — exact match (specific name + specific record type)
2. `resource(0, part)` — any name, specific record type
3. `resource(node, 0)` — specific name, any record type

If none match, the call reverts with `EACUnauthorizedAccountRoles`.

Each `hasRoles()` check also implicitly includes `ROOT_RESOURCE` (resource `0`), so a global admin always passes.

### Authorization flow diagram

```
Caller calls setText(node, key, value)
  │
  ├─ part = textPart(key) = keccak256(0x02 ++ keccak256(key))
  │
  ├─ Check 1: hasRoles(resource(node, part), ROLE_SET_TEXT, sender)?
  │            → "Can this sender set this specific text key on this specific name?"
  │            → Also checks ROOT_RESOURCE implicitly
  │            → If yes: PASS ✓
  │
  ├─ Check 2: hasRoles(resource(0, part), ROLE_SET_TEXT, sender)?
  │            → "Can this sender set this specific text key on ANY name?"
  │            → Also checks ROOT_RESOURCE implicitly
  │            → If yes: PASS ✓
  │
  └─ Check 3: hasRoles(resource(node, 0), ROLE_SET_TEXT, sender)?
              → "Can this sender set ANY record on this specific name?"
              → Also checks ROOT_RESOURCE implicitly
              → If yes: PASS ✓
              → If no: REVERT ✗
```

### Which setters use which `part`

| Setter | Part used | Granularity |
|---|---|---|
| `setAddr(node, coinType, bytes)` | `addrPart(coinType)` | Per coin type |
| `setText(node, key, value)` | `textPart(key)` | Per text key |
| `setContenthash(node, hash)` | `0` | Name-level only |
| `setPubkey(node, x, y)` | `0` | Name-level only |
| `setABI(node, contentType, data)` | `0` | Name-level only |
| `setInterface(node, iface, impl)` | `0` | Name-level only |
| `setName(node, name)` | `0` | Name-level only |
| `clearRecords(node)` | `0` | Name-level only |
| `setAlias(from, to)` | N/A | ROOT_RESOURCE only |

Only `setAddr` and `setText` support fine-grained `part`-based permissions. The rest only check at the name level (`part = 0`).

## Write Methods — Detail

### `setAddr(bytes32 node, address addr)`

Sets the Ethereum mainnet address (coin type 60). Delegates to `setAddr(node, COIN_TYPE_ETH, abi.encodePacked(addr))`.

- **Role**: `ROLE_SET_ADDR` (`1 << 0`)
- **Part**: `addrPart(COIN_TYPE_ETH)`
- **Events**: `AddressChanged(node, 60, addressBytes)` + `AddrChanged(node, addr)`

### `setAddr(bytes32 node, uint256 coinType, bytes addressBytes)`

Sets the address for any coin type. Validates that EVM coin types have 0 or 20 byte addresses.

- **Role**: `ROLE_SET_ADDR` (`1 << 0`)
- **Part**: `addrPart(coinType)` — permissions can be scoped per coin type
- **Events**: `AddressChanged(node, coinType, addressBytes)` (+ `AddrChanged` if coinType is ETH)
- **Reverts**: `InvalidEVMAddress` if EVM coin type with non-standard address length

### `setText(bytes32 node, string key, string value)`

Sets a text record.

- **Role**: `ROLE_SET_TEXT` (`1 << 4`)
- **Part**: `textPart(key)` — permissions can be scoped per text key
- **Events**: `TextChanged(node, indexedKey, key, value)`

### `setContenthash(bytes32 node, bytes hash)`

Sets the content hash (IPFS, Swarm, etc.).

- **Role**: `ROLE_SET_CONTENTHASH` (`1 << 8`)
- **Part**: `0` (name-level)
- **Events**: `ContenthashChanged(node, hash)`

### `setName(bytes32 node, string name)`

Sets the primary name for reverse resolution.

- **Role**: `ROLE_SET_NAME` (`1 << 24`)
- **Part**: `0` (name-level)
- **Events**: `NameChanged(node, name)`

### `setABI(bytes32 node, uint256 contentType, bytes data)`

Sets ABI data. The `contentType` must be a power of 2.

- **Role**: `ROLE_SET_ABI` (`1 << 16`)
- **Part**: `0` (name-level)
- **Events**: `ABIChanged(node, contentType)`
- **Reverts**: `InvalidContentType` if contentType is not a power of 2

### `setPubkey(bytes32 node, bytes32 x, bytes32 y)`

Sets the SECP256k1 public key.

- **Role**: `ROLE_SET_PUBKEY` (`1 << 12`)
- **Part**: `0` (name-level)
- **Events**: `PubkeyChanged(node, x, y)`

### `setInterface(bytes32 node, bytes4 interfaceId, address implementer)`

Sets the EIP-165 interface implementer.

- **Role**: `ROLE_SET_INTERFACE` (`1 << 20`)
- **Part**: `0` (name-level)
- **Events**: `InterfaceChanged(node, interfaceId, implementer)`

### `clearRecords(bytes32 node)`

Wipes all records for a node by incrementing the version. Existing data becomes unreachable (new version = empty slate).

- **Role**: `ROLE_CLEAR` (`1 << 32`)
- **Part**: `0` (name-level)
- **Events**: `VersionChanged(node, newVersion)`

### `setAlias(bytes fromName, bytes toName)`

Creates an internal alias. Unlike record setters, this uses `onlyRootRoles` — only ROOT_RESOURCE holders can set aliases.

- **Role**: `ROLE_SET_ALIAS` (`1 << 28`)
- **Authorization**: ROOT_RESOURCE only (no per-name/per-part scoping)
- **Events**: `AliasChanged(indexedFromName, indexedToName, fromName, toName)`

## Batching with `multicall`

Multiple record changes can be batched in a single transaction:

```solidity
function multicall(bytes[] calldata calls) public returns (bytes[] memory results)
```

Each entry in `calls` is an ABI-encoded function call (e.g. the calldata for `setText`, `setAddr`, etc.). They execute via `delegatecall` in sequence, each going through its own role check. Reverts on the first error, rolling back the entire batch.

There's also `multicallWithNodeCheck(bytes32 node, bytes[] calls)` which behaves identically — the node check is a no-op since there is no trusted operator concept.

## Storage Layout

Records live in versioned mappings directly on the contract (no named storage slot):

```solidity
mapping(bytes32 node => bytes name) internal _aliases;
mapping(bytes32 node => uint64 version) internal _versions;
mapping(bytes32 node => mapping(uint64 version => Record)) internal _records;
```

Where `Record` is a struct defined on `PermissionedResolver`:

```solidity
struct Record {
    bytes contenthash;
    bytes32[2] pubkey;         // [x, y]
    string name;
    mapping(uint256 coinType => bytes) addresses;
    mapping(string key => string) texts;
    mapping(uint256 contentType => bytes) abis;
    mapping(bytes4 interfaceId => address) interfaces;
}
```

The current version is tracked in `_versions[node]`. When `clearRecords` is called, the version increments and a fresh empty `Record` is used.

## Example: Setting Multiple Records (viem / TypeScript)

```typescript
import { encodeFunctionData, namehash } from "viem";

const resolverAddress = "0x...";
const node = namehash("myname.eth");

// Batch: set ETH address + avatar text record + contenthash
const calls = [
  encodeFunctionData({
    abi: PermissionedResolverABI,
    functionName: "setAddr",
    args: [node, "0x1234..."],
  }),
  encodeFunctionData({
    abi: PermissionedResolverABI,
    functionName: "setText",
    args: [node, "avatar", "https://example.com/avatar.png"],
  }),
  encodeFunctionData({
    abi: PermissionedResolverABI,
    functionName: "setContenthash",
    args: [node, "0xe3010170..."], // IPFS CID
  }),
];

await walletClient.writeContract({
  address: resolverAddress,
  abi: PermissionedResolverABI,
  functionName: "multicall",
  args: [calls],
});
```

## Deleting a Record

There is no dedicated `deleteX` function. To delete a single record, set it to an empty value:

- **Address**: `setAddr(node, coinType, "0x")` (empty bytes)
- **Text**: `setText(node, key, "")` (empty string)
- **Contenthash**: `setContenthash(node, "0x")` (empty bytes)
- **Name**: `setName(node, "")` (empty string)
- **Pubkey**: `setPubkey(node, bytes32(0), bytes32(0))`
- **Interface**: `setInterface(node, interfaceId, address(0))`

To wipe **all** records at once, use `clearRecords(node)`.
