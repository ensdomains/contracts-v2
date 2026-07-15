# HCA protocol handoff

In the intended design, the Hidden Contract Account (HCA) is a per-user
execution account. The user's externally owned account (EOA) remains the name
owner and root authority.

This handoff classifies the current branch's risks and remaining work as:

- **Formal release blocker** means R1, R2, or R3 below.
- **High-priority finding** means a separate security issue identified by the
  review; this document does not silently promote it to R1–R3.
- **Demonstration gap** means a product target the current tests do not prove.
- **Open decision** means the protocol or product direction is not settled.
- **Recommended target** means a proposed architecture, not current
  behavior or an approved decision.

## Current implementation

- `StandaloneSingleOwnerHCA` is a Nexus implementation exercised through a
  `VerifiableFactory` proxy in tests. It stores one owner, blocks module changes,
  supports a session-revocation nonce, and allows owner-triggered upgrades to
  gate-approved implementations.
- `RegistrationBootstrapper` accepts caller-supplied factory, implementation,
  salt, initialization data, registrar, and commitment, then deploys and
  commits.
- `OwnerBoundRegistrationSessionValidator` supports direct-owner signatures and
  session grants. Its policy permits registrar commit/register/renew, approvals
  from either configured payment token to the registrar, resolver deployment
  and writes, and the registration-time reverse-name adapter.
- The account has a baked-in default `IntentExecutor`.
- Local Forge and end-to-end tests pass, but the end-to-end tests use a stronger
  mock executor and supply funds directly on the destination chain.

The branch should not be deployed in this state.

## Formal release blockers

### R1 — Trusted account provenance

`canUpgradeFrom` currently accepts every predecessor. A malicious
`VerifiableFactory` proxy can upgrade into the trusted implementation and then
appear to be a genuine ENS HCA.

Required fix: the first trusted HCA must reject every predecessor; later
versions must accept only explicit compatible predecessors.

### R2 — Counterfactual account capture

The generic bootstrapper lets a caller choose the deployment inputs even though
the proxy address depends only on the bootstrapper and salt. Someone can occupy
the expected account address with malicious initialization before ENS uses or
funds it.

Required fix: replace it with an owner-bound deployer that pins the factory,
implementation, registrar, and initialization shape; derives the salt
internally; verifies an existing account; and handles correct repeat deployment
or commitment safely.

### R3 — Signed digest does not bind checked operations

The validator verifies the session signature over the executor's digest and
separately checks `operationData` from the signature envelope. It does not prove
they describe the same calls, and it ignores the forwarded `sender`.

Required fix: rebuild the production `IntentExecutor` digest from the checked
operations, compare it with the ERC-1271 digest, require the expected executor,
and test against Rhinestone's versioned typed-data builder.

## Additional high-priority findings

These are separate from R1–R3. The protocol team must record how each affects
the launch gate.

1. **Resolver deployment is under-checked.** The policy does not bind the
   deployment salt, resolver address, initialization call, initial administrator
   and roles, seeded records, or exact resolver equality in `register`.
2. **One grant covers unrelated actions and uncapped spending.** A grant can
   authorize registration, renewal, records, and an unlimited token allowance.
   The proposed remediation uses separate registration, renewal, and records
   grants.
3. **The owner-role grant is under-checked.** The policy checks only the grantee,
   not the root resource, role bitmap, `grant == true`, or presence in a valid
   registration batch.
4. **The live runner omits the owner grant.** Its checks can pass while the HCA
   remains the resolver's sole administrator.
5. **The end-to-end test leaves excessive HCA authority in place.** It grants
   the owner `ROLES.ALL` but never removes the HCA's own permanent `ROLES.ALL`.
6. **The shared executor is a fleet-wide trust root.** It can execute arbitrary
   HCA batches without an account-side validator check. Its audit, upgrade,
   monitoring, ownership, and fleet emergency plan are not documented here.

## Demonstration gaps

The current evidence does not demonstrate:

- an offline reveal authorized before the user leaves;
- real Permit2/Across source funding for the current account;
- a wallet with no Permit2 allowance, or the DAI path;
- production account derivation and a random registrar secret;
- the current branch staying below the gas target;
- post-registration record sessions or renewal end to end; or
- sponsored session revocation and account upgrades for a user without
  destination-chain gas.

These are evidence gaps, not additional R1–R3 labels.

## Recommended target architecture

The protocol team has not yet formally ratified this proposed target:

- one canonical HCA per owner, destination chain, and account version;
- a persistent account that normally holds no funds;
- the user's EOA as name owner and sole root/admin authority;
- only minimal, EOA-revocable record-writing permission retained by the HCA;
- separate grants for registration, renewal, and record writes; and
- sponsored paths for revocation, upgrades, refunds, and stranded-fund
  recovery.

## Open decisions

The protocol team still needs to decide:

- canonical account discovery and version coexistence;
- upgrade-gate ownership, predecessor approval, review criteria, and delay;
- whether owner immutability is a governance promise or enforced outside
  upgradeable implementation code;
- the accepted trust and emergency model for the default executor;
- how offline reveal authorization or short-lived key custody works;
- registration and record-session lifetime limits;
- renewal, leftover funds, refunds, and recovery;
- supported owner wallet types, source chains, and tokens; and
- when state-pricing changes such as EIP-8037 should trigger a redesign.

## Recommended integration boundary

For the next integration, keep these operations outside the HCA:

- later primary-name changes should use the EOA signature-relay path, not the
  HCA;
- resolver changes, registry role changes, and transfers remain EOA-direct;
- subname operations are outside the current HCA policy; and
- the HCA is execution infrastructure, not the name owner or identity.
