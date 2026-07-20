# HCA protocol handoff

The HCA is a per-user execution account. The wallet remains the name owner, resolver co-admin, and revocation authority.

A Sepolia integration deployment is not release approval.

The same-chain path on Sepolia and the user-paid Arbitrum Sepolia-to-Sepolia path are proven. The remaining findings are launch-gate inputs.

## Current implementation

- `StandaloneSingleOwnerHCA` runs as a Nexus implementation behind a `VerifiableFactory` proxy.
- It stores one owner, exposes owner-only atomic batch execution, blocks module changes, revokes sessions by nonce, and requires separate DAO approvals for an upgrade target and its predecessor.
- `StandaloneHCADeployer` fixes the `VerifiableFactory`, constructs the owner initializer, and derives the salt from user salt, owner, and initial implementation.
- `OwnerBoundRegistrationSessionValidator` accepts existing owner signatures, owner-signed ERC-4337 UserOperations, and a standalone fixed-session envelope around the existing session-key signature.
- Its policy covers commit, register, renew, payment approval, resolver deployment and writes, and default reverse-name updates.
- Rhinestone sponsorship uses the fixed executor. ERC-4337 uses EntryPoint and an optional paymaster. Wallet-paid HCA execution uses `executeByOwner`.
- The local executor reproduces the production `SingleChainOps` digest and ERC-1271 route.
- Forge covers fresh HCA deployment and execution in one paymaster-sponsored UserOperation. Live tests cover same-chain EIP-2612 funding and cross-chain EIP-2612 plus Permit2 funding, USDC-paid session commit and reveal, existing-HCA reuse, ownership, retained resolver roles, and default primary name.

## High-priority findings

1. Resolver deployment does not bind the salt, address, initialization, initial roles, seeded records, or resolver used by `register`.
2. One fixed session covers registration, renewal, records, default-primary changes, and uncapped token approval. Separate payment authority from ongoing name-management permissions or narrow the fixed policy.
3. The owner-role check does not bind root resource, `ROLES.ALL`, `grant == true`, or registration-batch placement.
4. The shared executor can run arbitrary HCA batches. Its audit, upgrade, ownership, monitoring, and emergency model is undefined.

## Evidence gaps

Current tests do not prove:

- a production bundler and paymaster;
- DAI funding;
- the gas target;
- record sessions or renewal end to end; or
- sponsored revocation, upgrades, or stranded-fund recovery.

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
- Paymaster-sponsored batches use one owner signature. Fresh HCA deployment can be part of that UserOperation.
- Revocation, upgrades, refunds, and recovery have sponsored paths.

### Registry constraints

- `setApprovalForAll(HCA, true)` is persistent, registry-wide, and gives registry-token operator authority plus inherited non-root roles.
- Sponsored registry actions still require a suitable policy; the current session validator does not permit registry calls. The owner may use wallet-paid HCA execution without a session.

## Open decisions

- User-salt/version policy, address discovery, and version coexistence.
- Upgrade approval review and delay.
- Whether owner immutability is enforced or only governed.
- Default-executor trust and emergency controls.
- Session-key custody across the commitment delay.
- Registration and record-session lifetimes.
- Renewal, leftovers, refunds, and recovery.
- Supported wallets, chains, and tokens.
- Redesign triggers such as EIP-8037.
