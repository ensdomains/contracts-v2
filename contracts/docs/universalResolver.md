# Universal Resolver Deployment Structure

## Overview

During the v1 → v2 migration, universal resolution runs through a chain of two upgradable proxies in front of the implementation:

```
ENS clients
  └─ UpgradableUniversalResolverProxy          "top URP"
     │   admin: DAO on mainnet, top URP owner on sepolia (`owner` account)
     └─ ManagedUniversalResolverProxy          "managed URP"
        │   admin: security council (`urManager` account)
        └─ UniversalResolverV2                 implementation
```

- **Top URP** — the long-lived address clients resolve through: `0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe` on mainnet, sepolia, and holesky (`DEPLOYED_UNIVERSAL_RESOLVER_PROXY` in [`script/deploy-constants.ts`](../script/deploy-constants.ts)). On other networks it is create3-deployed with a fixed salt (`TOP_URP_CREATE3_SALT`) so the address is reproducible. Its admin is the slow-moving owner: the DAO on mainnet, the top URP owner account on sepolia.
- **Managed URP** — a second instance of the same proxy contract, admin'd by the security council. It exists so that implementation upgrades during the migration require only a council transaction instead of a top-URP-owner transaction per upgrade.
- **UniversalResolverV2** — the stateless implementation ([`src/universalResolver/UniversalResolverV2.sol`](../src/universalResolver/UniversalResolverV2.sol)).

The top URP owner signs once to insert the managed hop; the council then performs the v1 → v2 cutover (and any subsequent implementation changes) on its own. After the migration stabilizes, the top URP owner can point the top URP directly at the final implementation, retiring the managed hop.

## Lifecycle

1. **Deploy/adopt top URP** pointing at the v1 `UniversalResolver`.
2. **Deploy managed URP**, also pointing at the v1 `UniversalResolver`.
3. **Switch top URP → managed URP** (one top-URP-owner transaction). Resolution behavior is unchanged: both still resolve via v1.
4. **Deploy the `UniversalResolverV2` implementation.**
5. **Upgrade managed URP → `UniversalResolverV2`** (council transaction). This is the v2 resolution cutover.
6. **Post-cutover:** point the top URP directly at the implementation, removing the managed hop.

## Deploy scripts

The phases map to [`deploy/universalResolver/`](../deploy/universalResolver/):

| Script | Action | Signer | Migration tag |
| --- | --- | --- | --- |
| `00_deploy_UniversalResolver.ts` | Deploy top URP (create3), or adopt the known `0xeEeE…EeEe` deployment on mainnet/sepolia/holesky | `deployer` | `migration:phase1:deploy-v2` |
| `01_setup_UniversalResolverToV1.ts` | Point top URP → v1 `UniversalResolver` | `owner` † | `migration:phase1:deploy-v2` |
| `02_deploy_ManagedUniversalResolverProxy.ts` | Deploy managed URP → v1 `UniversalResolver` | `deployer` | `migration:phase1:deploy-v2` |
| `03_setup_UniversalResolverToManaged.ts` | Point top URP → managed URP | `owner` † | `migration:phase5:switch-urp-to-managed` |
| `04_deploy_UniversalResolverImplementation.ts` | Deploy `UniversalResolverV2` | `deployer` | `migration:phase1:deploy-v2` |
| `05_setup_ManagedUniversalResolverProxyToUniversalResolverImplementation.ts` | Upgrade managed URP → `UniversalResolverV2` | `urManager` † | `migration:phase6:upgrade-managed-urp` |
| `06_setup_UniversalResolverToUniversalResolverImplementation.ts` | Point top URP → `UniversalResolverV2` directly | `owner` † | `migration:post-cutover:direct-urp-to-v2` |

† On networks where the proxy admin is external (`hasDao` → DAO, `sepolia` → top URP owner), the setup scripts do not execute the upgrade. They print the target address and `upgradeTo` calldata for the admin to execute out-of-band (see `logUpgradeCalldata` in [`script/universalResolverDeployUtils.ts`](../script/universalResolverDeployUtils.ts)).

Setup scripts are idempotent — they read the proxy's current `implementation()` and skip when it already matches.

**Local environments:** every script except `04` skips when the environment has the `local` tag. Local devnets and tests deploy only the bare `UniversalResolverV2` and resolve against it directly, with no proxies.

## Accounts

Named accounts in [`rocketh/config.ts`](../rocketh/config.ts):

| Account | Role | Value |
| --- | --- | --- |
| `owner` | Top URP admin | DAO on mainnet; deployer elsewhere |
| `securityCouncil` | Managed URP admin | Defaults to `deployer` until a council multisig is configured per network |
| `urManager` | Account used by deploy scripts for managed-URP operations | Resolves to `securityCouncil` |

## CLI

The owner-signed steps (3, 5, 6) and verification are also exposed as `script/migration.ts` phase commands, for use against live networks and fork rehearsals:

```bash
# Step 3: top URP → managed URP (top URP owner signature)
bun run migration -- phase switch-urp-to-managed --network sepolia --rpc-url <url> \
  [--calldata-only] [--private-key <key>] [--impersonate-account <address>]

# Step 5: managed URP → UniversalResolverV2 (council signature)
bun run migration -- phase upgrade-managed-urp --network sepolia --rpc-url <url> \
  [--calldata-only] [--private-key <key>] [--impersonate-account <address>]

# Verify both proxies' current implementations
bun run migration -- phase verify-urp --network sepolia --rpc-url <url> \
  [--expected-top-implementation <address>] [--expected-managed-implementation <address>]
```

- Signing keys come from `--private-key` or environment variables: `SEPOLIA_TOP_URP_OWNER_KEY` / `TOP_URP_OWNER_KEY` for the top URP owner, `UR_MANAGER_KEY` / `DEPLOYER_KEY` for the managed URP admin.
- `--calldata-only` prints the transaction target and calldata instead of sending (for multisig execution); `--impersonate-account` sends as the admin on a fork.
- Proxy addresses default to the canonical top URP and the `ManagedUniversalResolverProxy` deployment under `--deployments-dir` / `--deployment-network`; override with `--top-urp` / `--managed-urp` / `--implementation`.
