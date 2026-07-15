# HCA protocol handoff

The HCA is a per-user execution account. The wallet remains the name owner, resolver co-admin, and revocation authority.

Do not deploy this branch.

R1-R3 are the formal release blockers. Other findings remain launch-gate inputs but are not silently relabeled as R1-R3. Evidence gaps are unproven product claims. The target architecture is proposed, not approved.

## Current implementation

- `StandaloneSingleOwnerHCA` runs as a Nexus implementation behind a `VerifiableFactory` proxy in tests.
- It stores one owner, blocks module changes, revokes sessions by nonce, and gates owner-triggered upgrades.
- `RegistrationBootstrapper` deploys and commits using caller-supplied deployment inputs.
- `OwnerBoundRegistrationSessionValidator` supports direct-owner and delegated registration authorization.
- Its policy covers commit, register, renew, payment approval, resolver deployment and writes, and default reverse-name updates.
- The account uses a fixed `IntentExecutor`.
- HCA-focused Forge and E2E tests pass with destination funds supplied directly and a stronger mock executor.

## Formal release blockers

### R1 — Trusted account provenance

Problem: `canUpgradeFrom` accepts every predecessor. A malicious proxy can upgrade into the trusted implementation and appear canonical.

Fix: the first trusted version rejects every predecessor. Later versions allow only explicit compatible predecessors.

### R2 — Counterfactual account capture

Problem: the bootstrapper accepts factory, implementation, salt, initialization, and registrar inputs. An attacker can occupy the expected address with malicious initialization.

Fix: use an owner-bound deployer that pins inputs, derives the salt, verifies existing code, and handles repeat deployment and commitment safely.

### R3 — Signed operations are not bound to checked operations

Problem: the validator checks the executor digest and separately checks envelope `operationData`. It does not prove they describe the same calls and ignores forwarded `sender`.

Fix: rebuild the production digest from checked operations, compare it with the ERC-1271 digest, require the expected executor, and test Rhinestone's versioned typed data.

## Other high-priority findings

1. Resolver deployment does not bind the salt, address, initialization, initial roles, seeded records, or resolver used by `register`.
2. One grant covers registration, renewal, records, default-primary changes, and uncapped token approval. Separate payment authority from ongoing name-management permissions or encode explicit permissions.
3. The owner-role check does not bind root resource, `ROLES.ALL`, `grant == true`, or registration-batch placement.
4. The live runner omits the wallet role grant.
5. The shared executor can run arbitrary HCA batches. Its audit, upgrade, ownership, monitoring, and emergency model is undefined.

## Evidence gaps

Current tests do not prove:

- offline reveal authorization before the user leaves;
- production Permit2 or Across funding;
- first-time allowance or DAI funding;
- production account derivation or a random registrar secret;
- the gas target;
- record sessions or renewal end to end; or
- sponsored revocation, upgrades, refunds, or stranded-fund recovery.

## Proposed target

- One canonical HCA per owner, destination chain, and account version.
- The HCA normally holds no funds.
- The wallet owns the name and receives resolver `ROLES.ALL`.
- The HCA keeps wallet-revocable resolver roles for sponsored follow-up actions.
- Registry operator approval is off by default and used only for recurring registry work.
- Session grants encode explicit permissions; an ongoing resolver session may include default-primary changes.
- Revocation, upgrades, refunds, and recovery have sponsored paths.

## Open decisions

- Canonical address discovery and version coexistence.
- Upgrade-gate ownership, predecessor approval, review, and delay.
- Whether owner immutability is enforced or only governed.
- Default-executor trust and emergency controls.
- Offline reveal authorization or temporary key custody.
- Registration and record-session lifetimes.
- Renewal, leftovers, refunds, and recovery.
- Supported wallets, chains, and tokens.
- Redesign triggers such as EIP-8037.

## Integration boundary

- Later primary naming should use an existing sponsored session, then a sponsored direct-owner HCA action, then a wallet transaction. The validator permits standalone `setNameWithHCA` for the owner when the policy has a resolver.
- A wallet-signature relay exists only when a service submits and sponsors it.
- `setApprovalForAll(HCA, true)` is persistent, registry-wide, and gives registry-token operator authority plus inherited non-root roles.
- Manager should not request registry approval at launch. Explorer should offer explicit enable and revoke actions.
- Registry approval still requires action-specific authorization and sponsorship. The current registration validator does not permit registry calls.
- Use wallet transactions for one-off registry changes and transfers by default.
- The HCA is execution infrastructure, not the user's identity or name owner.
