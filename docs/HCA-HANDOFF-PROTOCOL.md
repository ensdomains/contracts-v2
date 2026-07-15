# HCA protocol handoff

The HCA is a per-user execution account. The wallet remains the name owner, resolver co-admin, and revocation authority.

Do not deploy this branch.

R1 remains a release blocker. R2 is closed. R3 is fixed in the local implementation but still needs a production-shaped integration test. Other findings remain launch-gate inputs.

## Current implementation

- `StandaloneSingleOwnerHCA` runs as a Nexus implementation behind a `VerifiableFactory` proxy in tests.
- It stores one owner, exposes owner-only atomic batch execution, blocks module changes, revokes sessions by nonce, and gates owner-triggered upgrades.
- `StandaloneHCADeployer` fixes the `VerifiableFactory`, constructs the owner initializer, and derives the salt from user salt, owner, and initial implementation.
- `OwnerBoundRegistrationSessionValidator` accepts Rhinestone's existing owner and session-use signatures.
- Its policy covers commit, register, renew, payment approval, resolver deployment and writes, and default reverse-name updates.
- Sponsored execution uses a fixed `IntentExecutor`; wallet-paid execution calls the HCA directly.
- HCA-focused Forge and E2E tests pass with destination funds supplied directly and a test executor that supplies the exact operation to the validator.

## Release findings

### R1 — Trusted account provenance — blocker

Problem: `canUpgradeFrom` accepts every predecessor. A malicious proxy can upgrade into the trusted implementation and appear canonical.

Fix: the first trusted version rejects every predecessor. Later versions allow only explicit compatible predecessors.

### R2 — Counterfactual account capture — closed

`StandaloneHCADeployer` removes caller-supplied initialization. Its salt binds `userSalt`, owner, and initial implementation, so another implementation gets another address. Any caller may deploy first, but only with the expected owner and initial implementation at the expected address.

Unit and E2E tests cover address derivation, arbitrary relayers, owner separation, and implementation substitution. The SDK must reproduce the formula and verify existing code, owner, and the current implementation under the version and provenance policy before reuse.

### R3 — Checked-operation binding — integration gate

Session validation receives the operation from the fixed executor, checks that operation, and rejects other callers.

Release still requires an orchestrator-produced operation to prove the SDK, executor, and validator agree on the mode and encoding.

This affects sponsored intent execution. `executeByOwner` authenticates `msg.sender` and does not accept an intent signature.

## Other high-priority findings

1. Resolver deployment does not bind the salt, address, initialization, initial roles, seeded records, or resolver used by `register`.
2. One fixed session covers registration, renewal, records, default-primary changes, and uncapped token approval. Separate payment authority from ongoing name-management permissions or narrow the fixed policy.
3. The owner-role check does not bind root resource, `ROLES.ALL`, `grant == true`, or registration-batch placement.
4. The shared executor can run arbitrary HCA batches. Its audit, upgrade, ownership, monitoring, and emergency model is undefined.

## Evidence gaps

Current tests do not prove:

- a production reveal without the user returning;
- production Permit2 or Across funding;
- first-time allowance or DAI funding;
- SDK parity for account derivation or a random registrar secret;
- the gas target;
- record sessions or renewal end to end; or
- sponsored revocation, upgrades, refunds, or stranded-fund recovery.

## Target behavior

### Account and permissions

- One canonical HCA per owner, destination chain, and account version.
- The HCA normally holds no funds.
- The wallet owns the name and receives resolver `ROLES.ALL`.
- The HCA keeps wallet-revocable resolver roles for follow-up actions.
- Registry operator approval is off by default and used only for recurring registry work.
- Fixed sessions are time-limited and revocable. Registration sessions bind a resolver; sessions without one cannot edit resolver records or the default primary name.
- The validator permits standalone `setNameWithHCA` only for the HCA owner when the policy includes a resolver.
- Wallet-paid batches use `executeByOwner` and need one transaction confirmation, not an intent signature plus a transaction.
- Revocation, upgrades, refunds, and recovery have sponsored paths.

### Registry constraints

- `setApprovalForAll(HCA, true)` is persistent, registry-wide, and gives registry-token operator authority plus inherited non-root roles.
- Sponsored registry actions still require a suitable policy; the current session validator does not permit registry calls. The owner may use wallet-paid HCA execution without a session.

## Open decisions

- User-salt/version policy, address discovery, and version coexistence.
- Upgrade-gate ownership, predecessor approval, review, and delay.
- Whether owner immutability is enforced or only governed.
- Default-executor trust and emergency controls.
- Offline reveal authorization or temporary key custody.
- Registration and record-session lifetimes.
- Renewal, leftovers, refunds, and recovery.
- Supported wallets, chains, and tokens.
- Redesign triggers such as EIP-8037.
