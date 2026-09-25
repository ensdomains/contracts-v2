# ENS Pre-Migration Script

The pre-migration script (`contracts/script/preMigration.ts`) seeds ENS v1 `.eth` second-level (2LD)
registrations into the v2 registry. It reads a CSV export of v1 registrations, verifies each name
on-chain against the v1 `BaseRegistrar`, and reserves or renews it on v2 via the `BatchRegistrar`
contract. Names are written in a **reserved** state (owner `address(0)`) with the v1 expiry preserved
(plus a configurable bonus period) and `ENSV1Resolver` set as the fallback resolver; ownership
transfer happens in a later migration phase. A name whose v1 registrant is a `Graveyard` is never
reserved — see [Graveyard-held names](#graveyard-held-names).

## Quick start

Run from `contracts/` after `forge build`. Dry-run first (full pipeline, sends nothing), then execute;
resume with `--continue` after any interruption:

```bash
export PREMIGRATION_PRIVATE_KEY=0x...   # BatchRegistrar owner key

# 1. Dry run — parses, verifies, computes expiries, checkpoints; sends no transactions
bun run script/preMigration.ts \
  --rpc-url <url> --registry <addr> --batch-registrar <addr> \
  --v1-resolver <addr> --graveyards <addr,addr,...> \
  --csv-file ./data/v1-registrations.csv --dry-run

# 2. Execute (drop --dry-run)
bun run script/preMigration.ts \
  --rpc-url <url> --registry <addr> --batch-registrar <addr> \
  --v1-resolver <addr> --graveyards <addr,addr,...> \
  --csv-file ./data/v1-registrations.csv

# 3. Resume from the last checkpoint after an interruption (same options as before)
bun run script/preMigration.ts --continue \
  --rpc-url <url> --registry <addr> --batch-registrar <addr> \
  --v1-resolver <addr> --graveyards <addr,addr,...> \
  --csv-file ./data/v1-registrations.csv
```

In the phased migration this script is driven through the operator CLI
(`bun run migration -- premigration run` / `resume`, then `verify`) — see
[migration.md](./migration.md). The CLI fills in `--graveyards` from the deployment artifacts. The
reference below documents the underlying script directly.

## Prerequisites

- **Bun** runtime, and forge artifacts compiled (`forge build` in `contracts/`).
- **Deployed contracts:** the v2 `PermissionedRegistry`, `BatchRegistrar` (owned by the signer), and
  `ENSV1Resolver`.
- **Signer key** for the `BatchRegistrar` owner — `--private-key` or the `PREMIGRATION_PRIVATE_KEY`
  env var.
- **RPC endpoint** where both v1 and v2 contracts live (chain ID auto-detected). Optionally a separate
  `--mainnet-rpc-url` for v1 reads (e.g. when v2 runs on a devnet with its own v1 set).
- **CSV file** of v1 registrations (see [CSV input](#csv-input)).

## CLI Reference

Run from `contracts/`:

```bash
bun run script/preMigration.ts [options]
```

> In the phased flow these options map onto the operator-CLI subcommands `premigration run` /
> `resume` / `verify`, which additionally accept the shared
> [common options](./migration.md#common-options) (`--network`, deployment dirs). `premigration
> status` is a separate, local checkpoint read that takes **only** `--work-dir` — it does not touch an
> RPC. Run `bun run migration -- premigration <sub> --help` for the authoritative per-subcommand list.

### Required

| Option | Description |
|---|---|
| `--rpc-url <url>` | RPC endpoint (where v1 + v2 live) |
| `--registry <address>` | v2 `PermissionedRegistry` address |
| `--batch-registrar <address>` | `BatchRegistrar` address |
| `--csv-file <path>` | CSV of v1 registrations |
| `--v1-resolver <address>` | `ENSV1Resolver` address (set as fallback resolver) |
| `--graveyards <addresses>` | Comma-separated addresses of every `Graveyard` on the chain, superseded deployments' included. A name any of them holds on v1 is not reserved. |

### Optional

| Option | Default | Description |
|---|---|---|
| `--private-key <key>` | `PREMIGRATION_PRIVATE_KEY` | `BatchRegistrar` owner key. Exits if neither is set. |
| `--account <address>` | — | Impersonated/unlocked `BatchRegistrar` owner (forks/devnets). |
| `--mainnet-rpc-url <url>` | `https://eth.drpc.org` | RPC for v1 `BaseRegistrar` expiry reads; point at a devnet when v2 runs locally. |
| `--batch-size <number>` | `50` | Names per on-chain batch. |
| `--start-index <number>` | `-1` | CSV line to start from (set automatically by `--continue`). |
| `--limit <number>` | none | Max names to process. |
| `--dry-run` | `false` | Simulate without sending transactions. |
| `--continue` | `false` | Resume from the last checkpoint. |
| `--bonus-period-days <days>` | `62` | Days added to each name's v1 expiry to compute its v2 expiry. `0` preserves v1 expiries exactly. |
| `--max-gas-price <gwei>` | `0.146` on mainnet, none elsewhere | Wait to send while the gas price is above this many gwei. See [Gas price limit](#gas-price-limit). |
| `--v1-base-registrar <address>` | mainnet `BaseRegistrar` | v1 `BaseRegistrar` for expiry lookups (override for testing). |

> Eligibility is independently gated by v1's hard-coded 90-day grace: a name expired more than 90 days
> ago is past grace and skipped, regardless of `--bonus-period-days`. A name whose v1 registrant is a
> `Graveyard` is skipped whatever its expiry.
>
> A name deep in its v1 grace can compute a v2 expiry that has already passed. The registry accepts it,
> and the entry reads `Available` at once, but it is still the v1 owner's: v2 keeps a lapsed
> reservation in a 28-day grace period of its own, during which `ETHRenewerV1` renews it and
> `ETHRegistrar` refuses to register it to anyone else. The default bonus of 62 days is the v1 grace
> less the v2 grace, so that window closes exactly when v1's does. A shorter bonus leaves the names in
> the gap open to anyone on v2 while v1 still holds them, and `premigration reconcile` reports them as
> missing.

## CSV input

Parsing is **header-driven**: the first line is the header, the label column is located by name,
everything else is ignored. Two column names are accepted (case-insensitive, trimmed): **`labelName`**
(v1 subgraph schema, preferred) or **`label`** (the `exportTheGraphRegistrations.ts` exporter). Both
work with no flag:

```csv
node,name,labelHash,owner,parentName,parentLabelHash,labelName,registrationDate,expiryDate
,,,,,,vitalik,,
```

```csv
name,label,labelhash,registrant,expiryDate,registrationDate
vitalik.eth,vitalik,0x...,0x...,...,...
```

Quoted fields and `""`-escaped quotes are handled; a UTF-8 BOM, a single trailing blank line, and CRLF
endings are tolerated.

**Strict structural parsing.** Any structural problem aborts the run with the CSV path and 1-based
line number (header = line 1); fix the file and re-run. Aborts on: missing both `labelName` and
`label` columns; unbalanced quotes (header or row); a data row whose column count differs from the
header; an empty/whitespace-only label cell; a blank line anywhere but a single trailing one; an empty
file.

**Application-level filtering** happens *after* structural parsing and does **not** abort: labels
longer than 255 bytes and the bracketed-labelhash form (`[0x…]`) are skipped and counted as
`invalidLabelCount`.

> **Limitation:** `readline` splits on `\n`, so a field containing a literal newline inside quotes is
> misread. No exporter we control produces these; pre-process the file if you have one.

## How it works

Names stream from the CSV in batches of `--batch-size`. Each batch is verified with a single multicall
per side reading v2 state (`PermissionedRegistry.getState()`) and v1 expiry and registrant
(`BaseRegistrar.nameExpires()`, plus the owner reads in [Graveyard-held names](#graveyard-held-names)).
It is then submitted as one `BatchRegistrar.batchRegister()` transaction. Per-name action, in this
order:

| v2 status | v1 status | Action |
|---|---|---|
| Registered (2) | Any | **Fail** (already fully owned on v2) |
| Any | Never registered, or past v1's 90-day grace | **Skip** (v1 owner lost the claim) |
| Any | Registrant is a `Graveyard` | **Skip** (no v1 owner can claim it) |
| Available (0) | Registered, or expired but within v1's 90-day grace | **Reserve** with expiry `v1Expiry + bonusPeriodDays` |
| Reserved (1)† | Computed expiry longer than the stored one | **Renew** (extend expiry) |
| Reserved (1)† | Computed expiry equal to or shorter than the stored one | **Skip** (up to date) |

† Including a reservation past its expiry but inside the v2 grace period, which reads `Available (0)`
yet still belongs to its v1 owner. Treating it as available would re-send it on every sync and count it
as a fresh reservation each time.

Reserved names are written with owner/registry `address(0)`, resolver = `ENSV1Resolver`, roleBitmap
`0`, and the computed expiry.

### Graveyard-held names

A `Graveyard` holds v1 names that no v1 owner can take back. A migration hands it every name it moves
to v2, and `Graveyard.clear` takes an expired name out of circulation by registering it to the
Graveyard with an expiry at the `uint64` ceiling less the grace period. By expiry alone such a name
reads as live, but a reservation for it belongs to nobody, and `ETHRegistrar` never offers a reserved
name. So pre-migration neither reserves nor extends a name whose v1 registrant is a Graveyard, and
counts it under "v1 registrant is a Graveyard". A migrated name is still **Registered (2)** on the
registry it was migrated to, and is counted as already registered there, as before.

The registrant is read from four calls per name, made in the same multicall as the expiry:
`BaseRegistrar.ownerOf`, the `ENSRegistry` owner of the name's node, and `NameWrapper.ownerOf` of that
node. The node is `keccak256(namehash("eth") ‖ labelhash)`, so no plaintext label is needed.

- While the registration is live, the registrant is the `BaseRegistrar` token holder. It outranks the
  registry's node owner, since the holder can reclaim the node at any time.
- `ownerOf` reverts once the registration has expired, in grace too. The registrant is then the
  registry's node owner. The migration controllers and `Graveyard.clear` point the node at the Graveyard,
  so a migrated name still reads as the Graveyard's while it is in grace.
- When the holder found either way is the `NameWrapper`, the registrant is whoever the wrapper names. A
  locked migration leaves the `BaseRegistrar` token and the node with the `NameWrapper`, and hands the
  wrapper token to the Graveyard.

A name nobody holds has no registrant. A failed read that the registrant depends on fails the name, and
the name is retried.

`--graveyards` must list every Graveyard on the chain, not only the active deployment's. A superseded
deployment's Graveyard keeps every name it reclaimed or received while it was live: on Sepolia, the
Graveyard of the archived `sepolia-20260730-r1` set holds the names it reclaimed. The operator CLI
derives the set the way phase 3 finds superseded controllers: the active namespace's `Graveyard`
artifact plus that of every other namespace on the same chain. It leaves out a Graveyard whose artifact
records a different `NameWrapper` from the active one. That is a Graveyard of another v1, such as a
clean-testnet run's own, and it holds none of this v1's names. The CLI refuses to run when the active
namespace has no Graveyard.

Before anything is read, every address in the set must pass a check, so that a wrong address fails the
run instead of leaving that account's names unreserved:

- The address answers the Graveyard's `NAME_WRAPPER()`. An account or a Safe does not.
- It accepts a simulated `clear([])`, a no-op for a Graveyard. The migration controllers answer
  `NAME_WRAPPER()` but have no `clear`, so this is what refuses them.
- All the Graveyards report the same `NameWrapper`, and that wrapper's `registrar()` is the
  `BaseRegistrar` in use.

The `NameWrapper` and the registry (`NameWrapper.ens()`) are taken from the chain this way, not from
options.

A reservation is only ever extended, never shortened: `BatchRegistrar` renews when the requested
expiry is greater than the stored one and does nothing otherwise. Names that would be a no-op are left
out of the batch and counted separately, so the final sync sends only what has actually changed rather
than resubmitting the whole CSV.

> **When can a name be `Registered (2)`?** Not during the migration phases. Migration opens to users
> only after the final pre-migration sync completes, so a name owned on v2 while pre-migration is
> still running did not get there by being claimed. It is reported and counted, and does not fail the
> run, but it is worth understanding before continuing.

**One name cannot stop the run.** Every per-name failure mode is handled explicitly, but an
unforeseen one — a value that overflows a conversion, a malformed record — is caught, counted as a
failure, and skipped, so the rest of its batch is still reserved. Real chain data contains names with
deliberately maximal expiries (near `uint64` max), which is exactly the kind of value that used to
abort a whole run from a log line. Bonus-adjusted expiries are capped at `uint64` so they cannot wrap.

A whole batch failing is treated differently, because none of its names were written: the run stops
there so the checkpoint still points **before** those rows. Carrying on would advance the resume
cursor past names that were never reserved, and `--continue` would then skip them permanently. Re-run
with `--continue` once the cause is fixed.

**Gas safety.** Before submitting, the script estimates gas; if it exceeds 80% of the block limit the
batch is split in half and re-estimated (recursively). If a batch reverts at execution, it is
recursively halved and retried (binary search) until failing names are isolated — preserving partial
progress. A transaction that is slow to be mined is waited for, with or without a gas price limit,
and is not counted as failed: splitting its batch would send the names again while it can still be
mined. A checkpoint is saved after each batch.

### Gas price limit

A batch is not sent while the gas price is above a limit, and no transaction pays more than the
limit. The script reads the price again every 12 seconds, and sends as soon as it is at or below the
limit. A pause has no time limit: it lasts until the price comes back down, however long that takes.

- **Gas price** is a base fee plus a tip. The live price is the higher of the latest and the next
  block's base fee, plus the median of the last 5 blocks' median tips (the 50th-percentile priority
  fee that `eth_feeHistory` reports). The median keeps one unusual block from deciding the tip. The
  tip is what blocks paid, not the tip the RPC suggests, because suggested tips differ between
  providers by more than the limit itself.
- **Fee cap:** each transaction is sent with its maximum fee per gas set to the limit and its tip set
  to that market tip, so it never pays more than the limit. If the base fee rises past the limit
  after the check but before the send, the send is refused and the script waits again; the batch is
  not split. If the base fee rises after the send, the transaction waits in the node's pool until the
  base fee falls back.
- **Default:** `0.146` gwei on mainnet. This is the median mainnet gas price over the two weeks
  before the default was set. Other chains have no limit by default, because a mainnet price says
  nothing about their gas market. `--max-gas-price <gwei>` sets a limit on any chain. The run logs
  the limit it uses at start-up.
- **When it applies:** before every `batchRegister` transaction, including the smaller ones sent
  when a batch is split. A batch with nothing to send does not wait, so a final sync where most
  names are already up to date reads the chain at full speed.
- **While paused:** the log says when a pause starts, repeats every 5 minutes with the current
  price, and says when sends resume. A failed read of the chain does not end a pause: it is logged
  and tried again, with the wait between tries doubling from 12 seconds up to 5 minutes.
- **While a transaction waits to be mined:** the log reports it every 5 minutes, and there is no
  time limit here either. If the node no longer holds the transaction, it was dropped from the pool,
  and the batch waits for the price and is sent again rather than split: nothing is wrong with its
  names. Before sending again, the script checks whether an earlier send of the batch was mined
  instead. If the node refuses the new send for any reason other than a revert, an earlier send is
  still pending somewhere, so the script goes back to waiting on that one.

A batch that waits is sent with the results of the checks made before the pause. This is safe.
Nothing but pre-migration writes the v2 registry while it runs. The final sync picks up a v1 renewal
made during the pause. A name whose v1 grace ends during the pause gets an expiry that is already
past the v2 grace, so it reads as available.

> A local Anvil chain, forks included, mines a block only when a transaction arrives, so its gas
> price cannot fall while a run waits, and a paused run never resumes. A mainnet fork reports
> mainnet's chain id, so it gets the mainnet limit. The operator CLI's rehearsals and the devnet
> mine an empty block every second while pre-migration runs. The base fee then falls and the tips
> of recent blocks drop to what those blocks paid, so a rehearsal runs with the real limit and
> exercises the pause, the resume and the fee cap. When running the script by hand against a
> mainnet fork, start Anvil with `--block-time 1` for the same effect.

## Checkpoint & resume

A checkpoint (`preMigration-checkpoint.json`) is written after each batch, tracking the last processed
line and accumulated counters (reserved, renewed, skipped, invalid, failed). `--continue` loads it,
sets `--start-index` to the last processed line, and resumes; counters accumulate across runs. See the
resume command in [Quick start](#quick-start).

## Dry run

`--dry-run` runs the full pipeline — CSV parse, v1/v2 verification, expiry computation — and logs what
would happen, but sends no transactions. It is the default first step in [Quick start](#quick-start).

A dry run reads an existing checkpoint with `--continue` but never clears or saves one. Saving would move
the resume cursor past rows nothing was sent for and drop them from the retry queue, so a later real
`--continue` would skip them for good.

A dry run never waits for the gas price, but it logs the limit a real run would use.

## Output

Informational output goes to `preMigration.log` and errors to `preMigration-errors.log`; the console
mirrors progress with a final summary table (processed / reserved / renewed / skipped — never
registered, past grace, v1 registrant is a Graveyard / already registered / already up to date /
invalid / failed / success rate). Individual failures (name reverts,
RPC timeouts at a 30s per-call limit, checkpoint write errors) are counted and logged without aborting
the batch, so partial progress is preserved.

**A failed name is retried, not stepped over.** The checkpoint stops before the first failure, so
`--continue` reaches that name again rather than resuming past it. Names that succeeded after it are
re-read and skipped as already up to date, so the retry is cheap. A whole batch failing stops the run
for the same reason: none of its names were written, and the cursor must stay before them.

**A run that ends with failures exits non-zero.** A name that reverted was never written to v2, so
reporting the run as a success would hand back a green result over an incomplete reservation set.
Re-run with `--continue` after fixing the cause. The "already registered" and "already up to date"
counters are not failures — nothing was lost in either case — and do not affect the exit status.

## Testing on a Sepolia fork

To rehearse pre-migration against real Sepolia v1 state without a full `fork full` run, deploy the v2
stack onto a local Anvil fork (v2 is not on real Sepolia) and run pre-migration against it.

> **Account requirement:** the deployer/owner must be an address with **no code** on Sepolia. The
> standard Anvil test accounts carry an EIP-7702 delegation there, so their `onERC1155Received` does
> not return the ERC-1155 acceptance value and the `eth` 2LD mint during deploy reverts. Use a fresh
> throwaway key funded via `anvil_setBalance`.

```bash
# 1. Fork Sepolia
anvil --fork-url "$SEPOLIA_RPC_URL" --port 8547 --chain-id 11155111 &

# 2. Fresh deployer with no Sepolia code, funded on the fork
KEY=<fresh 0x… key>; ADDR=$(cast wallet address --private-key "$KEY")
cast rpc anvil_setBalance "$ADDR" 0x21e19e0c9bab2400000 --rpc-url http://127.0.0.1:8547

# 3. Deploy v2 onto the fork (impersonate the v1 owner for the .eth resolver write)
DEPLOYER_KEY=$KEY OWNER_KEY=$KEY UR_MANAGER_KEY=$KEY \
  bun run migration -- phase deploy-v2 --network sepolia --rpc-url http://127.0.0.1:8547 \
    --deployer "$ADDR" --owner "$ADDR" --ur-manager "$ADDR" --impersonate-v1-owner \
    --save-deployments --deployments-dir /tmp/fork-deployments --deployment-network sepolia

# 4. Run + verify (addresses read from the deployment JSON; v1 reads use the same fork RPC)
bun run migration -- premigration run --network sepolia --rpc-url http://127.0.0.1:8547 \
  --deployments-dir /tmp/fork-deployments --deployment-network sepolia \
  --csv-file ./csv-data/ens-registrations-sepolia.csv --private-key "$KEY"
bun run migration -- premigration verify --network sepolia --rpc-url http://127.0.0.1:8547 \
  --deployments-dir /tmp/fork-deployments --deployment-network sepolia \
  --csv-file ./csv-data/ens-registrations-sepolia.csv
```

Sepolia has no gas price limit by default. A mainnet fork does; see
[Gas price limit](#gas-price-limit) for keeping blocks coming on one.

The Graveyard set comes from `--deployments-dir`. A scratch directory like the one above holds only the
fork's own `Graveyard`, so names that an archived Sepolia deployment's Graveyard holds would still be
reserved on the fork. Add `--graveyards` with the fork's Graveyard and each `Graveyard.json` under
`deployments/sepolia*/` to leave them out, as a live run does.

For the full phased rehearsal instead, see the `fork full` command in
[migration.md](./migration.md#rehearsals).
