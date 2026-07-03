# HCA/SCA Redesign — What We're Actually Looking For

> **SUPERSEDED 2026-07-02 by [`HCA-DESIGN.md`](./HCA-DESIGN.md).** This file is
> a historical snapshot. Known-stale claims: "no sessions" (sessions are
> load-bearing — the reveal executes while the owner is offline), the
> DirectOwner-vs-SingleOwner benchmark comparison (DirectOwner numbers omit
> mandatory session costs), "upgrades disabled" as a goal (upgradeability
> became a hard requirement 2026-06-24, still unresolved), `BoundHCAResolver`
> (never shipped), and "reverse claim via the HCA adapter" (replaced by the
> default.reverse fallback; `claimWithHCA` removed from the flow 2026-07-02).

*Compiled 2026-06-11 from the prototype work in this workspace, the Codex session history (June 3–10), and the `feat/verifiable-reverse-adapters` branch.*

## TL;DR

We are replacing the factory-coupled HCA (Hidden Contract Account) design with a **standalone, immutable, single-owner smart account** that is:

1. **Completely split from the ENS protocol** — deployed through the generic `VerifiableFactory`, not an `HCAFactory`; no protocol contract records ownership.
2. **Self-describing** — the account stores its own owner and exposes `owner()`; consumers verify the caller through `VerifiableFactory.verifyContract()` + a trusted-implementation allowlist instead of querying a factory registry.
3. **As simple as possible** — one immutable owner, module install/uninstall reverted, upgrades disabled, NFT receipt blocked. No sessions, no per-proxy module installs.
4. **Permit2-compatible** (hard requirement) and **Rhinestone-relayer-accessible** (registration must be executable by arbitrary callers through standard `IntentExecutor` paths, without doubled validation or needing to know the relayer address).
5. **Cheap** — every design decision was driven by measured gas on Sepolia forks; the canonical two-tx registration flow now totals ~692k–737k gas depending on entry path.

## Background: the design we're moving away from

The factory-based design (in `contracts-v2-hca-write/`, the rhinestone `ens-modules` `hca` branch, and the live Sepolia deploy) works like this: `HCAFactory.setAccount`/`createAccount` records `msg.sender` as the HCA's owner; consumers resolve ownership via `IHCAFactoryBasic.getAccountOwner(hca)`; the account is a Nexus (ERC-7579/4337) instance with an `HCAModule` validator, `IntentExecutor` executor, and a SmartSession emissary. Key problems discovered:

- Ownership lives in a protocol contract, coupling the account to ENS infrastructure. The future design has **"the HCA completely split from the protocol."**
- The module machinery (per-proxy validator/executor installs, session validation) costs real gas on every account creation and validation.
- SDK friction: the HCA intentionally rejects `installModule`, so standard Rhinestone SDK flows (`experimental_enable()`) break; only the permission-config path (`experimental_enableSession()`) works. Sessions added complexity without being needed for the core use case.

## The new account: standalone single-owner HCA

Prototyped in `hca-permit2-proto/`:

- **`StandaloneDirectOwnerHCA.sol`** — **the chosen variant.** Extends Nexus; immutable `_owner` set once in `initializeAccount(abi.encode(owner))`; validates UserOps and ERC-1271 locally with plain ECDSA against `_owner`; `installModule`/`uninstallModule` revert; `_authorizeUpgrade` reverts; NFT callbacks revert. No per-proxy executor install. Account ID `ens-standalone-direct-owner-hca.1.0.0`.
- **`StandaloneSingleOwnerHCA.sol` + `StandaloneSingleOwnerValidator.sol`** — the stepping-stone variant that delegates validation to a default validator module. Benchmarked 2026-06-11: loses to DirectOwner by **39k–49k gas per registration** (constant +30,453 on tx1 from the executor `onInstall`, plus per-validation module roundtrips) and its implementation deploy is ~600k heavier. **No reason to prefer it.**

Deployment: `VerifiableFactory.deployProxy(implementation, salt, initData)` — the same factory used for resolver proxies, already deployed on Sepolia at `0xD2a632D8A8b67C2c4398c255CBD7af8dD7236198`. Constraint learned along the way: **init data generation cannot be in the factory** (the owner must be encoded by the caller, not derived).

## Authorization pattern: HCAAuthorizer (the `feat/verifiable-reverse-adapters` path)

Productionized in `contracts-v2-verifiable-reverse-adapters/` (branch `feat/verifiable-reverse-adapters`, based on `origin/post-audit`):

- **`HCAAuthorizer.sol`** (`contracts/src/utils/`) — abstract `Ownable` base. To authorize an action for `account`, the HCA calls the adapter; the adapter runs:
  1. `VERIFIABLE_FACTORY.verifyContract(msg.sender)` → returns the checked implementation (post-crit-fix interface of verifiable-factory: no more passing the expected implementation in).
  2. Implementation must be in the owner-managed `trustedHCAImplementations` allowlist.
  3. `Ownable(msg.sender).owner()` (reusing the OZ interface, no bespoke `IHCAOwner`) must equal `account`.
- **`ReverseRegistrarAdapter.claimWithHCA(account, resolver)`** and **`DefaultReverseRegistrarAdapter.setNameWithHCA(account, name)`** — new standalone methods added *alongside* the existing factory-based methods, with unit tests at 100% coverage (`MockHCA`/`MockRevertingHCA` mocks).
- Naming history (so nobody relitigates it): VerifiableProxyNamer → AccountNamerLib extension → "SCA sidecar" → "sidecar" → settled on **HCA** prefix; American English spelling; the lib approach was rejected because threading `VERIFIABLE_FACTORY` through every call was awkward — extend the base contract instead.

This pattern is the template for any protocol contract that needs "is this caller an HCA acting for owner X?" — reverse registrars today, potentially resolvers/registrars later.

## Registration flow (the gas-optimized shape)

Two transactions, commit-reveal:

- **tx1 — deploy + commit** (~158.6k): `StandaloneRegistrationBootstrapper.deployAndCommit()` deploys the HCA proxy via VerifiableFactory and submits the registrar commitment in one direct call (no HCA execution overhead in tx1). Cross-chain variant: this tx is the Across/Permit2 fill that also credits the fresh SCA with bridged USDC — the commit-reveal timer absorbs bridge settlement latency.
- **tx2 — register** (~533k–617k by entry path): through `IntentExecutor`, the HCA executes: exact-amount USDC approve → **bound resolver** deploy with seeded records → `register(...)` → reverse claim via the HCA adapter.

Key decisions baked into this flow:

- **Per-user resolver stays** ("can we keep the per-user resolver proxy deployment but keep all the other bits" — yes). `BoundHCAResolver` is bound to the SCA at deploy; the proxy is a Solady ERC-1967 clone (~61-byte runtime + immutable args) instead of a Solidity proxy — that was the big cliff (~100k+).
- **No privacy leak**: tx1 commits only to the deterministic resolver address; the resolver is deployed *and seeded* in tx2 alongside `register`, where the label is already public in reveal calldata. Seeding at commit time would have leaked the name early.
- **Seeded resolver init requires the HCA caller**; only empty-init resolvers are publicly deployable (otherwise anyone could predeploy a victim's resolver with malicious records).
- **The registrar pulls payment from the caller/SCA**, not the `owner` argument — registration funds must sit on the SCA.
- Post-register record txs (data/contenthash) are excluded from the measured flow by default.

## Measured gas (Sepolia fork, all verified reproducible)

Registration totals, `StandaloneDirectOwnerHCA`, by entry path:

| Entry path | tx1 | tx2 | Total | Notes |
|---|---:|---:|---:|---|
| Direct IntentExecutor Permit2 stub, `arbiter=caller` | 158,644 | 533,289 | **691,933** | Floor; needs arbiter = direct caller, not realistic via relayers |
| Nested Permit2 via standard Rhinestone route | 158,644 | 578,177 | **736,821** | **The realistic relayer-accessible number** |
| EntryPoint/UserOp Permit2 | 158,632 | 616,785 | **775,417** | |
| (old factory-based HCA, same flow) | — | — | 955,568 | superseded baseline |

`StandaloneSingleOwnerHCA` on the same matrix: 730,803 / 780,298 / 823,922 (loses every mode).

Live proof (Sepolia, June 3): registered `hcampzqr6xd.eth` and `hcampzrayho.eth` through the real Rhinestone/Across route — tx1 spawn+commit 334,379 (incl. bridged USDC receipt), tx2 register 331,761; route probe confirmed Rhinestone accepts `settlementLayer: ACROSS`, `fundingMethod: PERMIT2`, `using7579: false`, destination op `IntentExecutor.executeSinglechainOps` with the SCA as recipient.

Micro-costs: HCA proxy deploy/init 126,668; `executeSinglechainOps` no-op 81,380; impl deploy ~3.98M (one-time).

## Open items & risks

- **EIP-8037 (draft)**: this flow creates a lot of fresh state (account proxy, resolver proxy, ~10 storage slots). Modelled impact: nested benchmark ~2.42M–2.65M paid gas; full Rhinestone wrap ~3.3M. If 8037 lands, the per-registration deploy strategy needs rethinking.
- **Permit2 hash schema**: the live Sepolia `IntentExecutor` rejected the local devnet helper's `executePreClaimOpsWithPermit2Stub` digest (`InvalidSignature()`) — the in-checkout helper's Permit2 hash schema doesn't match the deployed executor. Direct Permit2 works only when the witness arbiter is the executor's caller.
- **Graduation**: the standalone account contracts + bootstrapper + bound resolver still live in `hca-permit2-proto/` (prototype quality, some stale absolute imports). They need to move into the main tree where the `feat/verifiable-reverse-adapters` adapters and the existing test infrastructure (`MockHCA` stands in for them today) can exercise the real things.
- **Superseded test surface**: the ~4.9k lines of HCA tests in `contracts-v2-hca-write/` target the factory-recorded design; if this path is final, that suite tests the wrong architecture. (Both `contracts-v2-hca-write` and `contracts-v2-with-migrations` are also orphaned git worktrees — their parent repo moved.)
- **Nexus fork dependency**: the standalone accounts build against `nexus-rhinestone` on `feat/default-executor`; that fork/branch needs a long-term home.

## Where everything lives

| Piece | Location |
|---|---|
| Adapter productionization (current direction) | `contracts-v2-verifiable-reverse-adapters/` — branch `feat/verifiable-reverse-adapters` |
| Standalone account prototypes + bound resolver + bootstrappers | `hca-permit2-proto/` |
| Gas/measurement harnesses | `hca-permit2-proto/measure-*.mjs`, `hca-rhinestone-lab/hca-viem-runner/measure-*.mjs` |
| Live-route runners (Rhinestone/Across e2e) | `hca-rhinestone-lab/hca-viem-runner/run-*.mjs`, `probe-*.mjs` |
| Old factory-based design + its test suite | `contracts-v2-hca-write/`, `hca-rhinestone-lab/rhinestone-ens-modules-hca/` |
| Nexus fork (default executor) | `nexus-rhinestone/` |
| Clean upstream baseline / migration variants / Sepolia artifacts | `contracts-v2/`, `contracts-v2-with-migrations/`, `sepolia-deploy/`, `hca-rhinestone-lab/enschain-deployments/` |
