# Name Renewal

How to extend the expiry of `.eth` names and subnames.

**Contracts**:
- `contracts/src/registrar/ETHRegistrar.sol` (for `.eth` names)
- `contracts/src/registry/PermissionedRegistry.sol` (for subnames)
- `contracts/src/registrar/StandardRentPriceOracle.sol` (pricing)

## Two Renewal Paths

| What you're renewing | Contract | Function | Payment? |
|---|---|---|---|
| `.eth` name (e.g., `example.eth`) | ETHRegistrar | `renew(label, duration, paymentToken, referrer)` | Yes (ERC20) |
| Subname (e.g., `sub.example.eth`) | PermissionedRegistry (UserRegistry) | `renew(anyId, newExpiry)` | No |

## Renewing `.eth` Names (via ETHRegistrar)

### Function

```solidity
function renew(
    string calldata label,
    uint64 duration,
    IERC20 paymentToken,
    bytes32 referrer
) external
```

### Who can call

**Anyone.** There is no ownership or role check on `ETHRegistrar.renew()`. This is intentional — it allows third parties, DAOs, or services to keep names alive on behalf of others.

### What happens

1. Checks the name is `REGISTERED` (not `AVAILABLE`)
2. Computes new expiry: `currentExpiry + duration`
3. Calculates renewal price via the rent price oracle (base rate only, no premium)
4. Transfers payment from caller to the `BENEFICIARY` address
5. Calls `REGISTRY.renew(tokenId, newExpiry)` on the ETHRegistry
6. Emits `NameRenewed` (registrar) and `ExpiryUpdated` (registry)

### Pricing

Renewal pricing comes from the `StandardRentPriceOracle`:

- **Base rate**: per-second cost determined by label length (shorter names cost more)
- **Duration discount**: longer renewals get a discount (piecewise-linear)
- **No premium**: renewals never pay the expiry premium (that's only for new registrations of recently-expired names)

### Example (viem / TypeScript)

```typescript
import { parseUnits } from "viem";

const label = "example";
const duration = 31536000n; // 1 year in seconds
const paymentToken = "0x..."; // ERC20 token address (e.g. USDC)

// Step 1: Get the renewal price
const [base, premium] = await publicClient.readContract({
  address: ethRegistrarAddress,
  abi: [{
    name: 'rentPrice',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'label', type: 'string' },
      { name: 'buyer', type: 'address' },
      { name: 'duration', type: 'uint64' },
      { name: 'paymentToken', type: 'address' },
    ],
    outputs: [
      { name: 'base', type: 'uint256' },
      { name: 'premium', type: 'uint256' },
    ],
  }],
  functionName: "rentPrice",
  args: [label, myAddress, duration, paymentToken],
});
// For renewals, premium is always 0

// Step 2: Approve the payment token
await walletClient.writeContract({
  address: paymentToken,
  abi: [{ name: 'approve', type: 'function', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }], stateMutability: 'nonpayable' }],
  functionName: "approve",
  args: [ethRegistrarAddress, base],
});

// Step 3: Renew
await walletClient.writeContract({
  address: ethRegistrarAddress,
  abi: [{
    name: 'renew',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'label', type: 'string' },
      { name: 'duration', type: 'uint64' },
      { name: 'paymentToken', type: 'address' },
      { name: 'referrer', type: 'bytes32' },
    ],
    outputs: [],
  }],
  functionName: "renew",
  args: [label, duration, paymentToken, "0x0000000000000000000000000000000000000000000000000000000000000000"],
});
```

### Events

| Event | Source | Fields |
|---|---|---|
| `NameRenewed(tokenId, label, duration, newExpiry, paymentToken, referrer, base)` | `IETHRegistrar` | Registrar-level renewal event |
| `ExpiryUpdated(tokenId, newExpiry, sender)` | `IRegistryEvents` | Registry-level expiry update |

Both events fire for the same renewal — the registrar event includes pricing data.

## Renewing Subnames (via PermissionedRegistry)

### Function

```solidity
function renew(uint256 anyId, uint64 newExpiry) external
```

### Who can call

The caller must have `ROLE_RENEW` (`1 << 16`, nybble 4) on the name's resource or on `ROOT_RESOURCE`.

Typically the parent name owner (admin of the UserRegistry) has this role.

### What happens

1. Checks the name is not expired
2. Checks the caller has `ROLE_RENEW`
3. Validates `newExpiry >= currentExpiry` (cannot reduce expiry)
4. Updates the entry's expiry
5. Emits `ExpiryUpdated(tokenId, newExpiry, sender)`

### Example

```typescript
import { keccak256, toHex } from "viem";

const labelHash = keccak256(toHex("sub"));
const newExpiry = BigInt(Math.floor(Date.now() / 1000) + 365 * 24 * 3600); // +1 year

await walletClient.writeContract({
  address: userRegistryAddress,
  abi: [{
    name: 'renew',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'anyId', type: 'uint256' },
      { name: 'newExpiry', type: 'uint64' },
    ],
    outputs: [],
  }],
  functionName: "renew",
  args: [labelHash, newExpiry],
});
```

### `anyId` flexibility

The `anyId` parameter accepts any of:
- **Labelhash**: `keccak256("sub")`
- **Token ID**: from `getTokenId(anyId)` or events
- **Resource**: from `getResource(anyId)` or events

All three resolve to the same entry internally.

## Errors

| Error | When |
|---|---|
| `CannotReduceExpiry(oldExpiry, newExpiry)` | `newExpiry < currentExpiry` |
| `LabelExpired(tokenId)` | Name is already expired |
| `EACUnauthorizedAccountRoles(...)` | Missing `ROLE_RENEW` (subname renewal only) |
| `NameNotRegistered(label)` | Trying to renew an `AVAILABLE` name (ETHRegistrar) |

## Batch Renewal

The `BatchRegistrar` contract (`contracts/src/registrar/BatchRegistrar.sol`) supports batch operations that include renewal. Its `batchRegister()` function can renew already-reserved names as part of a batch:

```solidity
function batchRegister(
    IRegistry registry,
    address resolver,
    string[] calldata labels,
    uint64[] calldata expires
) external onlyOwner
```

For each label: if the name is `RESERVED` and the new expiry is greater than the current one, it calls `renew()`. This is primarily used for pre-migration batch operations, not end-user renewal.

## Expiry Behavior

- Expired names return `AVAILABLE` from `getStatus()`
- Expired names return `address(0)` from `getSubregistry()` and `getResolver()`, breaking the resolution chain
- Subname expiry is independent of parent expiry, but if a parent expires, all subnames become unresolvable
- After expiry, a name can be re-registered (new registration, not renewal)

## Related

- [ETH Registrar](./eth-registrar.md) — Full commit-reveal registration flow and pricing
- [Subnames](./subnames.md) — Subname lifecycle including renewal
- [Name Registration](./name-registration.md) — How names are registered
