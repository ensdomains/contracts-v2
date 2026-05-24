# Unregistering Names

How to delete subnames using the `PermissionedRegistry`.

**Contract**: `contracts/src/registry/PermissionedRegistry.sol`
**Interface**: `contracts/src/registry/interfaces/IStandardRegistry.sol`

## Function

```solidity
function unregister(uint256 anyId) external;
```

Deletes a subdomain, burning the ERC1155 token and making the name available for re-registration.

## Parameters

| Parameter | Type | Description |
|---|---|---|
| `anyId` | `uint256` | The labelhash, token ID, or resource — all resolve to the same entry |

The `anyId` is flexible. You can pass:
- **Labelhash**: `keccak256(abi.encodePacked(label))` (e.g. `keccak256("sub")`)
- **Token ID**: obtained from `getTokenId(anyId)` or `getState(anyId).tokenId`
- **Resource**: obtained from `getResource(anyId)` or `getState(anyId).resource`

## Required Role

The caller must have `ROLE_UNREGISTER` (nybble 3, `1 << 12`) on the name's resource, or on the `ROOT_RESOURCE` (global).

Defined in `RegistryRolesLib` (`contracts/src/registry/libraries/RegistryRolesLib.sol`):

```solidity
uint256 internal constant ROLE_UNREGISTER = 1 << 12;
uint256 internal constant ROLE_UNREGISTER_ADMIN = ROLE_UNREGISTER << 128;
```

## What Happens

1. Checks the name is not already expired.
2. Checks the caller has `ROLE_UNREGISTER` on the name's resource.
3. Emits `LabelUnregistered(tokenId, sender)`.
4. Burns the ERC1155 token (if an owner exists).
5. Increments `eacVersionId` and `tokenVersionId` — invalidates all existing roles and the old token ID.
6. Sets `expiry = block.timestamp` — the name is immediately expired and becomes `AVAILABLE`.

## State Transition

```
REGISTERED  ──unregister() + ROLE_UNREGISTER──>  AVAILABLE
RESERVED    ──unregister() + ROLE_UNREGISTER──>  AVAILABLE
```

Works on both `REGISTERED` (has an owner) and `RESERVED` (no owner, just locked) names.

## Events Emitted

| Event | Signature |
|---|---|
| `LabelUnregistered(uint256 indexed tokenId, address indexed sender)` | Always emitted |

The token burn also emits the standard ERC1155 `TransferSingle` event (to `address(0)`).

## Example (viem / TypeScript)

```typescript
import { keccak256, toHex } from "viem";

// The parent registry that holds the subnames
const registryAddress = "0x...";

// To delete "sub.parent.eth", call unregister on parent.eth's registry
// with the labelhash of "sub"
const labelHash = keccak256(toHex("sub"));

await walletClient.writeContract({
  address: registryAddress,
  abi: IStandardRegistryABI,
  functionName: "unregister",
  args: [labelHash],
});
```

## After Unregistering

- The name status becomes `AVAILABLE`.
- All roles previously granted on the name's resource are invalidated (version bump).
- The old token ID is no longer valid; `ownerOf(oldTokenId)` returns `address(0)`.
- The name can be re-registered by anyone with `ROLE_REGISTRAR` on the parent registry's ROOT_RESOURCE.
