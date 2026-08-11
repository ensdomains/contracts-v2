# Post-Migration Monitoring

Once a network has completed the [phased v1 → v2 migration](./migration.md), the migrated state must
stay correct indefinitely: v1 frozen but renewable, v2 open, resolution served through the Universal
Resolver, and — above all — **no name that a v1 owner still has rights to may ever be claimable by
someone else on v2**. The monitor (`contracts/script/monitor.ts`, run as `bun run monitor`) watches
all of this continuously. It is strictly **read-only**: it never signs or broadcasts a transaction.

## What can go wrong, and how the monitor catches it

The monitoring design maps directly onto the post-migration risks identified during migration
planning:

| Risk | Failure mode | Detection |
| --- | --- | --- |
| **Missed name** (highest impact) | A name active or in grace on v1 was never seeded on v2, so a third party registers it organically and the v1 owner loses it | Every organic v2 registration is cross-checked against the v1 `BaseRegistrar` at event time; a registration inside the v1 expiry + 90-day window fires a **critical** alert, re-read against every configured RPC provider |
| **Renewal outage** (all-or-nothing) | v1 renewals (`ETHRenewerV1`) or v2 renewals (`ETHRegistrar`) revert for everyone at once | Pricing-path probes every tick (oracle + live `getRenewPrice` on labels learned from real renewals), role checks, plus renewal-traffic liveness watermarks that alert when a steady stream goes silent |
| **NameWrapper desync** | `syncWrapper` stops working, so wrapped-name expiries drift between v1 and v2 | `syncWrapper([])` is simulated every tick — the empty call exercises the full add/remove-controller path and proves `ETHRenewerV1` still holds v1 registrar custody (pass/fail, as discussed in planning) |
| **Graveyard daemon desync** | Migrated names keep live v1 registry records because the graveyard daemon stalls | Each migration observed on v2 is tracked until the v1 registry record points at `Graveyard`; sustained lag beyond a threshold alerts (a little desync is expected and tolerated) |
| **v1 freeze breach** | A frozen v1 registration controller is re-enabled, or ownership of the v1 `BaseRegistrar` moves | Controller flags re-read every tick; `ControllerAdded`/`ControllerRemoved`, ownership transfers and non-Graveyard v1 registrations watched from the event stream |
| **Resolution cutover regression** | The Universal Resolver proxy chain is re-pointed or its admin changes | `implementation()`/`admin()` invariants every tick plus `Upgraded`/`AdminChanged`/`AdminRemoved` event watch on both proxies; canary names resolved through the top URP |
| **Authorization drift on v2** | `ETHRegistrar` loses its roles, `BatchRegistrar` gets them back, migration controllers lose `REGISTER_RESERVED`, or any root-resource role changes | `hasRootRoles` invariants every tick plus `EACRolesChanged` (root resource) event watch on `ETHRegistry` and `RootRegistry` |

## Architecture

The monitor runs the same checks in two modes:

- **`check`** — one pass, human or JSON report, exit code `0` (ok) / `1` (warnings) / `2`
  (critical). Suitable for cron, CI, or ad-hoc verification.
- **`watch`** — a daemon: every `--interval` seconds it re-runs the invariants and probes,
  incrementally scans events since the last processed block (with reorg protection via
  `--confirmations`), updates its state file, and pushes alerts.

Four layers of coverage:

1. **Wiring invariants** — cheap multicall reads asserting the end-state of migration phases 3–7
   (see the [check catalogue](#check-catalogue)). These re-verify continuously what
   `phase verify-*` asserted once.
2. **Functional probes** — `eth_call` simulations of the paths users depend on: `syncWrapper([])`,
   renewal pricing on both registrars, resolution of canary names through the top URP, and a
   structural `findExactRegistry("eth")` read proving the URP serves the v2 tree.
3. **Event watch** — incremental `eth_getLogs` over the v2 registries/registrars, the v1
   `BaseRegistrar` and reverse registrars, and both Universal Resolver proxies. This is where the
   missed-name guard, freeze-breach detection, and admin-change detection live.
4. **Deep audits** (`check --deep`) — shells out to the migration CLI's heavyweight verifiers
   (`phase verify-v1-registrars-disabled`, `phase verify-v2-registrar`, `phase verify-urp`, and
   optionally `premigration verify` against a registration CSV). These re-run the full
   controller-history audit that scans v1 events from genesis, so they are scheduled (e.g. daily),
   not per-tick.

State (last processed block, learned probe labels, renewal watermarks, pending graveyard clears,
alert dedup) persists in `<work-dir>/monitor-state.json`, so restarts resume scanning where they
left off and catch up on anything that happened while the daemon was down.

Contract addresses resolve from the deployment artifacts — v2 from
[`deployments/<network>/`](../deployments/README.md), v1 from `deployments/v1/<network>` then
`lib/ens-contracts/deployments/<network>` — exactly like the migration CLI, with explicit flag
overrides available. Nothing is hardcoded, so the same monitor runs against sepolia today and
mainnet as soon as its `deployments/mainnet/` namespace exists.

### Data-source redundancy

Pass multiple `--rpc-url` values (or comma-separate them in `SEPOLIA_RPC_URL` /
`MAINNET_RPC_URL`). The monitor then:

- fails over reads to the next provider when one errors,
- compares head blocks across providers each tick and warns on lag or unreachability,
- re-reads every **missed-name** finding against *all* providers before alerting, so a single
  faulty provider can neither hide nor fabricate the highest-severity finding.

## Check catalogue

Severities: **critical** — user-facing breakage or a security-relevant change, page someone;
**warning** — degradation or something needing review at working speed.

### Continuous invariants (every tick)

| Check id | Asserts | Severity |
| --- | --- | --- |
| `v1-base-registrar-owner` | v1 `BaseRegistrar.owner()` is `ETHRenewerV1` (phase 6 lock-down) | critical |
| `v1-frozen-registration-controllers` | Legacy/current/wrapped v1 controllers and `NameWrapper` stay removed (phase 3 freeze) | critical |
| `v1-handoff-controllers-enabled` | `ETHRenewerV1`, `Graveyard` (+ testnet helper) stay authorized on v1 | critical |
| `v1-reverse-adapters-enabled` | Reverse-registrar adapters stay authorized on the v1 reverse registrars | critical |
| `v1-eth-resolver-v2` | v1 registry `.eth` resolver is `ENSV2Resolver` (phase 1 deferred tx) | warning |
| `v2-eth-registrar-enabled` | `ETHRegistrar` holds `REGISTRAR\|RENEW` on `ETHRegistry` (phase 6) | critical |
| `v2-batch-registrar-disabled` | `BatchRegistrar` holds no registrar roles (phase 6) | critical |
| `v2-eth-renewer-role` | `ETHRenewerV1` holds `RENEW` on `ETHRegistry` | critical |
| `v2-migration-controllers-role` | Both migration controllers hold `REGISTER_RESERVED` | critical |
| `v2-root-eth-wiring` | `RootRegistry.getSubregistry("eth")` is `ETHRegistry` | critical |
| `urp-proxy-chain` | top URP → managed URP (or direct) → `UniversalResolverV2` (phase 7) | critical |
| `urp-top-admin-stable` / `urp-managed-admin-stable` | URP admins unchanged since first observation | critical |
| `renewer-owner-stable` | `ETHRenewerV1.owner()` unchanged (it can move v1 registrar custody) | critical |
| `oracle-wiring` | Both registrars price through the same rent price oracle | warning |
| `rpc-heads-consistent` | All RPC providers reachable and within 10 blocks of each other | warning |

The three `-stable` checks ratchet against the first observed value; after an intentional
governance change, delete the corresponding `firstSeen` entry in `monitor-state.json` to
re-baseline.

### Functional probes (every tick)

| Check id | Exercises | Severity |
| --- | --- | --- |
| `probe-sync-wrapper` | `ETHRenewerV1.syncWrapper([])` simulation — wrapper-sync path + v1 custody | critical |
| `probe-rent-price` | Oracle prices a 1-year renewal for a configured payment token | critical |
| `probe-registrar-renew-price` | Live `ETHRegistrar.getRenewPrice` on a label learned from real v2 renewals | critical |
| `probe-renewer-renew-price` | Live `ETHRenewerV1.getRenewPrice` on a label learned from real v1 renewals | critical |
| `probe-ur-eth-registry` | Top URP `findExactRegistry("eth")` returns the v2 `ETHRegistry` | critical |
| `probe-resolution:<name>` | Each `--names` canary resolves to a non-zero address through the top URP | critical |

### Event watch (incremental)

| Finding id | Trigger | Severity |
| --- | --- | --- |
| `missed-name:<label>` | Organic v2 registration of a name whose v1 registration + 90d grace has not elapsed, and whose v1 token is not held by `Graveyard` | critical |
| `v2-unknown-minter:<label>` / `v2-batch-registrar-active:<label>` | `LabelRegistered` on `ETHRegistry` from a sender other than `ETHRegistrar` or the migration controllers | critical |
| `v2-post-migration-reservation:<label>` | Any `LabelReserved` after migration (seeding is over) | critical |
| `v2-unregistered:<tokenId>` | Admin force-unregistration on `ETHRegistry` | warning |
| `v2-root-role-change:*` / `root-registry-role-change:*` | Root-resource `EACRolesChanged` on `ETHRegistry` / `RootRegistry` | critical |
| `root-registry-activity:*` | Any TLD-level change on `RootRegistry` not from the DNS mirror registrar | critical |
| `v1-freeze-breach:*` | v1 registration minted to anyone but `Graveyard` | critical |
| `v1-controller-change:<tx>` | v1 controller churn that is not a same-transaction `NameWrapper` add/remove pair (i.e. not `syncWrapper`) | critical |
| `v1-ownership-transferred:*` | v1 `BaseRegistrar` `OwnershipTransferred` | critical |
| `reverse-adapter-disabled:*` / `reverse-controller-change:*` | v1 reverse registrar controller changes | critical / warning |
| `urp-upgraded:*` / `urp-adminchanged:*` / `urp-adminremoved:*` | Any Universal Resolver proxy change | critical |
| `oracle-updated:*` | `RentPriceOracleUpdated` on either registrar | warning |
| `renewal-liveness-v2` / `renewal-liveness-v1` | No renewal observed for `--renewal-stale-hours` (renewal failures are all-or-nothing, so silence is a signal; default 6h mainnet, off on sepolia) | warning |
| `graveyard-clear-lag` | Migrated names whose v1 registry record outlives `--graveyard-lag-hours` (default 24h) | warning |

Registrations are classified by the `LabelRegistered` `sender`: `ETHRegistrar` → organic (runs the
missed-name guard), migration controllers → migration (tracked for graveyard lag), anything else →
alert. Expiry produces **no events** in v2, so availability transitions are computed from
timestamps, never awaited from logs.

### Deep audits (`check --deep`, scheduled)

| Check id | Delegates to | Notes |
| --- | --- | --- |
| `deep-v1-registrars-disabled` | `migration phase verify-v1-registrars-disabled` | Full controller-history audit from chain genesis; catches anything the incremental watch missed |
| `deep-v2-registrar` | `migration phase verify-v2-registrar` | |
| `deep-urp` | `migration phase verify-urp` | |
| `deep-premigration-verify` | `migration premigration verify --csv-file <path>` | Only with `--csv-file`; re-verifies every eligible v1 name is reserved/registered on v2 — the batch complement to the per-event missed-name guard. Export a fresh CSV via `migration fetch-data` first |

## Operations

### Quick start

```bash
cd contracts
export SEPOLIA_RPC_URL=<url>[,<second-provider-url>]

# One-shot verification (cron-able; exit 0/1/2)
bun run monitor -- check --network sepolia

# Continuous daemon with health endpoint and alerts
bun run monitor -- watch --network sepolia --interval 60 --port 8787 \
  --webhook-url https://hooks.example/ens-monitor \
  --heartbeat-url https://hc-ping.com/<uuid>
```

First run initializes event scanning at the current head; pass `--from-block <n>` (e.g. the
migration cutover block) once to backfill history. On mainnet add `--names nick.eth,vitalik.eth`
(the default) or your own canary list, and run at least two independent RPC providers.

### Alerting

- Every failing check logs to stderr and, if configured, POSTs JSON
  (`{source, network, severity, id, summary, details, timestamp}`) to `--webhook-url` /
  `MONITOR_WEBHOOK_URL` — point it at a Slack/PagerDuty/Discord bridge.
- Alerts deduplicate per check id: they fire on the ok→fail transition, re-fire every
  `--alert-cooldown-hours` (default 6) while still failing, and emit a recovery notice on
  fail→ok.
- `--heartbeat-url` / `MONITOR_HEARTBEAT_URL` is fetched after every tick with **zero critical
  findings** — wire it to a dead man's switch (healthchecks.io or similar) so the monitor dying,
  or being unable to give the all-clear, is itself an alert.
- `watch --port <p>` serves `GET /health` (200/503, for container orchestration) and
  `GET /status` (JSON summary including currently-failing check ids).

### Suggested deployment

- **During and right after cutover:** `watch --interval 30` with webhook + heartbeat + two or
  three providers, plus `check --deep --csv-file <fresh-export>` once the final pre-migration CSV
  is at hand.
- **Steady state:** `watch --interval 60` under systemd/Docker (restart-on-exit; state file on a
  persistent volume), plus a daily cron `check --deep` and a weekly
  `check --deep --csv-file <fresh fetch-data export>`.
- The monitor holds no keys and needs no funded account. If an on-chain canary transaction is ever
  wanted (a real paid renewal), run it manually via the migration CLI rather than giving the
  monitor a signer.

### Responding to alerts

Wiring/authorization alerts correspond one-to-one to migration phases — the remediation reference
is the matching phase in [migration.md](./migration.md) (e.g. a `v2-eth-registrar-enabled` failure
is re-established by the phase 6 `enable-v2-registrar` step; URP findings map to phase 7). A
`missed-name` alert is the reputational/financial-liability scenario: confirm against a second
data source (the alert already includes per-provider reads), then escalate immediately — the
resolution is a team decision (compensation/recovery), not a monitor action.

## What this deliberately is not

- **Not an indexer.** It keeps only enough state to detect regressions; see
  [`docs/indexing-ensv2-events.md`](../../docs/indexing-ensv2-events.md) for building a full
  index (note that document's event names have drifted; the monitor's ABIs mirror
  [`IRegistryEvents.sol`](../src/registry/interfaces/IRegistryEvents.sol)).
- **Not a signer.** All checks are `eth_call`/`eth_getLogs`; nothing is broadcast, so a
  compromised monitor host cannot touch the contracts.
- **Not the graveyard daemon.** It measures that daemon's lag but never calls `Graveyard.clear()`
  itself.
