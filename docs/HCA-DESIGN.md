# HCA design

## Purpose

The HCA exists to let someone register an ENS name with stablecoins without
needing gas on the registration chain.

The user's wallet remains the owner of the name and its long-term authority.
The Hidden Contract Account (HCA) is a transaction rail: it receives the funds
needed for registration and executes the approved calls. It should remain an
implementation detail in the product.

## Who owns what

| Part | Responsibility |
|---|---|
| User wallet | Own the name and approve the funding and registration action. |
| Frontend | Collect the registration choices, request signatures through shared packages, and show progress and recovery states. |
| Smart-account and transaction-manager packages | Present a stable account and transaction interface to the frontend. |
| Rhinestone SDK and orchestrator | Derive and deploy the supported account, build and route intents, and arrange funding and relay. |
| ENS HCA contracts | Enforce account ownership, accepted signatures, and the calls a registration authorization may execute. |
| ENS protocol contracts | Define registration, resolver, and reverse-record behavior. |
| Mockestrator | Simulate the orchestrator transport in local development. It is not a security or production-parity test. |

This split is intentional. Frontend feature code should not encode HCA calls,
reproduce typed data, derive account addresses, or call mockestrator directly.

## Intended registration flow

This is the target flow, not a claim about the current integration:

1. The frontend initializes the supported HCA through the shared account
   provider.
2. The wallet authorizes funding and the registration action.
3. The route funds the HCA and submits the registrar commitment.
4. After the commitment delay, a relayer submits the approved registration
   batch.
5. Registration finishes with the user's wallet owning the name and retaining
   administrative control of its resolver.

The exact number of signatures, source-chain funding path, and handling of the
commitment delay are still product and protocol decisions.

## Required properties

- The user's wallet, not the HCA or relayer, owns the registered name.
- An account address cannot be captured with attacker-chosen initialization.
- The signature checked by the HCA must authorize the same chain, executor, and
  calls that are executed.
- A registration grant must be short-lived, narrowly scoped, and revocable.
- The HCA should not retain unnecessary funds or permanent control after
  registration. Refund and recovery paths must exist for exceptions.
- Resolver and reverse-name setup must not leave the user dependent on the HCA.
- Mock routing must never be treated as evidence that these properties hold in
  production.

## What this branch contains

The branch has a standalone, single-owner Nexus account implementation intended
to run behind a `VerifiableFactory` proxy; local tests deploy it that way. It
prevents later module changes, supports revoking outstanding session grants
with a nonce, and gates upgrades by owner approval plus an implementation
allowlist.

It also has:

- a validator for direct owner signatures and delegated registration sessions;
- a hardcoded policy for selected registration, renewal, token approval,
  resolver, and reverse-name calls;
- a generic helper that deploys an account and submits a commitment; and
- local tests for direct signatures, delegated sessions, and a Permit2-shaped
  authorization.

The local devnet deploys these contracts and exposes their addresses at
`http://127.0.0.1:8000/deployments`. Its Compose stack also runs the upstream
mockestrator against the devnet RPC.

## What is not working end to end

The ENS manager does not currently use this standalone account.

- `@rhinestone/sdk` v1.7.0 creates the older `HCAFactory` account for
  `account: { type: "hca" }`.
- The manager is configured around a Sepolia chain and Sepolia ENS contract
  addresses, while this devnet is chain 31337 with local addresses.
- The current registration machine implements the legacy deploy, commit,
  approval, and registration sequence. It does not yet construct the standalone
  account's funding and delayed-reveal authorization lifecycle.
- The current tests do not demonstrate the production Rhinestone/Across funding
  and execution route.
- The protocol release blockers in `HCA-HANDOFF-PROTOCOL.md` remain open.

Running mockestrator changes none of those facts. It gives the frontend a local
transport only after the SDK account adapter and manager chain configuration
support the standalone HCA.

## Decisions still required

Before production integration, the responsible teams need to settle:

- the canonical account address, versioning, and discovery rule;
- the safe deployer and initialization shape;
- the production signature and operation-binding format;
- how a gasless wallet grants the first token allowance;
- who holds any short-lived reveal authority across the commitment delay;
- refunds, leftover funds, recovery, and sponsored revocation;
- whether the HCA has any role after registration; and
- upgrade-gate and shared-executor ownership and emergency procedures.

These decisions belong to protocol and Rhinestone integration work, not to the
frontend feature implementation.

## Evidence required before frontend sign-off

1. Contract tests cover account provenance, address capture, exact operation
   binding, and least-privilege resolver ownership.
2. Parity tests use Rhinestone's versioned typed-data builders rather than a
   second ENS copy of the same schema.
3. A real route demonstrates first-time funding, commit, delayed reveal,
   registration, refunds or leftovers, and failure recovery.
4. Frontend end-to-end tests use the shared account and transaction interfaces
   and finish with the wallet owning and administering the name.

## Team handoffs

- [`HCA-HANDOFF-FRONTEND.md`](./HCA-HANDOFF-FRONTEND.md) explains what the app
  can use now and what must land first.
- [`HCA-HANDOFF-PROTOCOL.md`](./HCA-HANDOFF-PROTOCOL.md) lists contract and
  security work.
- [`HCA-HANDOFF-RHINESTONE.md`](./HCA-HANDOFF-RHINESTONE.md) lists SDK and
  orchestrator dependencies.
