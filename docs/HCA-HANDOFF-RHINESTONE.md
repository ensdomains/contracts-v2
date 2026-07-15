# ENS v2 HCA: Rhinestone handoff

This document separates the current integration from the standalone-HCA work requested from Rhinestone.

## Current integration

- Apps use `@rhinestone/sdk` v1.7.0 with `account: { type: "hca" }`.
- That selector creates the legacy `HCAFactory`/CREATE3 account, not this branch's standalone HCA.
- The legacy account has no SmartSession, recovery, or extra modules. The wallet signs each intent.
- The standalone Nexus account, validator, and signature envelope are ENS-owned branch contracts with devnet and runner coverage, but are not wired into the SDK or apps.
- `StandaloneHCADeployer` derives accounts from user salt, owner, and implementation through the shared `VerifiableFactory`.
- Local registration uses destination funds and a stronger mock executor. It does not prove production Permit2 or Across execution.
- Single-chain and Permit2 helpers are exported through internal-looking package subpaths, not a documented, stable, versioned API with test vectors.
- HCA `getDeployArgs` understands legacy `createAccount(bytes)` only.

## Proposed flow

This target still depends on ENS security fixes and protocol decisions.

1. The wallet authorizes funding and registration.
2. The route deploys the HCA if needed, funds it, and submits the commitment.
3. A relayer submits the registration batch after the registrar delay.
4. The wallet owns the name and receives resolver `ROLES.ALL`; the HCA keeps wallet-revocable resolver roles.

The branch uses one HCA per owner, destination chain, initial implementation, and user salt. The SDK integration is not implemented.

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

The adapter must provide standalone address derivation, deployment data, and the ENS signature envelope. Use:

```text
deploymentSalt = keccak256(abi.encode(userSalt, owner, initialImplementation))
factory = StandaloneHCADeployer
factoryData = deploy(owner, initialImplementation, userSalt)
```

The proxy address uses `StandaloneHCADeployer` as the caller in the standard `VerifiableFactory` formula. Derive it with the initial implementation. Before reuse, verify existing code, owner, and current implementation under the supported version and provenance policy. Production use still waits on provenance and signed-operation binding fixes.

### 4. Deploy and commit in one fill

Deployment data is static and does not include registration data. For an undeployed HCA, put `StandaloneHCADeployer.deploy(...)` in the account `setupOps` and `ETHRegistrar.commit(commitment)` in `destinationExecutions` for the same intent. For an existing verified HCA, omit the setup operation.

If the expected HCA is deployed after planning, the adapter verifies it and omits setup; the ENS planner reprepares the intent. This is a recoverable stale plan, not a reason to combine registration logic with deployment.

The SDK already separates account setup operations from destination executions. The standalone adapter must supply the deployment operation; the ENS planner supplies the commitment call. Return this fill and the later reveal as two destination transactions.

### 5. Support gasless first-time allowance

Can the route submit a user-signed token permit before the Permit2 pull when the source token supports permits?

Target for supported tokens: two signatures and no wallet transaction when the user has stablecoins but no Permit2 allowance or gas token. Other tokens fall back to an onchain approval reported by the route.

### 6. Support delayed registration execution

Provide a route that funds the standalone HCA, submits the commitment, resumes after the registrar delay, and sponsors the authorized reveal batch. The delegated path should not require another wallet prompt.

## Not requested

ENS is not asking Rhinestone to add SmartSession or module installation. ENS owns the account and validator.

## Inputs from ENS

ENS must provide the deployer and implementation addresses, user-salt policy, address derivation, ABIs, signature envelope, and parity tests.

For each request, Rhinestone should provide feasibility, an owner, and a target SDK version.
