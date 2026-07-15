# HCA design

## Purpose

The HCA lets a user register with stablecoins without registration-chain gas. It is an execution account and retained resolver delegate, not the user's identity or name owner.

The wallet owns the name, receives resolver `ROLES.ALL`, and can revoke the HCA's resolver roles.

## Responsibilities

| Part | Owns |
|---|---|
| Wallet | Name ownership and user authorization |
| Frontend | Inputs, wallet prompts, progress, recovery, and result checks |
| Shared app packages | Account and transaction planning interfaces |
| Rhinestone | Account adapter, typed data, routing, funding, and relay |
| ENS HCA contracts | Ownership, signatures, upgrades, and allowed calls |
| ENS protocol contracts | Registration, resolver, and reverse-name behavior |
| Mockestrator | Local route and fill transport only |

Frontend feature and UI code consumes the shared planning interface. Shared packages encode ENS calls and use the Rhinestone SDK and orchestrator for account derivation, typed data, funding, and relay. They do not copy Rhinestone schemas, and feature code does not call mockestrator directly.

## Target registration

1. Shared packages prepare the HCA, funding route, calls, prompts, and counts.
2. The wallet authorizes funding and registration.
3. The route deploys the owner-bound HCA if needed, funds it, and submits the commitment.
4. A sponsor submits the authorized batch after the registrar delay.
5. The wallet owns the name and receives resolver `ROLES.ALL`; the HCA keeps resolver roles.

See [the frontend handoff](./HCA-HANDOFF-FRONTEND.md) for route choices, exact calls, and wallet counts.

## Required properties

- The wallet, not the HCA or relayer, owns the name.
- Attackers cannot capture an account with chosen initialization.
- The checked signature binds chain, executor, and executed calls.
- Registration grants are short-lived, scoped, and revocable.
- The HCA retains no unnecessary funds; refund and recovery paths exist.
- The HCA keeps resolver roles; the wallet receives `ROLES.ALL` and can revoke them.
- Mock routing is not production security evidence.

## Branch status

Present:

- A single-owner Nexus implementation behind `VerifiableFactory` in tests.
- Direct-owner and delegated registration authorization.
- A fixed policy for selected registration, renewal, payment, resolver, and standalone default-primary calls.
- Owner-gated, allowlisted upgrades and session revocation by nonce.
- An owner- and initial-implementation-bound deployer using the shared `VerifiableFactory`; Rhinestone can carry deployment and the separate registrar commitment call in one fill.
- Local contract tests and a Permit2-shaped authorization test.
- Devnet addresses at `http://127.0.0.1:8000/deployments`.
- A Compose mockestrator sidecar.

Missing:

- A standalone-HCA adapter in `@rhinestone/sdk`.
- Manager support for chain 31337 and local ENS addresses.
- A standalone funding, commit, delay, and reveal state machine.
- Production Permit2 or Across execution.
- Fixes for the remaining blockers in [the protocol handoff](./HCA-HANDOFF-PROTOCOL.md).

Mockestrator supplies transport only. It does not close these gaps.

## Open decisions

- User-salt/version policy, address discovery, and version coexistence.
- Existing-account verification and reuse in the SDK.
- Production signatures and operation binding.
- Gasless first-time token allowance.
- Reveal authorization across the commitment delay.
- Refunds, leftovers, recovery, and sponsored revocation.
- Upgrade-gate and executor ownership and emergency controls.

These are protocol and Rhinestone decisions, not frontend feature logic.

## Required evidence

1. Contract tests cover provenance, address capture, operation binding, wallet co-administration, and the wallet's authority to revoke retained HCA roles.
2. Parity tests use Rhinestone's public, versioned typed-data builders.
3. A production-shaped route covers funding, commit, delay, reveal, registration, leftovers, and recovery.
4. Frontend E2E uses shared packages and ends with wallet ownership, wallet `ROLES.ALL`, and retained HCA roles.

## Team handoffs

- [Frontend](./HCA-HANDOFF-FRONTEND.md): route policy, calls, prompts, and devnet use.
- [Protocol](./HCA-HANDOFF-PROTOCOL.md): security fixes, decisions, and acceptance evidence.
- [Rhinestone](./HCA-HANDOFF-RHINESTONE.md): SDK, typed data, funding, and routing requests.
