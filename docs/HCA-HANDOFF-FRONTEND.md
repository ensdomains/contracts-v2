# HCA — Frontend Team Handoff (apps-monorepo migration)

*2026-07-02. Derived from [`HCA-DESIGN.md`](./HCA-DESIGN.md) (authoritative on
conflict). Targets the standalone HCA stack on branch `feat/hca-final-maybe`;
the old `HCAFactory` stack your code currently uses is being retired.*

## The one-paragraph mental model

The user's **EOA is the identity**: it owns the name, holds the registry
roles, and (after migration) co-admins the resolver. The **HCA is disposable
plumbing**: a throwaway smart account that holds bridged funds for one
operation, executes the batch, and can be abandoned. Sessions are two
signatures: the owner signs a *grant* once (delegating to an ephemeral
session key your client generates, with an expiry), and the session key signs
the actual operation digests silently — no wallet prompts after the grant.
In the registration flow the grant rides inside the Permit2 funding
signature, so **one wallet prompt covers money + authorization**.

## Target interaction counts (vs what you ship today)

| Flow | Today | Target | What changes |
|---|---|---|---|
| Registration | 4 prompts | **1** (2 for fresh wallets) | funding model + batching (below) |
| Record edits | 1 tx | **1 sig, 0 tx, 0 gas** | session grant + sponsored relay |
| Primary name (later) | 2 prompts | **1 sig, 0 tx** | drop the HCA from this flow entirely |
| Renewal | 1–2 EOA txs | **1 sig** (pending product decision) | same rail as registration |
| setResolver / roles / subnames / transfers | 1 tx each | 1 tx each (unchanged) | keep EOA-direct; never route via intents |

## Per-flow migration

### Registration (`registration.machine.ts`) — 4 → 1

Your four prompts exist because funds sit on the EOA: deploy-resolver intent,
commit intent, a **separate mandatory EOA approve tx** (the registrar pulls
payment from `msg.sender`, which is the HCA — an intent can't sign an EOA
approve), and the register intent. The standalone flow inverts the funding:

1. User signs **one Permit2 typed-data payload** = stablecoin funding
   (bridged Base→L1 via Across) **+** the session grant (embedded in the
   witness). Client generates the ephemeral session key and `validUntil`
   (minutes — commit-reveal window scale, treat it as a security parameter).
2. Relayer executes tx1: `RegistrationBootstrapper.deployAndCommit` (HCA
   deploy + registrar commit, fused).
3. Relayer executes tx2: the register batch through the HCA — exact-amount
   USDC approve → resolver deploy via VerifiableFactory (**HCA must be the
   deployer** — VF addresses are deployer-dependent) → `register` (owner =
   EOA) → seed records → `setNameWithHCA` (reverse) → **resolver role grant
   to the EOA** (new — see Records below).

The old comment "the HCA holds no funds — gas is paid by the Warp relayer"
describes the retired stack. In the new one the HCA briefly holds the
registration payment; gas is still relayer-sponsored.

**Fresh wallets:** if the EOA has never approved Permit2 for the source-chain
USDC, that's +1 interaction. Prefer the EIP-2612 path (sign
`permit(owner, Permit2, …)`, relayer submits) over an approve tx — an
approve tx needs ETH on Base and breaks the no-gas-token property. Whether
the Rhinestone route can bundle the 2612 permit into the fill is an open ask
to Rhinestone (their handoff doc, ask 5).

**SDK:** you already use `createAccount({account: {type: 'hca'}, owners:
{type: 'ens', …}})` — that account type currently binds to the old factory.
Retargeting it (VF derivation + bootstrapper deploy + new validator envelope)
is Rhinestone ask 1; until it lands, deploy routing needs the
`{factory, factoryData}` slot pointed at the bootstrapper (or split
deploy/commit — resolution pending Rhinestone ask 4).

### Record edits (`ProfileEdit.transactions.ts`, `saveRecords.ts`)

Two things:

1. **The good news:** post-registration record edits become 1 signature,
   0 transactions, 0 user gas — a session grant bound to the user's resolver
   (plain EIP-191 shape, no Permit2/funding leg since nothing is paid),
   session key signs the multicall, sponsored relayer executes.
2. **The former blocker is fixed on the branch (2026-07-03):** the
   registration batch now grants the EOA root roles on its resolver
   (`authorizeNameRoles`, policy-permitted for grantee == owner only), so
   EOA-signer editors work against names registered on the new stack.
   Still check `hasRoles` on the resolver before offering the EOA path —
   names registered before the fix carry no EOA roles until a one-off
   HCA-mediated grant.

### Primary name (`primaryName.machine.ts`) — 2 → 1, and simpler

Drop the HCA from this flow. Later primary-name changes should use the
reverse registrar's **signature path** (`setNameForAddrWithSignature`-style):
the EOA signs one typed-data claim, any relayer submits it. Your current
intent path spends a second prompt using the HCA as a mere relay, and raw
`reverseRegistrar.setName` through an HCA names *the HCA*, not the user.
The HCA-based reverse write (`setNameWithHCA`) exists **only** inside the
registration batch (the validator enforces same-batch), which stays as-is.

### Resolver change (`changeResolver.ts`), roles, subnames, transfers

Keep all of these EOA-direct, permanently. Their authorization is registry
token roles held by the EOA; the validator policy blocks registry targets
**by design** and that will not change. Your `resolver.machine.ts`
rhinestone-intent branch should be removed or EOA-gated — against the
standalone stack it is double-blocked (policy + roles).

### Renewal (`useRenewalTransactions.ts`)

The contract rail is ready (permissionless `renew`, pays from caller, policy
allows it) and fits the same 1-signature Permit2 shape as registration. The
product story (reuse the user's existing HCA — its address is deterministic
— vs spawn) is an open protocol-team decision; don't wire it until that
lands. Today's EOA path keeps working.

## Client responsibilities for sessions (new)

- Generate an ephemeral session keypair per grant; never persist it beyond
  the flow; never send the private key anywhere.
- Read the account's **session nonce** (new `ownerAndSessionNonce()` /
  `sessionNonce()` view after the redeploy) when building a grant — the
  nonce is part of the signed grant struct but is **not** sent onchain.
- **Typehashes changed 2026-07-03** (a `sessionNonce` field was added to
  both grant structs): the constants in `test/utils/hcaSessions.ts` are the
  reference. The nonce is read from `ownerAndSessionNonce()` on a deployed
  account and is 0 for a counterfactual (not-yet-deployed) HCA; it is never
  sent in the signature envelope.
- Keep `validUntil` at minutes, not days. It's the primary safety bound.
- Expose "revoke sessions": one EOA tx to `revokeSessions()` on the user's
  HCA (~26k gas) kills every outstanding grant. A revoked/stale grant fails
  as `InvalidSigner` (not a distinct error) — map that to "grant expired or
  revoked, re-sign" when the account nonce has moved.
- Render grants legibly at signing time (name, resolver, expiry) — the
  wallet shows an opaque Permit2 witness; your UI is the only place the user
  can actually read what they're authorizing.

## Dependency order

1. **Now:** primary-name flow switch (signature path — no contract
   dependency); remove/gate the resolver intent branch.
2. **After the contracts redeploy:** registration funding-model migration,
   session-based record editing, typehash bump, revoke-sessions UI.
3. **After Rhinestone asks land:** SDK `hca` account-type retarget (ask 1),
   deploy-slot shape (ask 4), fresh-wallet 2612 bundling (ask 5).
