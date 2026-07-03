# HCA — Protocol Team Handoff

*2026-07-02. Derived from [`HCA-DESIGN.md`](./HCA-DESIGN.md) (authoritative on
conflict). Branch: `feat/hca-final-maybe` in `contracts-v2-hca-use-what-we-have/`.*

## What this is

ENS v2 registration via a disposable per-user smart account (HCA): the user
signs once (a Permit2 witness that is both stablecoin funding and a bounded
session grant), relayers execute deploy+commit then the register batch, the
name lands on the user's EOA. The HCA is payment/execution plumbing, never
identity: **any design that parks durable authority on the HCA is a bug.**

## Current state (all in working tree, not committed)

- `StandaloneSingleOwnerHCA` — stock Nexus, baked-in default validator +
  executor, immutable owner, modules/upgrades/NFT callbacks disabled.
- `OwnerBoundRegistrationSessionValidator` — stateless ERC-1271 validator;
  direct owner sigs, legacy EIP-191 grants, Permit2-shaped Rhinestone JIT
  grants; hardcoded registration policy (registrar commit/register/renew,
  policy-resolver record writes, `setNameWithHCA` same-batch, exact approve
  to registrar, resolver deploy via VF). Constructor went 7→6 args
  (ReverseRegistrarAdapter removed with `claimWithHCA`); `RENEW_SELECTOR`
  fixed to the 4-arg `renew(string,uint64,address,bytes32)`.
- `RegistrationBootstrapper.deployAndCommit` — fuses HCA deploy + registrar
  commit (tx1).
- `DefaultReverseRegistrarAdapter.setNameWithHCA` — the one HCA-aware
  protocol adapter (HCAAuthorizer: VF `verifyContract` + trusted-impl
  allowlist + `owner()` readback).
- Deploy pipeline `deploy/hca/00–04`, exercised by e2e via devnet.
  Verification: 937/937 forge, 4/4 e2e, live check `bun run check:hca-live`.

## The redeploy work-package (Sepolia redeploy required regardless)

The 7→6 constructor and renew-selector fix already force a redeploy. Land
these with it:

### 1. Gated upgrades (decision A — resolved)

Frozen **owner model**, upgradeable **account**, reusing the existing
`ApprovedUpgradeGate` pattern exactly as `WrapperRegistry` consumes it:

- `StandaloneSingleOwnerHCA` gains an immutable `UPGRADE_GATE`
  (`ApprovedUpgradeGate`) constructor param.
- `_authorizeUpgrade(newImpl)`: require `msg.sender == owner()` **and**
  `UPGRADE_GATE.approvedImplementations(newImpl)` (replaces the
  `HCAUpgradeDisabled` revert). Owner check is load-bearing: the proxy's
  `upgradeToAndCall` is externally callable, and an upgrade doubles as mass
  session revocation — gate-only auth would let third parties grief
  in-flight reveals.
- `canUpgradeFrom` returns blanket `true` (WrapperRegistry idiom — it is a
  compatibility hook, not access control; anyone can deploy a true-returning
  contract).
- **Deploy a separate gate instance** in the `hca` deploy group. The gate
  mapping is flat; sharing the v2 instance would cross-approve registry
  implementations as HCA upgrade targets.
- Invariant caveat to preserve in review: post-upgrade, the new impl owns
  all proxy storage including `_owner` — "hard-frozen owner" becomes a
  gate-curation invariant (no admitted version may mutate the owner or
  break slot layout).

### 2. Session revocation nonce (decision F — resolved)

- `uint96 _sessionNonce` packed into the **same slot** as `_owner`.
- Replace the validator's per-validation `owner()` staticcall with a
  combined `ownerAndSessionNonce()` — same slot, same single SLOAD, ~tens
  of gas marginal.
- Add `uint256 sessionNonce` to **both** grant typehashes
  (`RegistrationSessionGrant`, `RegistrationPermit2SessionGrant`). The nonce
  is **never carried in the envelope** — the validator reads the on-account
  value and rebuilds the digest; a bump surfaces as `InvalidSigner`.
- `revokeSessions()` on the account, `msg.sender == _owner` only (~26k EOA
  tx, all-or-nothing). Session ops cannot self-bump (account self-calls have
  `msg.sender == account`).
- Direct-owner path stays nonce-free.

### 3. Resolver grant-to-owner policy rule (fixes the permanence leak)

The registration batch initializes the resolver `(hca, ROLES.ALL, [])`; the
EOA gets nothing and the policy blocks role grants — durable user state
admin'd by a disposable account, and EOA-direct record writes revert.

- Extend `_checkResolverCall` to allow the resolver role-grant selector(s)
  **constrained to grantee == owner** (one selector rule + one
  `_requireArgAddress`).
- Frontend will include the grant in the registration batch, ending with the
  EOA co-admin of its own resolver. Every HCA becomes genuinely abandonable.

Independently confirmed: a clean-room design derivation (goals only, no
code) initialized the resolver with `admin = EOA` + account as revocable
setter — same invariant.

### 4. T9 digest binding (sequenced behind decision C — do not build yet)

The validator checks policy against the envelope's `operationData` and
trusts the executor to bind it to the digest and executed ops. The mock
executor enforces this; **the live Rhinestone IntentExecutor does not know
our envelope**, so on the live route a compromised session key could sign a
digest over out-of-policy ops while presenting policy-clean operationData.
Fix (same technique as `_permit2SessionDigest`): rebuild the expected intent
digest with `mandate.destinationOps = hash(operationData)` and require it to
equal `hash`. **Blocked on capturing the live intent-digest preimage during
the decision-C orchestrator run.** Until it lands, leaked-key bounds on the
live route are `validUntil` + account emptiness + the nonce, not the policy.

### 5. Optional hardening

A `maxPrice`/fee-cap field in the grant for oracle drift across the
commit-reveal window (today exact-amount approve fails closed — safe but
retry-only). From the clean-room review; take or leave.

## What NOT to build

- **No registry targets in the policy.** `setResolver`, roles, transfers,
  subnames are structurally EOA territory (token roles live on the EOA);
  a policy change alone cannot help and a grant tx defeats the purpose.
- **No standalone primary-name session path.** Later primary-name changes
  use `setNameForAddrWithSignature` (1 EOA sig, any relayer) — strictly
  better than any HCA shape. The same-batch rule stays.
- **No new HCA-aware adapters** unless a flow appears that needs Verified
  auth (HCAAuthorizer) — the taxonomy in HCA-DESIGN.md ("flow map") says
  when: only where a contract must accept an HCA acting *for* an owner and
  neither permissionless economics (Implied) nor deploy-capture applies.

## Open items owned here

- **Decision B**: renewal product story (the rail exists and is
  policy-permitted; reuse-HCA vs spawn is undecided) and dust on frozen
  accounts.
- **Gate curation process**: who approves HCA implementations, review
  criteria (owner immutability, slot layout), optional upgrade delay.
- **Decision C run** (required): live orchestrator round-trip on the current
  account; capture the intent-digest preimage; watch the Permit2 witness
  schema — it is compiled into validator immutables.
- **Decision E**: EIP-8037 trigger point (~2.4–2.65M paid gas if it lands;
  breaks the gas invariant structurally).

## Gas position (for reviewers asking "why not cheaper")

~780k nested route at last measurement vs a measured ~693k for the
code-bound variant with equivalent features: **~87k/registration is
knowingly spent** on stock Nexus + standard 7579 module shape + one audit
surface. Invariant 6 ranks correctness/requirements above gas — twice a
gas-optimal design was invalidated by a late requirement. Re-measure on this
branch at redeploy.
