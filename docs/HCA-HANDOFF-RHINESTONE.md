# ENS v2 HCA: Rhinestone handoff

## Goal

Add the standalone account to Rhinestone's existing HCA adapter with the smallest practical SDK change. Changes outside the adapter are guarded standalone-HCA branches.

## Current gap

- `@rhinestone/sdk` v1.7.0 derives and deploys the legacy `HCAFactory` account.
- The standalone HCA uses `StandaloneHCADeployer` and the shared `VerifiableFactory`.
- The HCA adapter only understands the legacy factory and account.
- The fixed validator consumes Rhinestone's existing owner signatures and Smart Session `USE` payload.
- SDK v1.7 defines pure emissary-execution mode but routes execution-checked sessions through hybrid mode.

## SDK work

Add a standalone version to the HCA adapter. Keep the current `hca` behavior for legacy accounts.

The standalone variant accepts the owner, supported initial implementation, user salt, and deployed `StandaloneHCADeployer`. Its version configuration supplies the implementation's fixed validator. Reject a validator mismatch.

It derives and deploys the account using:

```text
deploymentSalt = keccak256(abi.encode(userSalt, owner, initialImplementation))
factory = StandaloneHCADeployer
factoryData = deploy(owner, initialImplementation, userSalt)
```

The account address is the `VerifiableFactory` proxy address for `StandaloneHCADeployer` and `deploymentSalt`.

For an undeployed account, return the deployment call as `setupOps`. For an existing account, omit it after verifying the deployment, owner, and supported implementation.

Use the account's fixed validator as the standalone variant's default owner and session validator. Existing owner signatures are unchanged.

The owner-signed setup and commitment keep the existing ERC-1271 route. That intent may deploy and fund the HCA, enable the fixed session, and commit.

For later pre-enabled calls that need no funding claim, reuse the existing `USE` payload and select `SIG_MODE_EMISSARY_EXECUTION` (mode 4). The expected operation word is `0x0204` followed by 30 zero bytes. Emit only the emissary signature.

For this variant only, session status and estimation use the fixed validator, and generic Smart Session enablement and typed-data packing are bypassed. Mode 4 still requires production orchestrator and `IntentExecutor` confirmation.

## Boundary

No new signature type, typed data, session payload, policy module, or ENS workflow API is required. Do not change generic Smart Session nonce, enable, policy, or hybrid-mode behavior.

ENS owns the account contracts, fixed permission checks, session parameters, registration calls, commitment-delay state, and result checks. Rhinestone owns its existing routing, funding, signing, sponsorship, and relay behavior.

Wallet-paid `executeByOwner` bypasses Rhinestone.

## Acceptance

- SDK and contract address derivation match.
- Legacy HCA behavior is unchanged.
- Existing owner signatures work without an ENS-specific encoder.
- Existing session-use signatures work with the fixed validator in mode 4.
- Session status and gas estimation use that validator address.
- The first sponsored intent can deploy the HCA and execute supplied calls in one fill.
- Existing verified HCAs are reused without a deployment operation.
- Commit and reveal remain separate intents.
- A production operation confirms the mode-4 word and verifier call.

ENS provides deployed addresses, the user-salt policy, address derivation, ABIs, and parity tests.
