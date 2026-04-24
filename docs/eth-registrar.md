# ETH Registrar

The controller contract for `.eth` name registration. Handles payment, pricing, and the commit-reveal anti-frontrunning scheme.

**Contract**: `contracts/src/registrar/ETHRegistrar.sol`
**Interface**: `contracts/src/registrar/interfaces/IETHRegistrar.sol`

## Overview

Users don't call the `ETHRegistry` (PermissionedRegistry) directly. The `ETHRegistrar` sits on top and handles:

1. **Commit-reveal** — prevents frontrunning of name registrations
2. **Payment** — collects rent in ERC20 tokens via a price oracle
3. **Duration validation** — enforces minimum registration duration
4. **Role assignment** — grants a standard set of roles to the new owner

The ETHRegistrar holds `ROLE_REGISTRAR` and `ROLE_RENEW` on the ETHRegistry, allowing it to register and renew names on behalf of users.

## Commit-Reveal Flow

### Why commit-reveal?

Without it, a malicious miner or frontrunner could see your `register("coolname")` transaction in the mempool and submit their own registration first. The commit-reveal scheme hides the name until it's too late to frontrun.

### Step 1: Commit

Compute a commitment hash off-chain, then submit it:

```solidity
bytes32 commitment = ETHRegistrar.makeCommitment(
    label,        // "example"
    owner,        // your address
    secret,       // random bytes32 (generated off-chain)
    subregistry,  // address(0) or a UserRegistry
    resolver,     // address(0) or a PermissionedResolver
    duration,     // in seconds (e.g. 365 days = 31536000)
    referrer      // bytes32(0) or a referrer identifier
);

ETHRegistrar.commit(commitment);
```

The commitment is just `keccak256(abi.encode(label, owner, secret, subregistry, resolver, duration, referrer))`.

**Events**: `CommitmentMade(commitment)`

### Step 2: Wait

Wait at least `MIN_COMMITMENT_AGE` seconds (e.g. 60s). The commitment expires after `MAX_COMMITMENT_AGE` seconds.

### Step 3: Register (reveal + pay)

Reveal the same parameters plus the payment token:

```solidity
uint256 tokenId = ETHRegistrar.register(
    label,         // "example"
    owner,         // your address
    secret,        // same secret from step 1
    subregistry,   // same as commitment
    resolver,      // same as commitment
    duration,      // same as commitment
    paymentToken,  // ERC20 token address (e.g. USDC)
    referrer       // same as commitment
);
```

**What happens internally:**

1. Validates `duration >= MIN_REGISTER_DURATION`
2. Checks `isAvailable(label)` — the name must be `AVAILABLE`
3. Consumes the commitment — reverts if too new or too old
4. Calculates price via `rentPriceOracle.rentPrice(label, owner, duration, paymentToken)` → `(base, premium)`
5. Transfers `base + premium` of `paymentToken` from caller to `BENEFICIARY`
6. Calls `REGISTRY.register(label, owner, subregistry, resolver, REGISTRATION_ROLE_BITMAP, block.timestamp + duration)`
7. Emits `NameRegistered` (registrar-level; the underlying ETHRegistry also emits `LabelRegistered`)

### Roles granted to owner

The `REGISTRATION_ROLE_BITMAP` is hardcoded:

```solidity
REGISTRATION_ROLE_BITMAP = 
    ROLE_SET_SUBREGISTRY |          // change subregistry
    ROLE_SET_SUBREGISTRY_ADMIN |    // delegate subregistry changes
    ROLE_SET_RESOLVER |             // change resolver
    ROLE_SET_RESOLVER_ADMIN |       // delegate resolver changes
    ROLE_CAN_TRANSFER_ADMIN;        // transfer the name
```

The owner can change the subregistry and resolver, and transfer the name. They do NOT get `ROLE_REGISTRAR`, `ROLE_RENEW`, or `ROLE_UNREGISTER` — those are controlled at the registry level.

## Renewal

```solidity
ETHRegistrar.renew(
    label,         // "example"
    duration,      // additional seconds
    paymentToken,  // ERC20 token
    referrer       // bytes32
);
```

**What happens:**
1. Checks the name is `REGISTERED` (not expired or available)
2. Calculates price (base only, no premium on renewal)
3. Transfers payment
4. Calls `REGISTRY.renew(tokenId, currentExpiry + duration)`

**Anyone can renew any name** — there's no ownership check on renewal. This is intentional: it allows third parties to keep names alive.

**Events**: `NameRenewed(tokenId, label, duration, newExpiry, paymentToken, referrer, base)`

## Read Methods

| Method | Signature | Description |
|---|---|---|
| `isAvailable(string label)` | `→ bool` | Whether the name is available for registration |
| `commitmentAt(bytes32 commitment)` | `→ uint64` | Timestamp when a commitment was made |
| `makeCommitment(...)` | `→ bytes32` | Compute commitment hash off-chain |
| `rentPrice(string label, address owner, uint64 duration, IERC20 paymentToken)` | `→ (uint256 base, uint256 premium)` | Get the registration price |
| `isValid(string label)` | `→ bool` | Whether the label passes validation (via oracle) |
| `isPaymentToken(IERC20 token)` | `→ bool` | Whether the token is accepted for payment |

## Configuration (immutables)

| Parameter | Description |
|---|---|
| `REGISTRY` | The `PermissionedRegistry` (ETHRegistry) this registrar controls |
| `BENEFICIARY` | Address that receives all payments |
| `MIN_COMMITMENT_AGE` | Minimum wait between commit and register |
| `MAX_COMMITMENT_AGE` | Maximum wait before commitment expires |
| `MIN_REGISTER_DURATION` | Minimum registration duration |

The `rentPriceOracle` is mutable and can be updated by an account with `ROLE_SET_ORACLE` on the registrar's ROOT_RESOURCE.

## Events

| Event | When |
|---|---|
| `CommitmentMade(bytes32 commitment)` | `commit()` called |
| `NameRegistered(tokenId, label, owner, subregistry, resolver, duration, paymentToken, referrer, base, premium)` | `register()` succeeds |
| `NameRenewed(tokenId, label, duration, newExpiry, paymentToken, referrer, base)` | `renew()` succeeds |
| `RentPriceOracleChanged(oracle)` | `setRentPriceOracle()` called |

## Errors

| Error | When |
|---|---|
| `NameNotAvailable(label)` | Name is not `AVAILABLE` |
| `NameNotRegistered(label)` | Trying to renew an unregistered name |
| `DurationTooShort(duration, minDuration)` | Duration below minimum |
| `UnexpiredCommitmentExists(commitment)` | Commitment already exists and hasn't expired |
| `CommitmentTooNew(commitment, validFrom, blockTimestamp)` | Haven't waited long enough since commit |
| `CommitmentTooOld(commitment, validTo, blockTimestamp)` | Waited too long, commitment expired |

## Example: Full Registration (viem / TypeScript)

```typescript
import { keccak256, encodePacked, toHex, zeroAddress } from "viem";

const registrar = "0x..."; // ETHRegistrar address
const resolver = "0x...";  // PermissionedResolver address
const paymentToken = "0x..."; // e.g. USDC

// Step 1: Generate secret and compute commitment
const secret = keccak256(toHex(crypto.randomUUID()));

const commitment = await publicClient.readContract({
  address: registrar,
  abi: IETHRegistrarABI,
  functionName: "makeCommitment",
  args: ["example", myAddress, secret, zeroAddress, resolver, 31536000n, "0x0..."],
});

// Step 2: Commit
await walletClient.writeContract({
  address: registrar,
  abi: IETHRegistrarABI,
  functionName: "commit",
  args: [commitment],
});

// Step 3: Wait MIN_COMMITMENT_AGE seconds
await new Promise((r) => setTimeout(r, 65_000));

// Step 4: Approve payment
const [base, premium] = await publicClient.readContract({
  address: registrar,
  abi: IETHRegistrarABI,
  functionName: "rentPrice",
  args: ["example", myAddress, 31536000n, paymentToken],
});

await walletClient.writeContract({
  address: paymentToken,
  abi: erc20ABI,
  functionName: "approve",
  args: [registrar, base + premium],
});

// Step 5: Register
const tokenId = await walletClient.writeContract({
  address: registrar,
  abi: IETHRegistrarABI,
  functionName: "register",
  args: ["example", myAddress, secret, zeroAddress, resolver, 31536000n, paymentToken, "0x0..."],
});
```
