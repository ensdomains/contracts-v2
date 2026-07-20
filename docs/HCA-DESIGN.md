# HCA design

## Purpose

The HCA lets a user register with stablecoins without registration-chain gas. It is an execution account and retained resolver delegate, not the user's identity or name owner.

The wallet owns the name, receives resolver `ROLES.ALL`, and can revoke the HCA's resolver roles.

Rhinestone-sponsored and paymaster routes remove the registration-chain gas requirement. Direct-wallet fallback requires native gas there.

## Current status

Present:

- A single-owner Nexus implementation behind `VerifiableFactory`.
- Owner-only atomic batch execution for wallet-paid actions.
- Owner-signed ERC-4337 execution through EntryPoint.
- Owner-signed sponsored authorization and pre-enabled fixed sessions.
- A fixed policy for selected registration, renewal, payment, resolver, and standalone default-primary calls.
- Owner-gated upgrades with separate DAO approvals for the target and predecessor, plus session revocation by nonce.
- An owner- and initial-implementation-bound deployer using the shared `VerifiableFactory`.
- A Bun-patched Rhinestone SDK adapter with address and signature parity tests.
- A Sepolia SDK test covering a fresh HCA, EIP-2612 wallet funding, fixed-session reveal, and existing-HCA reuse through the production executor.
- A passing Arbitrum Sepolia-to-Sepolia live check covering a fresh zero-ETH wallet, EIP-2612 source funding, Permit2 authorization, the Across claim and HCA fill, and USDC-paid session follow-up.
- A local EntryPoint test covering fresh deployment and execution in one paymaster-sponsored UserOperation.
- Devnet addresses at `http://127.0.0.1:8000/deployments`.
- A Compose mockestrator sidecar.

Missing:

- A published standalone-HCA adapter in `@rhinestone/sdk`.
- Standalone-HCA support in Manager's shared account and transaction code.
- Manager support for chain 31337 and local ENS addresses.
- Manager registration, wallet-paid, and recovery flows.
- A live bundler/paymaster test.
- The remaining release work in [the protocol handoff](./HCA-HANDOFF-PROTOCOL.md).

Mockestrator supplies transport only. It does not close these gaps.

## Target registration

1. The app integration reads current state and resolves supported routes, calls, wallet actions, and counts.
2. For cross-chain registration, the wallet permits the source Nexus if needed and signs the Permit2 intent.
3. The claim pulls source funds; the fill deploys and funds the HCA, enables the session, and commits.
4. After the delay, the session, sponsor, or wallet submits the registration batch.
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
| ENS app integration | HCA integration, route resolution, wallet-funding calls, execution, and recovery |
| Rhinestone | Account adapter, signing, routing, claim and fill, and relay |
| ENS HCA contracts | Ownership, wallet-paid execution, sponsored permissions, signatures, and upgrades |
| ENS protocol contracts | Registration, resolver, and reverse-name behavior |
| Mockestrator | Local route and fill transport only |

Manager currently uses `@ens-apps/smart-account` and `@ens-apps/transaction-manager`, but standalone-HCA integration is missing.

## Required properties

- The wallet, not the HCA or relayer, owns the name.
- Attackers cannot capture an account with chosen initialization.
- Sponsored operations bind the signature to the chain, executor, and executed calls.
- Wallet-paid batches require the owner as transaction sender and no separate signature.
- ERC-4337 batches require an owner signature; a paymaster may pay gas without narrowing the owner's authority.
- Sessions are short-lived, scoped, and revocable.
- The HCA retains no unnecessary funds; refund and recovery paths exist.
- The HCA keeps resolver roles; the wallet receives `ROLES.ALL` and can revoke them.
- Mock routing is not production security evidence.

## Open decisions

- User-salt/version policy, address discovery, and version coexistence.
- Allowance fallback for tokens without permits.
- Session-key storage and lifetime.
- Refunds, leftovers, recovery, and sponsored revocation.
- Upgrade review and delay, plus executor ownership and emergency controls.

## Required evidence

1. Contract tests cover provenance, address capture, operation binding, wallet co-administration, and the wallet's authority to revoke retained HCA roles.
2. Parity tests cover SDK address derivation, owner and fixed-session signing, default-validator nonce selection, and fresh-account factory data.
3. Production evidence covers same-chain funding, commit, delay, reveal, registration, and existing-HCA reuse.
4. Release evidence covers leftovers, recovery, and the protocol findings.
5. Frontend E2E covers sponsored and wallet-paid routes and ends with wallet ownership, wallet `ROLES.ALL`, and retained HCA roles.

## Team handoffs

- [Frontend](./HCA-HANDOFF-FRONTEND.md): route policy, calls, prompts, and devnet use.
- [Protocol](./HCA-HANDOFF-PROTOCOL.md): security fixes, decisions, and acceptance evidence.
- [Rhinestone](./HCA-HANDOFF-RHINESTONE.md): standalone adapter, funding, and routing.
- [User-paid USDC](./HCA-USER-PAID-USDC.md): gasless source funding, USDC fees, and session refunds.
