# ENS Pre-Migration Script

## Overview

The pre-migration script (`contracts/script/preMigration.ts`) migrates ENS v1 `.eth` second-level domain (2LD) registrations to the v2 registry. It reads a CSV export of v1 registrations, verifies each name on-chain against the v1 BaseRegistrar, and reserves or renews the name on v2 via the `BatchRegistrar` contract.

Names that are registered or still in the ENSv1 grace period are registered on v2 in a **reserved** state (owner set to `address(0)`) with the continuity-adjusted expiry and the ENSV1Resolver set as the fallback resolver. Actual ownership transfer happens in a later migration phase.

The continuity rules are fixed by the ENSv1 continuity case study:

- ENSv1 grace period: 90 days
- ENSv1 true grace period: 90 days + 1 second
- ENSv2 grace period: 28 days
- ENSv2 reservation bonus: 62 days + 1 second

Every eligible reservation uses `v2Expiry = v1Expiry + 62 days + 1 second`. Names are eligible when the ENSv1 name is actively registered or still inside ENSv1 grace.

## Prerequisites

- **Bun** runtime installed
- **Forge artifacts** compiled (`forge build` in `contracts/`)
- **Deployed contracts:**
  - `PermissionedRegistry` (the v2 ETH registry)
  - `BatchRegistrar` (owned by the deployer account)
  - `ENSV1Resolver` (deployed on v2 for fallback resolution)
- **Private key** for the `BatchRegistrar` owner account — provided via `--private-key` or the `PREMIGRATION_PRIVATE_KEY` environment variable
- **RPC endpoint** for Ethereum mainnet (where both v1 and v2 contracts live). The chain ID is auto-detected from the RPC.
  - Optionally, a separate `--mainnet-rpc-url` if v1 reads should go to a different endpoint (e.g. when running v2 on a local devnet that also has v1 contracts deployed)
- **CSV file** of v1 registrations (see [CSV Format](#csv-format))

## CLI Reference

Run from the `contracts/` directory:

```bash
bun run script/preMigration.ts [options]
```

For the full phased migration workflow, prefer the operator CLI:

```bash
bun run migration --help
```

The CLI entrypoint is `script/migration.ts` and is exposed through
`contracts/package.json`. Use `bun run migration --help` to list the available
phase commands.

When running against a Hardhat deployment network, prefer the Hardhat task so the
BatchRegistrar owner key can come from the configured Hardhat signer:

```bash
bunx hardhat --network tenderly-sepolia migration premigration-run \
  --migration-network sepolia \
  --deployment-network sepolia \
  --csv-file ./csv-data/ens-registrations-sepolia.csv \
  --mainnet-rpc-url https://sepolia-rpc.example.com \
  --min-expiry-days 0 \
  --skip-existing-reservations
```

Prepared owner transactions are JSONL files emitted by the phased migration
deploy. The owner can execute a specific role from that file without exposing the
key on the command line:

```bash
SEPOLIA_V1_OWNER_KEY=0xabc...def bun run migration -- phase execute-owner-txs \
  --network sepolia \
  --rpc-url https://sepolia-rpc.example.com \
  --file ./owner-txs.jsonl \
  --role v1Owner
```

Mnemonic-backed owner accounts can use the matching mnemonic environment
variable instead. This is intended to work with secret-injection tools such as
1Password CLI:

```bash
op run --env-file ./owner-txs.env -- bun run migration -- phase execute-owner-txs \
  --network sepolia \
  --rpc-url https://sepolia-rpc.example.com \
  --file ./owner-txs.jsonl \
  --role v1Owner
```

Where `owner-txs.env` contains a secret reference such as
`SEPOLIA_V1_OWNER_MNEMONIC=op://Vault/Item/mnemonic`. Use
`SEPOLIA_V1_OWNER_MNEMONIC_INDEX` or `SEPOLIA_V1_OWNER_MNEMONIC_PATH` if the
owner is not the first derived account. If the mnemonic uses a BIP39
passphrase, set `SEPOLIA_V1_OWNER_MNEMONIC_PASSPHRASE` to a separate secret
reference.

The operator CLI can verify a pre-migration pass after the reservations are
submitted:

```bash
bun run migration -- premigration verify \
  --network sepolia \
  --rpc-url https://sepolia-rpc.example.com \
  --deployment-network sepolia \
  --csv-file ./csv-data/ens-registrations-sepolia.csv
```

The verifier checks the stored continuity expiry for every eligible name. Names
whose v2 continuity expiry is already in the past may read as available from the
registry, so the verifier reports those separately instead of treating the
available status as a failure.

After the final pre-migration pass, the hand-off phases are split across v1 and
v2 permissions. Phase 8 authorizes `Graveyard` as a v1 BaseRegistrar controller
and keeps `TestnetV1PremigrationRegistrar` authorized on testnets when that
deployment exists. Phase 9 authorizes `ETHRenewerV1` as a v1 BaseRegistrar
controller, transfers v1 BaseRegistrar ownership to `ETHRenewerV1`, then grants
`REGISTRAR | RENEW` on the v2 ETH registry to `ETHRegistrar`.

Before the final pre-migration sync, export a fresh CSV for the target network
after v1 registration controllers are disabled. This applies to both Sepolia and
mainnet. The initial pre-migration pass can use the current export plus
`--min-expiry-days 7`, but the final sync should use fresh data with
`--min-expiry-days 0` and `--skip-existing-reservations` so it catches names
registered, renewed, or crossing the expiry buffer before the v1 freeze. The
skip only applies when the existing v2 reservation already has the expected
continuity expiry; a differing expiry is renewed.

For Sepolia, use the audited Dune export query `7411764`
(`ENS Sepolia registrations pre-migration CSV export`). Execute it after the v1
freeze and download the execution CSV for phase 4:

```bash
curl -X POST https://api.dune.com/api/v1/query/7411764/execute \
  -H "x-dune-api-key: $DUNE_API_KEY" \
  -H "content-type: application/json" \
  -d '{"performance":"medium"}'
```

Poll the returned execution id at
`/api/v1/execution/<execution_id>/status`, then download
`/api/v1/execution/<execution_id>/results/csv` to the phase-4 CSV path.

For mainnet, use the Google BigQuery export source rather than Dune. The output
still must use the same CSV shape described below.

```bash
THEGRAPH_API_KEY=... bun run migration -- fetch-data \
  --network sepolia \
  --output ./csv-data/ens-registrations-sepolia-final-sync.csv
```

### Required Options

| Option | Description |
|---|---|
| `--rpc-url <url>` | Ethereum mainnet RPC endpoint |
| `--registry <address>` | v2 PermissionedRegistry contract address |
| `--batch-registrar <address>` | BatchRegistrar contract address |
| `--csv-file <path>` | Path to the CSV file of v1 registrations |
| `--v1-resolver <address>` | ENSV1Resolver address on v2 for fallback resolution |

### Optional

| Option | Default | Description |
|---|---|---|
| `--private-key <key>` | `PREMIGRATION_PRIVATE_KEY` env var | Deployer private key. If omitted, falls back to the `PREMIGRATION_PRIVATE_KEY` environment variable. The script exits with an error if neither is provided. The migration CLI also accepts `BATCH_REGISTRAR_OWNER_KEY` or `DEPLOYER_KEY` as fallbacks. |
| `--mainnet-rpc-url <url>` | `https://eth.drpc.org` | Mainnet RPC for v1 BaseRegistrar expiry lookups. Useful when v2 is running on a local devnet with its own v1 contracts, so v1 reads can be pointed at the devnet instead of real mainnet. |
| `--batch-size <number>` | `50` | Names per on-chain batch transaction |
| `--start-index <number>` | `-1` | CSV line number to start from (used internally with `--continue`) |
| `--limit <number>` | none | Maximum total names to process |
| `--dry-run` | `false` | Simulate without sending transactions |
| `--continue` | `false` | Resume from the last checkpoint |
| `--min-expiry-days <days>` | `0` | Skip active names expiring within this many days. Names already in ENSv1 grace are still continuity-eligible. |
| `--v1-base-registrar <address>` | `0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85` | v1 BaseRegistrar address for expiry lookups |

### Registration Export

`bun run migration -- fetch-data` and `script/exportTheGraphRegistrations.ts`
accept `--thegraph-api-key`, `THEGRAPH_API_KEY`, or `GRAPH_API_KEY`.

## CSV Format

Parsing is **header-driven**. The script reads the first line as the header, locates the label column by name, and ignores everything else. Two column names are accepted (case-insensitive, leading/trailing whitespace trimmed):

- **`labelName`** — the v1 subgraph schema. Preferred when both names are present.
- **`label`** — the name used by the `exportTheGraphRegistrations.ts` exporter.

Both of these inputs work without any flag:

```csv
node,name,labelHash,owner,parentName,parentLabelHash,labelName,registrationDate,expiryDate
,,,,,,vitalik,,
,,,,,,nick,,
,,,,,,ens,,
```

```csv
name,label,labelhash,registrant,expiryDate,registrationDate
vitalik.eth,vitalik,0x...,0x...,...,...
nick.eth,nick,0x...,0x...,...,...
```

The parser handles quoted fields and `""`-escaped quotes within values. A UTF-8 BOM on the header line and a single trailing blank line at end of file are tolerated. CRLF line endings are normalized to LF.

### Strict-mode behavior

Any structural problem aborts the run with a clear error that includes the CSV path and 1-based line number (the header counts as line 1). The script does not try to recover — fix the file and re-run.

| Condition | Behavior |
|---|---|
| Header has no `labelName` and no `label` column | Abort. Error lists the columns that were found. |
| Header has unbalanced quotes | Abort. |
| Data row column count does not match header column count | Abort. Error shows declared and actual counts and the first ~200 chars of the row. |
| Data row has unbalanced quotes | Abort. |
| Data row has an empty (or whitespace-only) value in the label column | Abort. |
| Blank line in the middle of the file | Abort. Only a single trailing blank line is tolerated. |
| File is empty (no header) | Abort. |

Application-level filtering still applies *after* structural parsing — labels longer than 255 bytes and the bracketed-labelhash form (`[0x…]`) are skipped and counted as `invalidLabelCount` rather than aborting the run.

### Known limitation

`readline` splits on `\n`, so a field that contains a literal newline inside quotes will be misread. No exporter we control produces such fields. If you have one, pre-process the file to strip or escape the embedded newline.

## How It Works

### End-to-End Pipeline

1. **Parse CLI options** and build configuration
2. **Load checkpoint** if `--continue` is set and a checkpoint file exists
3. **Connect** to the v2 chain and Ethereum mainnet via RPC
4. **Validate** that the `BatchRegistrar` contract is deployed
5. **Stream** the CSV file, reading names in batches of `--batch-size`
6. **Filter** invalid/empty labels from the batch
7. **Verify all names in the batch via multicall** — a single multicall reads v2 state (`PermissionedRegistry.getState()`) and v1 expiry (`BaseRegistrar.nameExpires()`) for all names in two RPC calls
8. **For each verified name:**
   - If already **registered** (status 2): fail — name is fully owned on v2
   - If already **reserved** (status 1): mark for potential renewal
   - If not registered on v1 or fully available after ENSv1 grace: skip
   - Add to the batch reservation list with v2 expiry = `v1Expiry + 62 days + 1 second`
9. **Estimate gas** for the batch and preemptively split if estimated gas exceeds 80% of the block gas limit
10. **Submit batch transaction** via `BatchRegistrar.batchRegister()`. If a batch reverts, recursively split it in half (binary-search fallback) until individual failing names are isolated.
11. **Save checkpoint** after each batch
12. **Print final summary**

### Name Processing States

| v2 Status | v1 Status | Action |
|---|---|---|
| Available (0) | Registered or in ENSv1 grace | **Reserve** on v2 |
| Reserved (1) | Registered or in ENSv1 grace with different continuity expiry | **Renew** on v2 (sync expiry) |
| Reserved (1) | Registered or in ENSv1 grace with same continuity expiry | **Skip** (already up-to-date) |
| Registered (2) | Any | **Fail** (already fully registered) |
| Any | Fully available on ENSv1 or never registered | **Skip** |

### On-Chain Registration Parameters

Each name is reserved with:
- **owner**: `address(0)` (reserved, not yet claimed)
- **registry**: `address(0)`
- **resolver**: The ENSV1Resolver address (for fallback resolution to v1 records)
- **roleBitmap**: `0`
- **expires**: The v1 expiry timestamp plus the fixed continuity bonus of 62 days + 1 second

## Batch Processing

Names are grouped into batches (default size 50) and submitted as a single `batchRegister()` transaction. Verification of v1 and v2 state is done via multicall, reducing per-batch RPC calls to 2 regardless of batch size.

### Gas Estimation & Dynamic Splitting

Before submitting a batch, the script estimates gas usage. If the estimate exceeds 80% of the block gas limit, the batch is preemptively split in half and each half is estimated independently (recursively). This prevents out-of-gas reverts for large batches or batches with high-calldata names.

### Binary-Search Batch Fallback

If a batch transaction reverts at execution time, the script recursively splits it in half and retries each half. This continues until either a sub-batch succeeds or individual failing names are isolated. This preserves partial progress — names that can be registered will succeed even if something in the batch caused a revert.

## BatchRegistrar Contract

The `BatchRegistrar` contract (`contracts/src/registrar/BatchRegistrar.sol`) is a simple owner-gated batch wrapper around `PermissionedRegistry`. For each name in a batch:

- **Already registered** (not expired, has owner): skip silently
- **Not registered or expired**: call `register()`
- **Reserved with lower expiry**: call `renew()` to sync
- **Reserved with same/higher expiry**: skip (no-op)

The contract is `Ownable` — only the owner can call `batchRegister()`.

## Checkpoint & Resume

The script writes a checkpoint file (`preMigration-checkpoint.json`) after each batch. The checkpoint contains:

```json
{
  "lastProcessedLineNumber": 499,
  "totalProcessed": 500,
  "totalExpected": 500,
  "successCount": 480,
  "renewedCount": 5,
  "failureCount": 3,
  "skippedCount": 10,
  "invalidLabelCount": 2,
  "timestamp": "2026-03-10T12:00:00.000Z"
}
```

To resume after an interruption:

```bash
bun run script/preMigration.ts --continue [same options as before]
```

The `--continue` flag loads the checkpoint, sets `--start-index` to the last processed line, and resumes from there. Counters accumulate across runs.

## Dry Run Mode

Use `--dry-run` to simulate the entire pipeline without sending transactions:

```bash
bun run script/preMigration.ts --dry-run [options]
```

Dry run still:
- Reads and parses the CSV
- Checks v2 state for each name
- Verifies v1 registration and expiry
- Applies the fixed continuity bonus to each eligible expiry
- Logs what would happen
- Saves checkpoints

It does **not** send any on-chain transactions.

## Output & Logging

### Log Files

| File | Contents |
|---|---|
| `preMigration.log` | All informational output (processing steps, results) |
| `preMigration-errors.log` | Errors only (failed names, RPC issues) |

### Console Output

The script uses color-coded console output:
- Green: successful reservations
- Cyan: renewals
- Yellow: skipped names
- Red: failures
- Magenta: progress summaries

### Final Summary

At completion, a summary table is printed:

```
Total names processed:          500
Successfully reserved:          480
Successfully renewed:             5
Skipped:                         10
Invalid labels:                   2
Failed:                           3
Actual reservations/renewals:   488
Success rate:                   99%
```

## Error Handling

| Scenario | Behavior |
|---|---|
| CSV structural problem (bad header, wrong column count, unbalanced quotes, empty label cell, mid-file blank line) | Abort the run. See [CSV Format](#csv-format) for the full list. |
| Label longer than 255 bytes or in the `[0x…]` bracketed-labelhash form | Filtered out before processing, counted as `invalidLabelCount` |
| Name not registered on v1 | Skipped, counted as `skippedCount` |
| Name already fully registered on v2 | Counted as failure |
| Batch transaction reverts | Binary-search split: recursively halves the batch until individual failures are isolated |
| Batch gas estimate exceeds 80% of block limit | Preemptively splits the batch before submitting |
| Gas estimation fails | Falls back to binary-search batch submission |
| Individual transaction reverts | Counted as failure, logged to error file |
| RPC timeout | 30-second timeout per call; failure counted and logged |
| Checkpoint write failure | Logged as error, processing continues |

## Examples

### Full migration (dry run first)

```bash
# Set private key via environment variable
export PREMIGRATION_PRIVATE_KEY=0xabc...def

# Dry run to verify
bun run script/preMigration.ts \
  --rpc-url https://v2-rpc.example.com \
  --registry 0x1234...abcd \
  --batch-registrar 0x5678...ef01 \
  --csv-file ./data/v1-registrations.csv \
  --v1-resolver 0x9876...5432 \
  --dry-run

# Execute for real
bun run script/preMigration.ts \
  --rpc-url https://v2-rpc.example.com \
  --registry 0x1234...abcd \
  --batch-registrar 0x5678...ef01 \
  --csv-file ./data/v1-registrations.csv \
  --v1-resolver 0x9876...5432

# Or pass the private key directly
bun run script/preMigration.ts \
  --rpc-url https://v2-rpc.example.com \
  --registry 0x1234...abcd \
  --batch-registrar 0x5678...ef01 \
  --private-key 0xabc...def \
  --csv-file ./data/v1-registrations.csv \
  --v1-resolver 0x9876...5432
```

### Process a limited number of names

```bash
bun run script/preMigration.ts \
  --limit 100 \
  --batch-size 25 \
  [other options]
```

### Resume after interruption

```bash
bun run script/preMigration.ts --continue [same options]
```

### Custom v1 BaseRegistrar (for testing)

```bash
bun run script/preMigration.ts \
  --v1-base-registrar 0xCustomBaseRegistrar... \
  --mainnet-rpc-url http://localhost:8545 \
  [other options]
```
