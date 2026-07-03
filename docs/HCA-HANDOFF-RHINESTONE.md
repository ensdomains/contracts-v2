# ENS v2 Registration on Rhinestone — Integration Notes & Asks

*From the ENS contracts team, 2026-07-02. Contact: ENS v2 / HCA workstream.*

## What we've built on your stack

ENS v2 `.eth` registration executed through the Rhinestone orchestrator:
a disposable per-user ERC-7579 account ("HCA", stock Nexus with a baked-in
default validator) is deployed and funded via an Across fill, then executes
the registration batch (ERC20 approve → resolver deploy → `register` →
record seeding → reverse name) on the destination chain. The user's single
Permit2 signature both funds the intent (`fundingMethod: PERMIT2`,
`settlementLayer: ACROSS`, `using7579: false`) and carries our
session-grant authorization inside the JIT witness. The name is registered
directly to the user's EOA; the account is throwaway.

Validated live on Sepolia 2026-06-03 through the real orchestrator route
(source chain Base, `IntentExecutor.executeSinglechainOps` destination op).
We pin **SDK v1.7.0** and currently reproduce your typed-data hashing
in-contract: our validator reconstructs the Permit2 JIT digest (domain,
JIT intent struct, mandate) from signature-supplied fields to verify the
owner's grant.

We deliberately do **not** use SmartSession / `experimental_sessions` — the
account shape rejects module installs, and authorization is a bespoke
ERC-1271 envelope validated by our default validator. Nothing we need from
you involves session-module support.

## Asks

**1. Retarget the SDK `hca` account type.** `createAccount({account:
{type: 'hca'}, owners: {type: 'ens', …}})` currently binds to our old
factory-based account. We'd like it to target the standalone stack: address
derivation via ENS's `VerifiableFactory` (CREATE2, `outerSalt =
keccak256(abi.encode(msg.sender, salt))` — note the deployer-dependence),
deployment through our `RegistrationBootstrapper`, and the new validator's
signature envelope. We can supply the derivation and envelope spec.

**2. Public export of the intent typed-data builders.** We currently
mirror your hashing (Permit2 domain, JIT intent, mandate structs) from SDK
internals. A public, versioned `getTypedData`-style export would let us
verify our on-chain reconstruction against your source of truth in CI
instead of pinning by hand.

**3. `getDeployArgs` for non-standard accounts.** It currently throws for
this account shape. Either support it or document the intended path for
accounts deployed outside your factories.

**4. Late-bound `factoryData`.** Our ideal deploy routes through
`RegistrationBootstrapper.deployAndCommit(...)` in the `{factory,
factoryData}` slot — but the calldata embeds a per-registration commitment,
so it must be computable at `prepareTransaction` time rather than fixed at
account creation. Is late-bound factoryData possible? If not, we'll split
into a plain deployer + commit-as-first-destination-op, which works but
relegates the fused path.

**5. Source-chain EIP-2612 bundling for Permit2 cold starts.** A fresh
wallet holding only USDC (no gas token) and no existing Permit2 allowance
cannot send the one-time `approve(Permit2)`. USDC supports EIP-2612 — can
the route accept a user-signed `permit(owner, Permit2, …)` and submit it on
the source chain ahead of the Permit2 claim, keeping the flow fully
gasless? (Two signatures, zero user transactions.)

**6. Intent-digest preimage documentation + change policy.** We plan to
strengthen our validator so it *reconstructs* the destination intent digest
and verifies that the destination ops committed in the digest match the ops
our policy checked (binding `mandate.destinationOps` to the batch,
in-contract). For that we need: (a) the exact, documented preimage layout of
the digest `IntentExecutor` validates via ERC-1271 for this route, and
(b) a versioning/notice commitment for changes to it. Related: because our
validator compiles your witness typehashes into immutables, **any change to
the JIT witness hashing is a breaking change for deployed ENS accounts** —
advance notice lets us stage validator upgrades ahead of SDK releases.

## Priority from our side

(6) and (1) unblock security hardening and the frontend migration
respectively; (4) decides a contract-shape question we'd rather not guess;
(2) reduces our exposure to accidental breakage; (5) affects first-time-user
UX; (3) is cleanup.
