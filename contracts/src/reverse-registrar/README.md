# L2 Reverse Registrar

The L2 Reverse Registrar is a combination of a resolver and a reverse registrar that allows the name to be set for a particular reverse node.

## Setting records

You can set records using one of the follow functions:

`setName()` - uses the msg.sender's address and allows you to set a record for that address only

`setNameForAddr()` - uses the address parameter instead of `msg.sender` and checks if the `msg.sender` is authorized by checking if the contract's owner (via the Ownable pattern) is the msg.sender

`setNameForAddrWithSignature()` - uses the address parameter instead of `msg.sender` and allows authorisation via a signature

`setNameForOwnableWithSignature()` - uses the address parameter instead of `msg.sender`. The sender is authorized by checking if the contract's owner (via the Ownable pattern) is the msg.sender, which then checks that the signer has authorized the record on behalf of msg.sender using `ERC1271` (or `ERC6492`)

## Replay Protection

Signature-based methods use an **inception timestamp** system for replay protection. Each address has an associated inception timestamp stored onchain. For a signature to be valid:

1. The signature's `signedAt` timestamp must be **strictly greater than** the current inception for that address
2. The `signedAt` timestamp must not be in the future (i.e., `signedAt <= block.timestamp`)

When a valid signature is used, the inception is updated to the `signedAt` value. This ensures:
- Each signature can only be used once per chain
- Newer signatures always supersede older ones
- Ordering is guaranteed (signatures with older `signedAt` values become invalid once a newer one is used)

You can query the current inception for any address using `inceptionOf(address)`.

## Signatures for setting records

Signatures are all plaintext, prefixed with `\x19Ethereum Signed Message:\n<length of message>` as defined in ERC-191.

### Field definitions

| Field | Type | Description |
|-------|------|-------------|
| `name` | `string` | The ENS name to set as primary (e.g., `vitalik.eth`). |
| `address` | `address` | The address for which the primary name is being set. EIP-55 checksummed. |
| `owner` | `address` | The address that owns the contract for which the primary name is being set. EIP-55 checksummed. Only applicable for `setNameForOwnableWithSignature`. |
| `chainList` | `string` | Comma-separated list of chain IDs, **must be in strictly ascending order**. |
| `signedAt` | `string` | ISO 8601 UTC datetime when the signature was signed. Must be after the current inception and not in the future. |

### `setNameForAddrWithSignature`

```
You are setting your ENS primary name to:
{name}

Address: {address}
Chains: {chainList}
Signed At: {signedAt}
```

### `setNameForOwnableWithSignature`

```
You are setting the ENS primary name for a contract you own to:
{name}

Contract Address: {address}
Owner: {owner}
Chains: {chainList}
Signed At: {signedAt}
```