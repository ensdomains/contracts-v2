# Threat model: contracts-v2 (ENSv2)

Severity and scope follow the ENS bug bounty on Immunefi (https://immunefi.com/bug-bounty/ens/information/). Where
this file and that page disagree, the Immunefi page wins. The scanned branch is `post-audit-2`, the ENSv2 code
after the audit fixes (reports in `contracts/docs/audits/`).

## What this project does and where untrusted input enters
ENSv2 replaces ENS v1's flat registry with a hierarchy of registries on Ethereum mainnet: the root registry, then
TLD registries such as `.eth`, then one registry per name for its subnames. Each registry is an ERC-1155 contract
in which every subname is a single token (`ERC1155Singleton`), with resource-scoped roles (`EnhancedAccessControl`)
deciding who can register, renew, set resolvers, set subregistries, transfer, and upgrade. `.eth` names are
registered through a commit-reveal `ETHRegistrar` paid in ERC-20 tokens priced by `StandardRentPriceOracle`.
Existing v1 names move across through migration controllers, and `UniversalResolverV2` resolves names across both
versions. `contracts/README.md` describes the design in detail; read it before anything else.

Untrusted input arrives as:
- Calls from any account to any external function, including re-entrant calls through ERC-1155 receiver hooks,
  ERC-20 tokens, and user-supplied subregistries and resolvers.
- Arbitrary registry and resolver contracts: any name owner (with the role) can point a name at any contract, and
  resolution will walk into it.
- CCIP-Read (EIP-3668) responses from offchain gateways, and DNS TXT data reached through `DNSTLDResolver`.
- ENS v1 state during migration: v1 `NameWrapper` tokens and fuses, `BaseRegistrar` tokens, and v1 registry and
  resolver records, which `LockedMigrationController`, `UnlockedMigrationController` and `WrapperRegistry` read and
  act on.
- Signatures for reverse records and for HCA operations (the optional per-wallet ENS execution account described in `docs/HCA.md`), including ERC-1271 contract
  signatures and session authorisations.
- DNS-encoded names, labels and multicall payloads as calldata.

## Components that matter most / least
Most important:
- `access-control/EnhancedAccessControl.sol` and `registry/libraries/RegistryRolesLib.sol`: role bitmaps (4-bit
  nybbles, 32 roles plus 32 admin roles), the limit of 15 assignees per role per resource, root-resource inheritance,
  and admin-role rules (only the name owner may hold admin roles; admin roles cannot be granted externally). Any
  way to gain a role, keep one after a transfer or regeneration, or corrupt another account's roles is in scope.
- `registry/`: `PermissionedRegistry`, `UserRegistry`, `WrapperRegistry`, `ERC1155Singleton`. Canonical IDs and token
  ID regeneration (`canonicalId = tokenId ^ uint32(tokenId)`), expiry, reservation, unregistration, and transfer.
  Regeneration exists so that old roles and stale marketplace listings cannot survive a re-registration or role
  change; anything that defeats that is in scope.
- `registrar/`: `ETHRegistrar` (commit-reveal, payment, payment-token handling), `ETHRenewerV1`, `BatchRegistrar`,
  `StandardRentPriceOracle`, `LibHalving`.
- `migration/`: `LockedMigrationController`, `UnlockedMigrationController`, `LockedWrapperReceiver`,
  `AbstractWrapperReceiver`, `Graveyard`, `MigrationHelper`, `LibMigration`. Migrating a name the caller does not
  own, migrating a locked or emancipated v1 name into v2 with weaker guarantees than its burned fuses promised, or
  leaving a name controllable in both v1 and v2.
- `resolver/`: `PermissionedResolver`, `PublicResolverV2`, `ENSV1Resolver`, `ENSV2Resolver`, the mirror resolvers and
  `ResolverProfileRewriterLib`.
- `universalResolver/`: `UniversalResolverV2`, `UniversalResolverV1`, `UpgradableUniversalResolverProxy`,
  `LibResolution`, ENSIP-15 normalisation. Anything that makes a victim name resolve to attacker-chosen data, or
  breaks the v1-to-v2 cutover described in `contracts/docs/universalResolver.md`.
- `reverse-registrar/`: forging or replaying a primary-name claim for an address the attacker does not control,
  including through HCA-aware adapters.
- `hca/`: owner binding in `StandaloneHCAFactory`, validators, operation hashing, permit and registrar/resolver
  policies (see `docs/HCA.md`). An HCA acting outside the authority its owner granted is in scope.
- `dns/`: `DNSTLDResolver`, `DNSAliasResolver`, `DNSTXTResolver`, `DNSTXTParserLib`.
- Upgradeability: UUPS proxies, `ROLE_UPGRADE`, the DAO-approved upgrade set (`PermissionedAddressSet`), initialisers,
  and storage layout across upgrades.

Least important / out of scope:
- `src/testnet/` (testnet fixtures and a premigration registrar for test networks).
- `contracts/lib/` submodules. `ens-contracts` is enrolled separately; report v1 bugs there unless the bug is in how
  ENSv2 uses v1. Do not patch anything under `contracts/lib/` (see `AGENTS.md`).
- `script/`, `deploy/`, `rocketh/`, `plugins/`, `test/`, `alto/`, `mockestrator/`, `docker/` and configuration files.
  Immunefi excludes impacts on test and configuration files.

## How to exercise it
Run everything from `contracts/`. Solc, the submodules and all packages are already in the image.
- Forge tests live next to what they test under `test/unit/<area>/` (`*.t.sol`). Run a slice with
  `forge test --match-path 'test/unit/registry/*' -vvv`. The agent machine has 2 CPUs and fuzz runs default to 4096,
  so target the area you are working on; `FOUNDRY_FUZZ_RUNS=256` speeds up exploration.
- Hardhat integration tests: `bun run test:hardhat` (vitest, `test/integration/**/*.test.ts`), covering the resolvers
  and universal resolvers against deployed v1 and v2 contracts.
- TypeScript unit tests: `bun run test:unit`. End-to-end tests: `bun run test:e2e` (starts local anvil instances).
- Reproducers: a Forge test in the relevant `test/unit/<area>/` directory is preferred. Follow `AGENTS.md`: check
  events with `vm.expectEmit` or `vm.recordLogs`; put `vm.expectRevert` before `vm.prank`; use constants from the
  source libraries (eg, `RegistryRolesLib`) rather than literal values; never compile with `--via-ir`.

## How you rate severity
Use the Immunefi Vulnerability Severity Classification System v2.3 for smart contracts, as the ENS program applies
it. In ENS terms, a name is an NFT, and its owner, roles, subregistry, resolver, records and expiry are what that
NFT represents.

- **Critical**: direct theft of user funds (at rest or in motion), including payment tokens or funds held by an HCA;
  direct theft of a name, or gaining any role on a name, registry or resolver the attacker should not have; privilege
  escalation in `EnhancedAccessControl` (eg, acquiring an admin role, or a role surviving a transfer or token
  regeneration when it should not); unauthorised minting, registration or migration of a name, including
  registering without full payment or a valid commitment; permanent freezing of funds or names (eg, a name that can
  never be renewed, transferred or migrated); unintended alteration of what a name represents, including making a
  victim's name resolve to attacker-chosen data; migration that weakens the guarantees of a locked v1 name;
  forging a reverse (primary name) record; an unauthorised upgrade, or an initialiser or storage-layout bug that lets
  an attacker take over a proxy; protocol insolvency.
- **High**: theft or permanent freezing of unclaimed yield or royalties; temporary freezing of funds or names, rated
  by value and duration.
- **Medium**: contracts unable to operate as intended for some or all users (eg, registration, renewal, migration or
  resolution blocked for a set of names) without loss of funds; griefing that damages users or the protocol without
  profit to the attacker; theft of gas; unbounded gas consumption an attacker can trigger; events that are missing or
  wrong in a way that misleads indexers about ownership or roles (indexers rely on the events documented in
  `docs/indexing-ensv2-events.md`).
- **Low**: a contract fails to deliver promised returns without losing value; spec deviations (ENSIPs, EIP-3668,
  ERC-165, ERC-1155, ERC-1271) with limited practical impact; NatSpec that contradicts the code.
- An issue that needs a third-party system to fail (a CCIP-Read gateway, an L2 bridge or state proof, a payment
  token, Rhinestone or ERC-4337 infrastructure) can be discounted by up to half; say what has to fail.
- Every report needs a runnable proof of concept, as Immunefi requires.

## Trust assumptions and anything to leave alone
- The ENS DAO and its executors are trusted, and so are accounts holding root roles granted at deployment (see the
  deployment permissions table in `contracts/README.md`) and DAO-approved upgrade targets. The Security Council is
  trusted within its documented powers. Reports that need a malicious or compromised DAO, Security Council, ENS Labs
  or its operators, or leaked keys for a privileged address, are out of scope unless the role can do something
  beyond its documented powers (eg, `ROLE_SET_RESOLVER` being enough to transfer a name).
- By design, not bugs (see `contracts/README.md`): roles delegated to other accounts survive a transfer unless
  revoked; parent registries with root roles control their subnames unless the subregistry is locked in and its
  owner holds no root roles; revoking `ROLE_CAN_TRANSFER_ADMIN` makes a name soulbound; token IDs change on
  re-registration and on role changes.
- Out of scope per Immunefi: behaviour of an HCA session key within the authority it was granted (eg, an attacker
  using a stolen session key before it expires).
- Known v1 issues apply to the v1 contracts that ENSv2 migrates from: a malicious DAO can steal names by upgrading
  `NameWrapper` or reduce name expiries, and a `NameWrapper` race condition can set fuses inappropriately. Report
  them only if ENSv2 makes them worse.
- Patches: keep them minimal and in the existing style. Every changed Solidity item needs updated NatSpec, comments
  describe behaviour rather than the change, and docs under `contracts/docs/` must stay accurate. Add a regression
  test beside the existing tests for that area.
