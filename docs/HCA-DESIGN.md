# HCA design

## Purpose

The HCA lets a user register with stablecoins without registration-chain gas. It is an execution account and retained resolver delegate, not the user's identity or name owner.

The wallet owns the name, receives resolver `ROLES.ALL`, and can revoke the HCA's resolver roles.

Sponsored routes remove the registration-chain gas requirement. Wallet-paid fallback requires native gas there.

## Current status

Present:

- A single-owner Nexus implementation behind `VerifiableFactory` in tests.
- Owner-only atomic batch execution for wallet-paid actions.
- Owner-signed sponsored authorization and pre-enabled fixed sessions.
- A fixed policy for selected registration, renewal, payment, resolver, and standalone default-primary calls.
- Owner-gated upgrades with separate DAO approvals for the target and predecessor, plus session revocation by nonce.
- An owner- and initial-implementation-bound deployer using the shared `VerifiableFactory`.
- Local tests for Rhinestone's existing owner and session-use signature formats.
- Devnet addresses at `http://127.0.0.1:8000/deployments`.
- A Compose mockestrator sidecar.

Missing:

- A standalone-HCA adapter in `@rhinestone/sdk`.
- Standalone-HCA support in Manager's shared account and transaction code.
- Manager support for chain 31337 and local ENS addresses.
- Sponsored and wallet-paid funding, commit, delay, and reveal flows.
- SDK and app support for carrying standalone-HCA deployment and commitment in one fill.
- Production Permit2 or Across execution.
- The remaining release work in [the protocol handoff](./HCA-HANDOFF-PROTOCOL.md).

Mockestrator supplies transport only. It does not close these gaps.

## Target registration

1. The app integration reads current state and resolves supported routes, calls, wallet actions, and counts.
2. The wallet authorizes funding and registration.
3. The route deploys the owner-bound HCA if needed, funds it, and submits the commitment.
4. A sponsor or the wallet submits the HCA batch after the registrar delay.
5. The wallet owns the name and receives resolver `ROLES.ALL`; the HCA keeps resolver roles.

See [the frontend handoff](./HCA-HANDOFF-FRONTEND.md) for route choices, exact calls, and wallet counts.

## Upgrades

An upgrade requires the HCA owner and two DAO approvals: the current implementation's target gate approves the new implementation, and the new implementation's predecessor gate approves the current one.

V1 has a target gate and no predecessor gate, so it cannot be reached by upgrade. Each later implementation needs both gates; its deployment handoff supplies the two DAO approval calls.

## Responsibilities

| Part | Owns |
|---|---|
| Wallet | Name ownership and user authorization |
| Frontend | Inputs, wallet prompts, progress, recovery, and result checks |
| ENS app integration | HCA integration, route resolution, execution, and recovery |
| Rhinestone | Account adapter, signing, routing, funding, and relay |
| ENS HCA contracts | Ownership, wallet-paid execution, sponsored permissions, signatures, and upgrades |
| ENS protocol contracts | Registration, resolver, and reverse-name behavior |
| Mockestrator | Local route and fill transport only |

Manager currently uses `@ens-apps/smart-account` and `@ens-apps/transaction-manager`, but standalone-HCA integration is missing.

## Required properties

- The wallet, not the HCA or relayer, owns the name.
- Attackers cannot capture an account with chosen initialization.
- Sponsored operations bind the signature to the chain, executor, and executed calls.
- Wallet-paid batches require the owner as transaction sender and no separate signature.
- Sessions are short-lived, scoped, and revocable.
- The HCA retains no unnecessary funds; refund and recovery paths exist.
- The HCA keeps resolver roles; the wallet receives `ROLES.ALL` and can revoke them.
- Mock routing is not production security evidence.

## Open decisions

- User-salt/version policy, address discovery, and version coexistence.
- Existing-account verification and reuse in the SDK.
- Production support for the standalone HCA's fixed session validator.
- Gasless first-time token allowance.
- Reveal authorization across the commitment delay.
- Refunds, leftovers, recovery, and sponsored revocation.
- Upgrade review and delay, plus executor ownership and emergency controls.

## Required evidence

1. Contract tests cover provenance, address capture, operation binding, wallet co-administration, and the wallet's authority to revoke retained HCA roles.
2. Parity tests use Rhinestone's existing account and session signing paths.
3. A production-shaped route covers funding, commit, delay, reveal, registration, leftovers, and recovery.
4. Frontend E2E covers sponsored and wallet-paid routes and ends with wallet ownership, wallet `ROLES.ALL`, and retained HCA roles.

## Team handoffs

- [Frontend](./HCA-HANDOFF-FRONTEND.md): route policy, calls, prompts, and devnet use.
- [Protocol](./HCA-HANDOFF-PROTOCOL.md): security fixes, decisions, and acceptance evidence.
- [Rhinestone](./HCA-HANDOFF-RHINESTONE.md): standalone adapter, funding, and routing.
