# ENS Pre-Migration Script

## Overview

The pre-migration script (`contracts/script/preMigration.ts`) migrates ENS v1 `.eth` second-level domain (2LD) registrations to the v2 registry. It reads a CSV export of v1 registrations, verifies each name on-chain against the v1 BaseRegistrar, and reserves or renews the name on v2 via the `BatchRegistrar` contract.

Names are registered on v2 in a **reserved** state (owner set to `address(0)`) with the v1 expiry date preserved and the ENSV1Resolver set as the fallback resolver. Actual ownership transfer happens in a later migration phase.

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
| `--private-key <key>` | `PREMIGRATION_PRIVATE_KEY` env var | Deployer private key. If omitted, falls back to the `PREMIGRATION_PRIVATE_KEY` environment variable. The script exits with an error if neither is provided. |
| `--mainnet-rpc-url <url>` | `https://eth.drpc.org` | Mainnet RPC for v1 BaseRegistrar expiry lookups. Useful when v2 is running on a local devnet with its own v1 contracts, so v1 reads can be pointed at the devnet instead of real mainnet. |
| `--batch-size <number>` | `50` | Names per on-chain batch transaction |
| `--start-index <number>` | `-1` | CSV line number to start from (used internally with `--continue`) |
| `--limit <number>` | none | Maximum total names to process |
| `--dry-run` | `false` | Simulate without sending transactions |
| `--continue` | `false` | Resume from the last checkpoint |
| `--grace-period-days <days>` | `90` | Days of grace period added on top of each name's v1 expiry. Every reserved name gets `v1Expiry + gracePeriodDays` as its v2 expiry. Set to `0` to preserve v1 expiries exactly. |
| `--v1-base-registrar <address>` | `0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85` | v1 BaseRegistrar address for expiry lookups |

## CSV Format

The CSV must have a header row with the following columns:

```
node,name,labelHash,owner,parentName,parentLabelHash,labelName,registrationDate,expiryDate
```

Only the **`labelName`** column (index 6, zero-based) is used by the script. All other columns can be empty. Example:

```csv
node,name,labelHash,owner,parentName,parentLabelHash,labelName,registrationDate,expiryDate
,,,,,,vitalik,,
,,,,,,nick,,
,,,,,,ens,,
```

The script handles quoted fields and escaped quotes within CSV values.

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
   - If not registered or expired on v1: skip
   - Add to the batch reservation list with v2 expiry = `v1Expiry + --grace-period-days`
9. **Estimate gas** for the batch and preemptively split if estimated gas exceeds 80% of the block gas limit
10. **Submit batch transaction** via `BatchRegistrar.batchRegister()`. If a batch reverts, recursively split it in half (binary-search fallback) until individual failing names are isolated.
11. **Save checkpoint** after each batch
12. **Print final summary**

### Name Processing States

| v2 Status | v1 Status | Action |
|---|---|---|
| Available (0) | Registered & not expiring soon | **Reserve** on v2 |
| Reserved (1) | Registered with different expiry | **Renew** on v2 (sync expiry) |
| Reserved (1) | Registered with same expiry | **Skip** (already up-to-date) |
| Registered (2) | Any | **Fail** (already fully registered) |
| Any | Expired or never registered | **Skip** |

### On-Chain Registration Parameters

Each name is reserved with:
- **owner**: `address(0)` (reserved, not yet claimed)
- **registry**: `address(0)`
- **resolver**: The ENSV1Resolver address (for fallback resolution to v1 records)
- **roleBitmap**: `0`
- **expires**: The v1 expiry timestamp plus `--grace-period-days`

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
- Applies `--grace-period-days` to each expiry
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
| Invalid/empty label in CSV | Filtered out before processing, counted as `invalidLabelCount` |
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

### Custom grace period

```bash
bun run script/preMigration.ts --grace-period-days 180 [other options]
```

Every reserved name's v2 expiry is set to `v1Expiry + 180 days`. Pass `0` to preserve v1 expiries exactly.

### Custom v1 BaseRegistrar (for testing)

```bash
bun run script/preMigration.ts \
  --v1-base-registrar 0xCustomBaseRegistrar... \
  --mainnet-rpc-url http://localhost:8545 \
  [other options]
```
