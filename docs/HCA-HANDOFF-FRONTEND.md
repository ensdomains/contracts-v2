# HCA frontend handoff

## Product outcome

A user with stablecoins but no gas on the registration chain should be able to
register a name. Their wallet owns the name. The Hidden Contract Account (HCA)
only funds and executes the registration behind the scenes.

## Frontend boundary

Frontend owns:

- collecting the name, duration, records, and payment choice;
- asking the shared account and transaction packages to prepare the action;
- presenting wallet-signature, funding, commitment-wait, reveal, completion,
  and recovery states; and
- verifying that the wallet owns the name and can administer its resolver.

Frontend does not own account derivation, deployment calldata, typed-data
schemas, session policy, or direct mockestrator requests. Those belong below the
UI in the SDK, shared packages, and protocol contracts.

## What can run today

The apps monorepo already runs mockestrator in its own E2E stack. That setup
tests the manager's existing Rhinestone integration, which uses the legacy SDK
HCA on a Sepolia-shaped local chain.

This contracts repository now has an equivalent thin transport setup for its
chain-31337 devnet:

```sh
docker compose --profile default up -d --build mockestrator
```

Targeting `mockestrator` also starts its `devnet` dependency.

| URL | Provides |
|---|---|
| `http://127.0.0.1:8545` | Devnet JSON-RPC |
| `http://127.0.0.1:8000/deployments` | Current local contract addresses |
| `http://127.0.0.1:3007` | Upstream mockestrator |

Mockestrator simulates route and fill transport. It may use Anvil shortcuts and
does not prove that HCA authorization or production routing is correct.

## Why the manager cannot use this HCA yet

There is no supported environment-variable-only setup for the standalone HCA:

1. `@rhinestone/sdk` v1.7.0 maps `account: { type: "hca" }` to the legacy
   `HCAFactory` account, not this branch's standalone account.
2. The manager supplies `customSepolia` to the account provider and imports a
   Sepolia ENS contract map. The contracts devnet uses chain 31337 and different
   addresses.
3. The registration machine follows the legacy sequence: deploy a resolver,
   ensure the old HCA exists, commit, wait, then approve and register. Its
   request builder does not pass the funding `tokenRequests` already supported
   by the Warp transport.
4. Pointing the manager at port 3007 changes the orchestrator endpoint only. It
   does not change account derivation, deployment, signatures, or ENS contract
   addresses.

UI code should not work around these blockers by encoding standalone-HCA calls
itself.

## How frontend will use mockestrator

Before this setup can exercise the standalone HCA, three shared-layer changes
must land:

1. Rhinestone exposes a versioned standalone-HCA account adapter.
2. The manager accepts an injected chain and ENS contract map.
3. The transaction manager gets a standalone registration path that supplies
   the funding request, prepares deploy-and-commit, creates the required owner
   authorization, preserves it across the commitment delay, and submits the
   reveal batch.

Once those exist:

1. Start the contracts stack with the command above.
2. Configure the manager's local environment:

   ```env
   VITE_RHINESTONE_ENDPOINT_URL=/orchestrator
   VITE_RHINESTONE_CUSTOM_RPC_URLS={"31337":"http://127.0.0.1:8545"}
   ```

3. Configure the manager to use chain 31337 and provide the addresses returned
   by `GET http://127.0.0.1:8000/deployments` to the shared transaction layer.
4. Initialize the account through `@ens-apps/smart-account` and submit the
   registration through `@ens-apps/transaction-manager`.

The manager's Vite config already proxies `/orchestrator` to port 3007. A local
endpoint also makes the existing account setup use its local-development API
key placeholder. Feature code should still call the SDK-facing interfaces, not
port 3007 directly.

## Work by team

- **Rhinestone:** versioned standalone-HCA SDK adapter and production
  typed-data parity.
- **Frontend platform and shared transaction layer:** injectable chain and ENS
  addresses plus the funding, deploy-and-commit, authorization, and delayed
  reveal lifecycle described above.
- **Protocol:** safe deployment, exact authorization binding, funding model,
  and release blockers.
- **Frontend feature team:** registration UX and state-machine wiring after
  those interfaces are available.

Frontend integration is complete only when an E2E test uses those shared
interfaces and finishes with the user's wallet owning the name and holding the
intended resolver authority.
