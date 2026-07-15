# ENS v2 HCA: requests for Rhinestone

This handoff covers ENS's Hidden Contract Account (HCA) integration. It
separates the integration that exists today from the proposed replacement and
the questions ENS needs Rhinestone to answer.

## Current state

- The apps use `@rhinestone/sdk` v1.7.0 with `account: { type: "hca" }`. That
  account is the legacy `HCAFactory`/CREATE3 account, not the standalone account
  in this branch.
- The legacy SDK account does not support SmartSession, recovery, or extra
  modules. The user's wallet signs each intent.
- This branch contains a standalone Nexus implementation exercised through a
  `VerifiableFactory` proxy in local tests, with a validator and signature
  format maintained by ENS. It is not wired into the SDK or apps.
- The standalone registration batch passes locally against a mock executor with
  destination funds supplied directly. The current account has not completed
  the production Permit2/Across route. The mock also enforces a stronger
  operation check than the production executor.
- SDK v1.7.0 contains internal typed-data builders for single-chain execution
  and Permit2, but they are not exported from the package root.
- The SDK's HCA `getDeployArgs` understands the legacy
  `createAccount(bytes)` factory call. Custom HCA factory data that does not use
  that format produces no deploy arguments.

## Proposed target

This is a proposal, not the current implementation. ENS contract fixes,
additional security findings, and protocol decisions are still unresolved.

1. The user authorizes stablecoin funding and registration.
2. The route funds a canonical HCA, using Across when funds start on another
   chain, and submits the registrar commitment.
3. After the registrar delay, a relayer submits the registration batch without
   another wallet prompt.
4. The user's wallet owns the name and all root and admin authority. The HCA is
   normally empty and may keep only narrowly scoped, wallet-revocable
   record-writing permission.

The proposed account identity is one HCA per owner, destination chain, and
account version. That derivation is not implemented yet.

## Requests

### 1. Public single-chain execution typed data

Please expose a stable version of the internal single-chain typed-data builder,
including:

- the `IntentExecutor` domain and types;
- destination-operation encoding;
- the digest passed to ERC-1271; and
- the expected executor or `sender` value during validation.

Please also provide a test vector and treat hashing changes as breaking changes.
ENS needs this so the validator can prove that the operations it checks are the
operations signed for production execution.

### 2. Public Permit2/JIT witness typed data

Please expose the Permit2/JIT witness builder separately, with a test vector and
the same versioning policy. ENS currently mirrors these types in Solidity and
local test helpers, so the existing compatibility test is circular.

### 3. Add a versioned standalone-HCA account

After ENS supplies the fixed deployer and final signature format, please expose
the standalone account through a versioned SDK selection. The current call must
continue to select the legacy account:

```ts
createAccount({
  account: { type: "hca" },
  owners: { type: "ens", /* ... */ },
})
```

Add either a new account discriminator or an explicit version field for the
standalone account. The exact API is for Rhinestone and ENS to agree. It must
let both accounts coexist; silently changing the existing `hca` discriminator
would change address, deployment, and signature behavior for current users.

The new adapter needs the standalone address derivation, deployment call, and
ENS signature envelope. Its deployment work depends on ENS replacing the
unsafe generic bootstrapper. Production use also depends on fixing
trusted-account provenance and signed-operation binding.

### 4. Confirm when `factoryData` is fixed

Can `{ factory, factoryData }` be computed during `prepareTransaction`, or is it
fixed when the account object is created?

Late-bound data would allow deploy and commit in one factory call. Static data
would require a canonical deployer plus `commit` as a destination operation.
ENS can support either shape but must know which one the SDK permits.

### 5. Gasless first-time Permit2 allowance

Can the route submit a user-signed token permit before the Permit2 pull when the
source token supports it? This is an open product dependency, not a demonstrated
capability. The target is two signatures and no user transaction for a wallet
with stablecoins but no Permit2 allowance or gas token.

### 6. Custom deployment arguments

For the proposed non-legacy factory call, should the HCA adapter extend
`getDeployArgs`, or is there another supported custom-account path? Please
document or implement the intended route.

## Not requested

ENS is not asking for SmartSession or module-installation support. The proposed
account and session validator remain ENS-owned.

## Inputs ENS must provide

Before Rhinestone can implement the account adapter, ENS must provide the fixed
deployer, address derivation, ABIs, signature envelope, and parity tests. For
each request above, ENS needs a feasibility answer, a responsible Rhinestone
contact, and the target SDK version.
