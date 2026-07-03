# HCA — Goals, Invariants, and Decisions

*2026-07-02. Supersedes `HCA-DESIGN-SUMMARY.md` (2026-06-11), which remains as a
historical snapshot of the prototype-era measurements but is stale on the
load-bearing questions (variant, sessions, upgradeability, resolver strategy,
reverse flow). Current implementation: branch `feat/hca-final-maybe` in
`contracts-v2-hca-use-what-we-have/`.*

## The application goal

A user anywhere — any chain, any wallet, holding only stablecoins — signs once
and ends up with a fully working ENS name on the v2 registry:

- the name is owned by **their EOA** (not the smart account),
- a per-user resolver is deployed and populated with records,
- their primary (reverse) name resolves via the default.reverse fallback.

Everything else in the HCA stack is mechanism in service of that checkout.
The HCA (Hidden Contract Account) lives on the destination chain, receives the
bridged payment, and executes on the user's behalf — and is never something
the user must know about, maintain, or secure. Whether it is *disposable*
(registration scaffolding) or a *standing rail* (serving the post-registration
targets too) is the central unresolved framing question — see targets T10–T13
and open decisions A/B/D, which are all versions of it.

## Targets

The concrete product targets, with status against the current branch.
Sources: the 2026-05-29 Codex thread (msg numbers), the apps-monorepo
transaction-manager machines, and the 2026-06-24 decisions.

**The registration checkout** (flows: registration machine)

| # | Target | Status |
|---|--------|--------|
| T1 | ≤ 2 wallet interactions end-to-end (msg 69); ideal is 1 — the single Permit2 signature carries stablecoin approval + session auth (msg 42) | **Met** on the executor path (1 sig); full orchestrator route unverified on current account (decision C) |
| T2 | ≤ 2 on-chain transactions: tx1 deploy+commit, tx2 register+everything (msg 27) | **Met** (bootstrapper `deployAndCommit`; tx2 batch) |
| T3 | Start from **L1 or L2** (msg 69/47): L2 start = Rhinestone/Across bridges stables to the HCA; L1 start = HCA pulls the ERC20 directly | **Partial** — L2 start validated 2026-06-03 (predecessor account); L1 start unwired: the registrar pulls from `msg.sender`, so the HCA needs the funds — how they get there on an L1 start is part of decision D |
| T4 | Pay in USDC or DAI; user never holds a gas token (relayer-sponsored) | **Met** (two policy payment tokens; sponsored route) |
| T5 | < 1M gas total incl. the ERC20 approve (msgs 70/256) | **Met** at last measurement (nested route ~780k); re-measure on this branch at redeploy |
| T6 | Front-running protection holds with sessions — the name never leaks before reveal (msgs 66-67) | **Met** (tx1 commits only to hashes/deterministic addresses) |
| T7 | Registration ends *complete*: records seeded + primary name resolving, in the same ≤2 txs (msg 60) | **Met** (records + `setNameWithHCA` in the tx2 batch; default.reverse fallback) |
| T8 | Name owned by the user's EOA, not the account | **Met** (policy: registrant == owner) |
| T9 | Relayer/session authority bounded to exactly this outcome | **Met with fine print** — full on the checked-executor path; on the live route the operationData↔digest binding is executor-trusted (see "The authorization mechanism itself"); closing fix identified, needs decision-C digest capture |

**After registration** (flows: primary-name, resolver, renewal)

| # | Target | Status |
|---|--------|--------|
| T10 | Set/update resolver records later through the same rail (msgs 63-65) | **Met** at the contract layer (resolver-bound session grants); no frontend wiring on the new stack |
| T11 | Change primary name later through the same rail (primary-name machine) | **Reframed 2026-07-02** — the HCA is the wrong tool here: `setNameForAddrWithSignature` gives 1 EOA sig + any relayer (0 tx), beating any session shape. Same-batch policy rule stays (see flow map) |
| T12 | Move the name's resolver later (resolver machine, `setResolver`) | **Not met, double-blocked** — policy has no registry targets AND `ROLE_SET_RESOLVER` sits on the EOA, so a policy change alone wouldn't help; EOA-direct 1 tx is the ideal (flow map, decision D) |
| T13 | Renew later with the same pay-with-stables property (renew snippets, msg 39) | **Partial** — policy allows `renew` (selector fixed 2026-07-02), but the later-session funding/shape is undecided (decision B) |

**Account properties**

| # | Target | Status |
|---|--------|--------|
| T14 | Hard (cryptographic) frozen single owner (2026-06-24) | **Met** today via frozen code; under resolved decision A becomes an allowlist-curation invariant |
| T15 | Upgradeable (2026-06-24) | **Direction resolved 2026-07-02** (owner-triggered, registry-bounded VF upgrade — decision A); code still reverts, lands with next redeploy |
| T16 | No per-user state in protocol contracts; consumers verify via factory + allowlist + `owner()` | **Met** (HCAAuthorizer pattern) |

The unmet cluster (T11/T12/T13, plus T3's L1 start) is one theme: the flows
that happen *after* registration, and where the money sits when there's no
bridge fill to seed the account. Decisions B and D are two halves of that one
question.

## Invariants (in priority order)

1. **Offline reveal.** Registration is commit-reveal with a mandatory delay
   (`minCommitmentAge`), cross-chain funded, fire-and-forget. The user signs
   once at commit time and is offline at reveal time. Authorization for the
   reveal must therefore be minted up front and usable later by untrusted
   infra — **sessions are load-bearing, not optional.** (This corrects the
   2026-06-11 doc's "no sessions" simplicity goal, which was derived from a
   benchmark harness that signed both ops synchronously.)
2. **Bounded session authority.** A session key goes to arbitrary relayers, so
   its blast radius must be: register a name *for the owner*, to *the owner's
   resolver*, spending only via approvals *to the registrar*. This invariant is
   what `OwnerBoundRegistrationSessionValidator`'s policy engine exists to
   enforce; it is the largest piece of code in the stack and had no
   corresponding goal in the old doc.
3. **Protocol split (account side).** The account is deployed through the
   generic `VerifiableFactory`; no ENS protocol contract records ownership.
   Consumers verify `verifyContract(caller)` + implementation allowlist +
   `owner()` (the `HCAAuthorizer` pattern). Note the scope: the *account* is
   protocol-agnostic; the session *validator* is deliberately
   protocol-coupled — it is the policy.
4. **Two wallet interactions max, from an L1 or an L2 start** (2026-05-29
   thread, msg 69). The single Permit2 signature carries both the stablecoin
   approval and the session authorization (msg 42). Two funding origins, one
   destination flow: an L1 start has the HCA pull the ERC20 directly; an L2
   start has Rhinestone/Across bridge the stablecoin to the fresh HCA
   (msg 47) — this is the L2 → L1 funding pipeline. Registration must be
   executable by arbitrary callers through standard `IntentExecutor` paths.
   Caveat: the Rhinestone SDK refuses `experimental_sessions` on this account
   shape, so sessions are bespoke signature-format inside the validator —
   compatibility is via the ERC-1271 envelope, deliberately around the SDK's
   session machinery.
5. **Single hard-frozen owner** (2026-06-24 decision): the owner binding must
   be a cryptographic guarantee, not a policy promise.
6. **Under 1M gas total** for deploy + commit + register + records + reverse,
   *including* the ERC20 approve (2026-05-29 thread, msgs 70/256 — the
   original budget the benchmarks were run against). Per-registration overhead
   is effectively part of the name's price. Invariants 1–5 rank above gas —
   twice now a gas-chosen design was invalidated by a requirement arriving
   later (code-bound spike, DirectOwner).
7. **Sessions outlive registration for record management** (2026-05-29 thread,
   msgs 63–65): a user should be able to set records on their resolver in a
   later session without re-registering. Satisfied today — a session grant
   bound to the user's resolver passes the policy without a register call in
   the batch. Only later *default-name* updates are blocked by the same-batch
   rule (see open decision B).

Flow-level constraints that still hold from the old doc: no privacy leak (tx1
commits only to deterministic addresses; the label appears only in tx2 reveal
calldata), seeded resolver writes require the HCA caller, and the registrar
pulls payment from the SCA — never the owner argument.

## What actually ships (feat/hca-final-maybe, as of 2026-07-02)

- **Account:** `StandaloneSingleOwnerHCA` (stock Nexus + baked-in default
  validator/executor; accountId `ens-standalone-hca.1.0.0`). This is the
  variant the June benchmarks scored ~39–49k gas/registration worse than
  `StandaloneDirectOwnerHCA` — but the comparison was apples-to-oranges:
  DirectOwner's numbers omitted the session machinery production requires
  (invariant 1). Shipping SingleOwner = paying the module tax to stay on stock
  Nexus + standard validator-module shape. **This trade has not been formally
  ratified — see open decision A.**
- **Validator:** `OwnerBoundRegistrationSessionValidator` — stateless,
  baked in as the default validator. Direct owner signatures, legacy EIP-191
  session grants, and Permit2-shaped grants (Rhinestone JIT witness). Enforces
  the invariant-2 policy: ETHRegistrar commit/register/renew, policy-resolver
  record setters, `setNameWithHCA` (same batch as its register call only),
  ERC20 approve-to-registrar, `deployProxy` of the permitted resolver impl.
- **Reverse:** default.reverse fallback via
  `DefaultReverseRegistrarAdapter.setNameWithHCA`. The v1 exact-reverse
  `claimWithHCA` path was removed 2026-07-02 (no product flow used it;
  `ReverseRegistrarAdapter` itself remains).
- **Resolver:** `PermissionedResolver` behind a VerifiableFactory proxy,
  seeded via record setters in the tx2 batch. The old doc's `BoundHCAResolver`
  Solady-clone optimization (~100k) did **not** ship; nobody has decided
  whether to revive it.
- **Deploy pipeline:** `deploy/hca/00–04` (mock executor on devnet, validator,
  bootstrapper, implementation, adapter trust setup) — exercised by the e2e
  suite via the devnet as of 2026-07-02.
- **Live validation:** `script/checkLiveHcaRegistration.ts` (via
  `bun run check:hca-live`) runs the Sepolia flow with SDK-exact typed data,
  self-submitted single-chain. The full orchestrator round-trip
  (quote → Permit2 deposit → Across → relayer fill) was last validated
  2026-06-03 on the predecessor account, not the current one.

## Cross-chain pipelines

**Funding (L2 → L1):** the user's stablecoins live on an L2 (Base in the live
route; `PERMIT2_SOURCE_CHAIN_ID = 8453`); Rhinestone/Across bridges them to
the fresh HCA on the registration chain during tx1, and the commit-reveal
delay absorbs bridge settlement latency. An L1 start skips the bridge — the
HCA pulls the ERC20 directly under the same Permit2 signature. Origin of
record: the 2026-05-29 Codex thread
(`~/.codex/sessions/2026/05/29/rollout-2026-05-29T17-59-44-*.jsonl`), which is
also where the ≤2-interactions and sub-1M-gas constraints were set.

### Resolution (registry → L1 consumers)

Registrations happen on the v2 registry (L2/Namechain side); consumers mostly
look from L1. Both directions are acceptance criteria enforced by the live
check and e2e, though no earlier doc stated them:

- **Forward:** the registered name and its records must resolve through
  `UniversalResolverV2` (the L1 entry point; CCIP-read gateway in production).
  Verified by `checkLiveHcaRegistration` (`urForward`).
- **Reverse:** HCA-registered users get their primary name via the
  **default.reverse fallback only** (`DefaultReverseRegistrarAdapter.
  setNameWithHCA`). The per-user v1 `addr.reverse` node is deliberately left
  unclaimed (`claimWithHCA` removed 2026-07-02; e2e asserts the v1 reverse
  resolver is zero). Tradeoff accepted: no per-user L1-side reverse write, but
  consumers that read the v1 reverse registrar directly — legacy libraries
  that don't implement the UR fallback logic — see no primary name for these
  users. Verified by `urReverse` + `exactV1ReverseResolver` in the live check.

## Rhinestone SDK utilization

Today the SDK is used in two disjoint ways: the frontend runs the full
lifecycle (`sdk.createAccount({ account: { type: 'hca' }, owners: { type:
'ens', ... } })` → `getAddress`/`isDeployed` → `prepareTransaction` → sign →
`submitTransaction`) against the **old** factory HCA that Rhinestone
registered as the SDK's `hca` account type; the contracts-side live check
deep-imports the SDK's internal `getTypedData` module (via the
`RHINESTONE_SDK_SINGLE_CHAIN_OPS` path) just to hash intents identically, and
self-submits.

**Ideal shape** — one principle: *the SDK is the orchestrator client and the
hashing source of truth; the account and the sessions are ours.*

- **Keep the SDK lifecycle unchanged** from the frontend's perspective:
  `createAccount` → address → `prepareTransaction` → sign → `submitTransaction`
  → poll fill. The orchestrator API (quotes, Across settlement, Permit2
  funding, sponsored fills, `using7579: false` destination ops) is exactly
  what the SDK is for; never reimplement it.
- **Retarget the SDK's `hca` account type** to the standalone stack: address
  derivation from VerifiableFactory salt + implementation, and the
  `owners: { type: 'ens' }` signer assembling the
  `OwnerBoundRegistrationSessionValidator` envelope (owner sig, or
  Permit2-shaped grant + session sig + operationData). Rhinestone already
  ships an ENS-specific account type, so this is an update to that
  integration, not a new kind of ask.
- **Deploy routing — a fixed-caller wrapper is mandatory.** VerifiableFactory
  mixes `msg.sender` into the CREATE2 salt, so the account address depends on
  who calls `deployProxy`; deploys must route through a stable-address
  contract, never the factory directly. Two options for the SDK's
  `{factory, factoryData}` slot: (a) `RegistrationBootstrapper.deployAndCommit`
  — fuses deploy + commit into tx1, but makes `factoryData` per-registration
  (it embeds the commitment), which needs late-bound init data from the SDK;
  (b) a plain fixed-caller deployer in the factory slot, with commit as the
  first destination op through the HCA in the same fill — static factoryData,
  same tx count, and the bootstrapper then only serves direct
  (non-orchestrator) flows. Which one is viable is a concrete question for
  Rhinestone. Note repeat registrations never hit the factory slot — commit
  always travels as an HCA op once the account exists (the policy allows it).
- **Sessions stay invisible to the SDK.** SmartSession is out
  (`experimental_sessions` is refused on this account shape, and the module
  tax was the reason to bake our own validator). From the SDK's point of view
  there is only "produce a signature for this intent digest" — the envelope
  assembly is our signer callback. No SDK session APIs anywhere.
- **Kill the deep import.** `hcaSessions.ts` and the validator already vendor
  the Permit2 witness typehashes; the right guard is a parity test asserting
  our digest equals the SDK's `getTypedData` output for the pinned SDK
  version, plus an ask to Rhinestone to export the intent typed-data builder
  publicly. The witness hashing is the single fragile seam with their
  releases (see decision C).

Asks to Rhinestone, consolidated: (1) point the SDK `hca` account type at the
standalone implementation + VerifiableFactory derivation; (2) public export of
the intent typed-data builders; (3) `getDeployArgs` should not throw for this
account shape (or document the supported path); (4) can `factoryData` be
late-bound (computed at `prepareTransaction` time) so the deploy call can
carry the registration commitment — or must deploy data be static per
account (which forces the split-deployer shape above)? (5) can the route
bundle an EIP-2612 `permit(owner, Permit2, …)` submission on the source
chain ahead of the Permit2 claim, so a fresh wallet (no Permit2 allowance,
no gas token) stays fully gasless (flow-map finding 6)?

## Frontend flows (apps-monorepo)

The consuming flows live in `apps-monorepo/packages/transaction-manager`
(state machines: **registration**, **primary-name**, **resolver**) and
`packages/smart-account` (Rhinestone provider). All three machines have
rhinestone-intent branches today — but they target the **old factory-based
stack**: the account is deployed via `HCAFactory.createAccount(initData)`
(CREATE3 ERC-1967 proxy), funds stay on the EOA ("the HCA holds no funds"),
the EOA infinite-approves the registrar directly, and gas is sponsored by the
Warp relayer.

Migrating the frontend to the standalone stack surfaces four gaps:

1. **Funding model conflict.** The contracts registrar pulls payment from
   `msg.sender` (`AbstractETHRegistrar`), so an HCA-routed register requires
   HCA-held funds and an HCA-side approve — the frontend's EOA-approve model
   only works when the register call itself is a direct EOA tx. The frontend
   comment "registrar pulls from the name owner" describes the pre-2026-05-29
   registrar semantics. One of the two models has to move.
2. **Primary-name flow breaks twice.** It sends `reverseRegistrar.setName`
   through the intent — via an HCA, `msg.sender` is the HCA, so it would set
   the *HCA's* primary name. The adapters exist for this
   (`setNameWithHCA`), but the validator's same-batch rule blocks standalone
   default-name sessions (open decision B), and `claimWithHCA` was removed.
3. **Resolver flow is blocked.** It calls `PermissionedRegistry.setResolver`;
   the validator policy allows no registry targets at all.
4. **Account provenance.** `HCAFactory.createAccount` vs
   `VerifiableFactory.deployProxy` + bootstrapper — different account, different
   address derivation, different trust verification (`getAccountOwner` vs
   `verifyContract` + allowlist).

Post-registration resolver *record* writes (the flow requirement from the
2026-05-29 thread) are covered by resolver-bound session grants; the gaps
above are about resolver *changes*, primary-name updates, and payment.

There is a fifth gap, found 2026-07-02 while mapping flows: **EOA-direct
record writes are blocked on the standalone stack.** The registration batch
initializes the resolver with the HCA as sole role-holder
(`initialize(hca, ROLES.ALL, [])`), the EOA gets no resolver roles, and the
validator policy does not allow `authorizeNameRoles` — so the HCA cannot even
grant them through a session. The app's EOA-signer record editors
(`ProfileEdit.transactions.ts`, `saveRecords.ts`) would revert against an
HCA-deployed resolver. Recommended fix (see the model assessment in the flow
map): extend the policy with resolver role-grant selectors constrained to
grantee == owner and perform the grant inside the registration batch, making
the EOA co-admin of its own resolver (see decision D).

## Flow map: ideal wallet interactions and HCA auth modes (2026-07-02)

Every core user flow, with the interaction count the architecture *supports*
(current app counts in parentheses where they differ). "Interaction" = any
wallet prompt, transaction or signature. Sources: apps-monorepo flow inventory
(13 flows across portal/manager/transaction-manager) + the v2 contracts' auth
models.

**The four HCA auth modes** (how a protocol contract comes to accept an HCA):

- **Implied** — permissionless, parameter-bound contract: payment pulled from
  the caller, output bound to an `owner`/label argument. Nothing verifies the
  HCA; the caller is economically irrelevant. (`ETHRegistrar.commit/register`,
  `AbstractETHRegistrar.renew`, ERC20 `approve` of HCA-held funds.)
- **Captured** — the HCA initialized the contract and holds admin roles from
  birth (`PermissionedResolver.initialize(hca, ROLES.ALL, [])` inside the
  registration batch). Zero user action, ever.
- **Verified** — an HCA-aware contract structurally verifies the caller via
  `HCAAuthorizer` (`VerifiableFactory.verifyContract` + trusted-implementation
  allowlist + `owner()` readback). Zero user action, but needs an adapter per
  consumer. (`DefaultReverseRegistrarAdapter.setNameWithHCA`.)
- **Granted** — the EOA must send an onchain tx to authorize the HCA
  (`PermissionedRegistry.grantRoles`, operator approval). Costs what it saves
  for one-shot ops; only pays off for recurring delegation.

| Flow | Ideal | Shape | HCA usable? | Auth mode |
|---|---|---|---|---|
| Registration, L2 start | **1–2** (app: 4) | one Permit2 typed-data sig = bridged funding + session grant; relayer runs deploy+commit fill then the register batch. +1 one-time Permit2 allowance on the source-chain token if missing (finding 6) | executes everything | Implied (registrar) + Captured (resolver) + Verified (reverse) |
| Registration, L1 start | **1–2** | same shape from L1-held funds; same one-time Permit2 allowance caveat | same | same |
| Renewal | **1** (app: 1–2 EOA txs, no intent path) | same Permit2 rail — fund HCA + grant; `renew` is permissionless and pulls from the caller | executes approve + renew | Implied |
| Record writes (v2 resolver) | **1 sig, 0 tx** (app: 1 tx) | legacy EIP-191 session grant bound to the resolver; no funding leg; sponsored relayer executes | executes the multicall | Captured |
| Primary name at registration | **0 extra** | rides the tx2 batch (`setNameWithHCA`, same-batch rule) | yes | Verified |
| Primary name later | **1 sig, 0 tx** (app: 2) | EOA signs a `setNameForAddrWithSignature` claim; any relayer submits | **wrong tool** — the EOA signature IS the auth; HCA adds nothing | — |
| Resolver change (`setResolver`) | **1 tx**, EOA | direct call; `ROLE_SET_RESOLVER` lives on the EOA from registration | can't: policy blocks registry targets AND roles are EOA-held (double-blocked) | Granted in principle, pointless for one-shot |
| Roles grant/revoke | **1 tx**, EOA | direct; the `*_ADMIN` roles are EOA-held | can't | — |
| Subregistry setup | **2 tx**, EOA (1 with a batching wallet) | VF `deployProxy` + `setSubregistry` | not today (see below) | future: Captured |
| Subname create/delete | **1 tx each**, EOA | role-gated on the subregistry admin | not today | future: Captured + policy |
| Name transfer | **1 tx**, EOA | ERC1155 `safeTransferFrom`; `ROLE_CAN_TRANSFER_ADMIN` checked on the owner | **never** — custody risk; policy blocks it by design | — |
| Burn fuses (v1 NameWrapper) | 1 tx, EOA | legacy v1 surface | out of scope | — |

### Is the HCA the right model? (assessment 2026-07-02)

Verdict: **yes on the fundamentals**, with one structural fix. The map itself
is the evidence: the HCA is load-bearing for exactly the flows that need
money movement + atomic multi-step execution + offline authorization
(registration, renewal, record writes) — things an EOA signature cannot do
against a `msg.sender`-pull registrar — and correctly excluded from every
identity/authority flow (roles, transfers, resolver changes, primary-name),
where plain EOA paths are equal or better. The decomposition holds: **EOA =
identity, HCA = disposable payment/execution plumbing.** T8 (name on the
EOA) is what makes disposability real. The T11/T12 reframes are the model
refusing to absorb flows it shouldn't — a feature.

Alternatives considered and why they lose today: **EIP-7702** dissolves the
two-address problem but wallets only sign authorizations for their own
delegate contracts (no dapp-chosen delegates) and ERC-7715 permissions are
not uniformly deployed — the HCA needs zero wallet cooperation, any
typed-data-capable EOA works. **Registrar-level Permit2** (protocol change)
fixes only the L1 start and smears account concerns into protocol contracts
the design keeps account-agnostic; the L2 start still needs intent rails,
and intent rails need a destination account. **A bespoke settlement
contract** means rebuilding Across/Rhinestone's cross-chain atomicity — the
HCA is the price of renting existing rails.

The one violation of the model's own principle: **the resolver permanence
leak.** Durable user state (the resolver) is Captured by a disposable
account — HCA holds `ROLES.ALL`, EOA holds nothing, policy blocks granting
out. Recommended fix (upgrades the fifth-gap "options" to a decision):
extend the resolver-call policy with role-grant selectors constrained to
**grantee == owner**, and include that grant in the registration batch, so
registration ends with the EOA co-admin of its own resolver and every HCA
is genuinely abandonable. One selector rule + one arg check.

Shelf-life caveat, held honestly: this is **bridge-era infrastructure**.
7702+7715 maturing (wallet-native sessions) and EIP-8037 (decision E) both
erode it. The hedge is already in place — with the EOA owning name and
(post-fix) resolver, moving off HCAs is abandonment, not migration. The
standing guard-rail: any design that parks *durable* authority on the HCA
is a bug.

### The authorization mechanism itself (assessment 2026-07-02)

The shape is right and should be kept: a two-signature stateless envelope
(owner grant + session-key op signature) is the only design that is
simultaneously cheap (no storage, no installs), offline-capable, and safe to
publish; code-as-policy (one auditable file, no configurable policy data to
phish or misconfigure) beats SmartSession (heavier; SDK refuses it on this
shape anyway), ERC-7715 (not deployed), and configurable-policy validators.

**The soundness fine print — the operationData↔digest binding (T9).** The
validator checks policy against the envelope's `operationData` and trusts
its caller to bind that to the digest and to the ops actually executed. The
mock executor enforces this binding onchain
(`MockRegistrationIntentExecutor._checkSignedOperationData` + digest =
`keccak256(operationData)`), so tests prove full T9. The live Rhinestone
`IntentExecutor` computes the intent typed-data digest and executes the
intent's ops but knows nothing of our envelope — nothing onchain checks
that `sigData.operationData` matches the intent's destination ops. On that
path the policy binds honest clients; a **compromised session key** (the T9
adversary) could sign a digest over out-of-policy ops while presenting
policy-clean operationData, falling back to the weaker bounds (validUntil,
account emptiness, decision-F nonce). Candidate fix, using the technique
already in `_permit2SessionDigest`: rebuild the expected intent digest from
envelope fields with `mandate.destinationOps = hash(operationData)` and
require it to equal `hash` — closes the gap onchain, deepens the schema
pinning (acceptable: coupling is recoverable via decision-A upgrades, a T9
gap is not). Prerequisite: capture the real intent-digest preimage during
the decision-C run.

Structural risks, priced in: (1) **vendor schema in immutables** — six
Rhinestone/Permit2 typehashes pinned to SDK v1.7.0; escape hatch is the
decision-A upgrade path; asks (2)/(5) reduce surprise. (2) **illegibility**
— grants render as an opaque Permit2 witness; users can't read "registers
x.eth with resolver Y"; mitigated by frontend rendering, really fixed only
by ecosystem-level legible permissions (same bridge-era story as the
account model). Minor note: the direct-owner path 1271-attests any digest
the owner ever signed (given a policy-clean envelope) — standard
1271-wrapper cross-context behavior, acceptable for a valueless account.

### Clean-room validation (2026-07-02)

A fresh model instance was given only the goals, protocol facts, and
environment facts (no design, no code) and asked to derive the optimal
architecture. It **converged on every structural decision**: per-user
counterfactual throwaway ERC-7579 account as register's `msg.sender` (after
eliminating trusted relayers, a singleton router, 4337-owns-name, 7702, and
pre-signed txs on the same grounds we did), EOA owns the name, a single
EIP-712 artifact doubling as the Permit2 witness and the ERC-1271
authorization **with validator-side reconstruction of the Permit2 digest
including the source-chain domain** (independently reinventing
`_permit2SessionDigest`), policy enforced in the account's validator,
resolver deployed via VF inside the reveal batch, EIP-2612 for the Permit2
cold start, ~800k gas estimate (our measured band) — confirming the budget
is structural, dominated by register (~250k) + resolver proxy (~120k) +
account deploy (~90k) + funds-in (~90k).

Deltas, each instructive:

- **It initialized the resolver with `admin = EOA` and the account as a
  revocable setter** — independently confirming the resolver permanence
  leak and its fix. Its init-time shape needs a multi-grantee `initialize`;
  our in-batch grant-to-owner achieves the same invariant with deployed
  contracts.
- **No session key** — the owner signs an exact-batch order at commit time.
  This works only if the fill-time digest is fully predictable or
  validator-reconstructable; Rhinestone's intent digest carries fill-time
  fee/nonce fields, which is exactly why we need an ephemeral signer. Its
  "validator executes only the exact signed batch" property is equivalent
  to our T9-closing fix. Standing note: if the rails ever allow pinning or
  late-binding those fields (asks 2/4), the session key can be dropped for
  owner-signed exact batches — one less moving part and leak surface.
- **It paid 2 registration signatures** (order + stock reverse-registrar
  signature format); our `setNameWithHCA` adapter (Verified mode) folds
  reverse into the batch and reaches 1 — the one place the shipped design
  beats the clean-room derivation, and the adapter's justification.
- Minor hardening idea worth stealing: an explicit **maxPrice/fee-cap field**
  in the grant to handle oracle drift across the commit-reveal window
  (today: exact-amount approve fails closed on price rises — safe but
  retry-only).
- It insisted the account implementation be **frozen**; we chose gated
  upgrades (decision A) for fleet lifecycle + emergency revocation — a
  reminder that the gate's curation carries real security weight.

Findings that fall out of the map:

1. **Registration 4→1 is the funding-model move.** The app's four prompts
   exist because funds sit on the EOA (separate mandatory approve tx — the
   registrar pulls from `msg.sender`, and the intent path can't sign an EOA
   approve) and deploy/commit/register are separate intents. Bridging funds
   to the HCA and folding approval + session grant into one Permit2 signature
   removes three of the four.
2. **Renewal is the strongest unused fit.** `renew` is permissionless with
   caller-pays — exactly the session-rail shape, policy already allows it.
   Only the product story (decision B: reuse the HCA vs spawn one) is open.
3. **Primary-name-later should not use the HCA** (reframes T11). The
   signature-relay path gets 1 sig / 0 tx with no session machinery; the
   app's current intent path spends a second interaction using the HCA as a
   mere relay. The validator's same-batch rule can stay.
4. **Registry-level ops are structurally EOA territory.** Their auth is
   token-roles held by the EOA; involving the HCA costs an explicit grant tx
   that defeats the purpose for one-shot ops. The exception worth designing
   for later: recurring subname management via an HCA-admin'd subregistry
   (the resolver's Captured pattern applied to `UserRegistry`), which would
   turn N subname txs into 1 grant signature — needs a policy extension.
5. **EOA-direct record writes are blocked** on HCA-deployed resolvers (fifth
   frontend gap above) — the one place where Captured auth cuts the *user*
   out along with everyone else.
6. **The Permit2 allowance bootstrap is identical on both starts**
   (2026-07-02 correction — the L2 row originally omitted it). Permit2 needs
   a one-time ERC20 approval on whichever chain the funds leave from. Active
   wallets usually have it (Uniswap made Permit2 allowances near-universal);
   a fresh wallet does not, and the naive fix — an `approve` tx — needs a gas
   token on the source chain, breaking T4. The gasless bootstrap: USDC
   supports EIP-2612, so the wallet signs `permit(owner, Permit2, …)` and a
   relayer submits it — 2 signatures, 0 txs, still inside T1's ≤2 budget.
   Whether the Rhinestone route can bundle that permit into the fill is
   ask (5). Note the June 3 live proof never surfaced this: the test EOA had
   pre-approved Permit2 on Base, and `check:hca-live` is self-submitted
   single-chain so the source funding leg doesn't run.

## Open decisions

**A. Frozen vs upgradeable — direction resolved 2026-07-02: frozen owner
model, upgradeable account via the VF mechanism, allowlist-bounded.**
Not yet implemented — `_authorizeUpgrade` still reverts (`HCAUpgradeDisabled`);
this lands with the next redeploy (needed anyway for the 7→6 validator
constructor and the renew-selector fix).

The VF proxy (`UUPSProxyLogic`) has no admin: `upgradeToAndCall` (1) requires
the **new** implementation to accept the migration via
`canUpgradeFrom(currentImpl)` — a direct call, so immutables work and
predecessor addresses are known at deploy time — then (2) delegatecalls the
upgrade into the **current** implementation, so `_authorizeUpgrade` is the
sole authorization gate. `canUpgradeFrom` is a storage-layout/compatibility
guard, **not** access control (anyone can deploy a contract returning true).

Chosen shape — reuse the existing `ApprovedUpgradeGate` pattern
(`src/registry/ApprovedUpgradeGate.sol`, already consumed by
`WrapperRegistry` and deployed in the v2 group via
`deploy/03_ApprovedUpgradeGate.ts`):

- `_authorizeUpgrade(newImpl)` requires **both** `msg.sender == owner()` and
  `UPGRADE_GATE.approvedImplementations(newImpl)`, where `UPGRADE_GATE` is an
  immutable `ApprovedUpgradeGate` pointer (an `Ownable` allowlist owned by the
  `owner` named account). An external gate is the only shape that works: the
  list cannot live in implementation storage (delegatecall context → per-proxy
  slots) nor in forward immutables (future addresses unknown). This mirrors
  `WrapperRegistry._authorizeUpgrade` exactly, with `msg.sender == owner()`
  standing in for `ROLE_UPGRADE`.
- Owner-trigger is load-bearing: `proxy.upgradeToAndCall` is externally
  callable, and an upgrade kills every outstanding session grant (the account
  stops consulting the validator that honors them). Gate-only authorization
  would let third parties force-migrate accounts and grief in-flight reveals.
  Owner + gate together also bound phishing: a tricked owner signature can
  only move the account between vetted versions. Because the VF proxy
  delegatecalls with `msg.sender` preserved, the owner upgrades via a plain
  EOA transaction — no session or executor involvement.
- `canUpgradeFrom` returns blanket `true`, matching the `WrapperRegistry`
  idiom — it is a compatibility hook, not access control (anyone can deploy a
  true-returning contract); layout-compatibility vetting lives with the gate
  curator.
- **Separate gate instance for the HCA family** (same artifact, new deployment
  in the `hca` group): the gate mapping is flat, so sharing the v2 instance
  would make every approved `WrapperRegistry` implementation an approved HCA
  upgrade target (owner-triggered self-harm only, but storage-collision
  nonsense the curation process shouldn't have to reason about).
- **Invariant 5 caveat:** post-upgrade, the new implementation owns all proxy
  storage including `_owner` — "owner never changes" becomes an
  allowlist-curation invariant (every admitted version is vetted to have no
  owner-mutation path and to preserve the slot layout), not a bytecode
  invariant. This is the accepted reading of "hard-frozen owner" under T15.

Remaining sub-decisions: who curates the HCA gate (same `owner` account as the
v2 gate?), and whether upgrades are additionally guarded (e.g. delay) given
the emergency-session-revocation dual use. Also ratifies the SingleOwner
variant choice above.

**B. Post-registration lifecycle.** Renewals: the policy permits `renew`, but
the rail is registration-session-shaped — "renew from my phone with USDC on
Base, two years later" has no decided story (reuse the HCA? spawn another?).
Dust: leftover USDC on a frozen, module-less account has no exit
(`ownerExecute` from the June spike was not ported). Both need product calls.

**C. Orchestrator re-validation — upgraded from nice-to-have to required
(2026-07-02).** Run the real Rhinestone route once with the current account +
validator (cross-chain, relayer-submitted), and **capture the exact intent
typed-data digest preimage** the live executor validates against. T9's full
strength depends on it: the operationData↔digest binding is
executor-trusted on the live route (see "The authorization mechanism
itself"), and the closing fix — validator-side reconstruction of the intent
digest with `mandate.destinationOps = hash(operationData)` — needs the real
preimage layout confirmed before it can be built. Watch the Permit2 witness
schema — it is the fragile seam if Rhinestone changes hashing.

**D. Frontend migration to the standalone stack.** apps-monorepo's three
rhinestone-intent flows target the old factory HCA (see "Frontend flows"
above). Decide the funding model (EOA-approve vs SCA-holds-funds — the
new registrar's `msg.sender` pull forces this), how EOA-direct record writes
work against HCA-admin'd resolvers (fifth gap: policy extension for
`authorizeNameRoles` grant-to-owner vs HCA-mediated-only), and when the
smart-account provider switches from `HCAFactory.createAccount` to the
bootstrapper path. Per the flow map, primary-name-later moves to the
signature-relay path (no HCA) and `setResolver` stays EOA-direct — the
policy does not need to grow for either. Until migration the standalone
stack has no consumer.

**E. EIP-8037 exposure.** Per-registration state creation (account proxy +
resolver proxy + ~10 slots) models to ~2.4–2.65M paid gas if the draft lands,
which would break invariant 6 structurally. No mitigation decided; needs a
trigger point (e.g., revisit if 8037 reaches last-call).

**F. Session revocation nonce — direction resolved 2026-07-02.** Worst-case
lever for a leaked session key: the owner bumps a nonce and every outstanding
grant dies. Not yet implemented; lands with the same redeploy as decision A.
Chosen shape (nearly gas-free via slot packing):

- `uint96 _sessionNonce` packed into the same storage slot as `_owner` on the
  account. The validator already staticcalls `owner()` on every validation —
  a combined `ownerAndSessionNonce()` getter returns both from the same
  single SLOAD, so the marginal validation cost is tens of gas (one extra
  return word + one extra word through `_sessionGrantHash`).
- Both grant typehashes (`RegistrationSessionGrant`,
  `RegistrationPermit2SessionGrant`) gain a `uint256 sessionNonce` field. The
  nonce is **never carried in the signature envelope** — the validator reads
  the authoritative value from the account and rebuilds the digest with it;
  a bumped nonce surfaces as `InvalidSigner` (frontends should map that to
  "grant revoked/stale" when the account nonce moved). The Permit2 witness
  embeds our grant struct hash, so Rhinestone's schema is untouched.
- `revokeSessions()` on the account, gated `msg.sender == _owner`, increments
  the nonce (~26k gas EOA tx, all-or-nothing). A leaked session key cannot
  grief-bump: account execution paths call *from* the account, so self-calls
  have `msg.sender == account`, never the owner. Per-grant revocation
  (bitmap) was rejected — it needs validator-side storage (+2100/validation)
  and grants are minutes-scale, freely re-mintable signatures anyway.
- Direct owner signatures (`sessionKey == 0`) stay nonce-free.
- Frontends read the nonce (view call) when minting a grant.

Escalation ladder this completes: `validUntil` (automatic expiry) → nonce
bump (leaked session key, kills grants) → gated upgrade per decision A
(compromised implementation, kills the validator relationship itself). The
validator itself stays stateless — session state lives in the account's
existing owner slot.

## Audience handoffs (derived from this doc, 2026-07-02)

- [`HCA-HANDOFF-PROTOCOL.md`](./HCA-HANDOFF-PROTOCOL.md) — the redeploy
  work-package (gated upgrades, session nonce, grant-to-owner policy rule,
  T9 binding fix), what not to build, open items.
- [`HCA-HANDOFF-FRONTEND.md`](./HCA-HANDOFF-FRONTEND.md) — apps-monorepo
  migration: per-flow changes, session client responsibilities, dependency
  order.
- [`HCA-HANDOFF-RHINESTONE.md`](./HCA-HANDOFF-RHINESTONE.md) —
  external-facing integration notes and the six asks, prioritized.

This file wins on conflict.

## Reading order for the history

1. This file — current goals and state.
2. `HCA-DESIGN-SUMMARY.md` — 2026-06-11 snapshot: prototype rationale, gas
   tables (read with the session caveat above), naming history.
3. Project memory `hca-design-direction` / `hca-standalone-gas-benchmarks` —
   the 2026-06-24 corrections and the raw benchmark provenance.
