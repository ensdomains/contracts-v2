# ENS v2 HCA: Rhinestone handoff

This document separates the current integration from the standalone-HCA work requested from Rhinestone.

## Current integration

- Apps use `@rhinestone/sdk` v1.7.0 with `account: { type: "hca" }`.
- That selector creates the legacy `HCAFactory`/CREATE3 account, not this branch's standalone HCA.
- The legacy account has no SmartSession, recovery, or extra modules. The wallet signs each intent.
- The standalone Nexus account, validator, and signature envelope are ENS-owned branch contracts with devnet and runner coverage, but are not wired into the SDK or apps.
- Local registration uses destination funds and a stronger mock executor. It does not prove production Permit2 or Across execution.
- Single-chain and Permit2 helpers are exported through internal-looking package subpaths, not a documented, stable, versioned API with test vectors.
- HCA `getDeployArgs` understands legacy `createAccount(bytes)` only.

## Proposed flow

This target still depends on ENS security fixes and protocol decisions.

1. The wallet authorizes funding and registration.
2. The route funds the canonical HCA and submits the commitment.
3. A relayer submits the registration batch after the registrar delay.
4. The wallet owns the name and receives resolver `ROLES.ALL`; the HCA keeps wallet-revocable resolver roles.

Proposed identity: one HCA per owner, destination chain, and account version. This is not implemented.

## Requests

### 1. Stabilize single-chain execution typed data

Document and support a stable, versioned builder for:

- `IntentExecutor` domain and types;
- destination-operation encoding;
- the ERC-1271 digest; and
- expected executor or `sender`.

Provide a test vector. Treat hashing changes as breaking changes.

### 2. Stabilize Permit2/JIT witness typed data

Document and support the Permit2/JIT witness builder with a test vector and the same versioning policy. ENS's current Solidity and test copies are circular evidence.

### 3. Add a versioned standalone-HCA adapter

Keep the current selector on the legacy account:

```ts
createAccount({
  account: { type: "hca" },
  owners: { type: "ens", /* ... */ },
})
```

Add a new discriminator or explicit version for the standalone HCA. Both account types must coexist.

The adapter must provide standalone address derivation, deployment data, and the ENS signature envelope. Production use waits on ENS fixes for deployment, provenance, and signed-operation binding.

### 4. Clarify `factoryData` timing

Can `{ factory, factoryData }` be computed in `prepareTransaction`, or is it fixed when the account object is created?

Late binding could permit deploy-and-commit in one factory call. If data is static, confirm whether ENS should recreate the account config with commitment-bearing factory data or use a canonical deployer plus `commit` as an operation.

### 5. Support gasless first-time allowance

Can the route submit a user-signed token permit before the Permit2 pull when the source token supports permits?

Target for supported tokens: two signatures and no wallet transaction when the user has stablecoins but no Permit2 allowance or gas token. Other tokens fall back to an onchain approval reported by the route.

### 6. Support custom deployment arguments

Should the standalone adapter extend `getDeployArgs`, or use another custom-account path? Please document or implement the supported option.

### 7. Support delayed registration execution

Provide a route that funds the standalone HCA, submits the commitment, resumes after the registrar delay, and sponsors the authorized reveal batch. The delegated path should not require another wallet prompt.

## Not requested

ENS is not asking Rhinestone to add SmartSession or module installation. ENS owns the account and validator.

## Inputs from ENS

ENS must provide the fixed deployer, address derivation, ABIs, signature envelope, and parity tests.

For each request, Rhinestone should provide feasibility, an owner, and a target SDK version.
