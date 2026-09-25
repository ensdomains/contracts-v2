#!/usr/bin/env bun

import { Command, InvalidArgumentError } from "commander";
import {
  createReadStream,
  existsSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import {
  BaseError,
  concat,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  encodeFunctionData,
  FeeCapTooLowError,
  formatGwei,
  getAddress,
  getContract,
  http,
  keccak256,
  namehash,
  parseGwei,
  publicActions,
  toHex,
  TransactionNotFoundError,
  TransactionReceiptNotFoundError,
  WaitForTransactionReceiptTimeoutError,
  zeroAddress,
  type Address,
  type FeeHistory,
  type Hex,
  type TransactionReceipt,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import {
  blue,
  bold,
  cyan,
  dim,
  green,
  Logger,
  magenta,
  red,
  yellow,
} from "./logger.js";

import { GRACE_PERIOD_V2, STATUS } from "./deploy-constants.js";
import { loadArtifact, resolveChain } from "./scriptUtils.js";
import {
  BaseRegistrar,
  EnsRegistry,
  Graveyard,
  NameWrapper,
} from "./migrations/abis.js";

const BASE_REGISTRAR_ABI = BaseRegistrar.nameExpires;

// Custom Errors
export class UnexpectedOwnerError extends Error {
  constructor(
    public readonly labelName: string,
    public readonly actualOwner: Address,
    public readonly expectedOwner: Address,
  ) {
    super(
      `Name ${labelName}.eth is already registered but owned by unexpected address: ${actualOwner} (expected: ${expectedOwner})`,
    );
    this.name = "UnexpectedOwnerError";
  }
}

export class InvalidLabelNameError extends Error {
  constructor(public readonly labelName: any) {
    super(`Invalid label name: ${labelName}`);
    this.name = "InvalidLabelNameError";
  }
}

export class CSVFormatError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CSVFormatError";
  }
}

/// A run that finished with names it could not reserve. They are queued in the
/// checkpoint, so a `--continue` run retries exactly those names.
export class FailedNamesError extends Error {
  constructor(public readonly count: number) {
    super(
      `pre-migration finished with ${count} failed name(s); see ${ERROR_LOG_FILE}`,
    );
    this.name = "FailedNamesError";
  }
}

const ENCODED_LABELHASH_RE = /^\[[0-9a-fA-F]{64}\]$/;

/// Whether a label has the `[labelhash]` shape ENS uses to show a label it does not
/// know. A CSV row in that shape is not a label pre-migration can submit: it is either
/// such a placeholder, or a name registered with the placeholder text itself, and the
/// two cannot be told apart from the text.
export function isEncodedLabelhash(label: string): boolean {
  return ENCODED_LABELHASH_RE.test(label);
}

export function isValidLabel(label: any): label is string {
  return (
    !!label &&
    typeof label === "string" &&
    label.trim() !== "" &&
    Buffer.from(label).length <= 255 &&
    !isEncodedLabelhash(label)
  );
}

// Types
export interface ENSRegistration {
  labelName: string;
  lineNumber: number;
}

export interface PreMigrationConfig {
  rpcUrl: string;
  mainnetRpcUrl: string;
  registryAddress: Address;
  batchRegistrarAddress: Address;
  privateKey?: `0x${string}`;
  account?: Address;
  csvFilePath: string;
  batchSize: number;
  startIndex: number;
  limit: number | null;
  dryRun: boolean;
  continue?: boolean;
  disableCheckpoint?: boolean;
  bonusPeriodDays: number;
  v1ResolverAddress: Address;
  v1BaseRegistrarAddress: Address;
  /// Graveyards whose v1 names are not claimable. See `v1Eligibility`.
  graveyards: ReadonlySet<Address>;
  /// Highest gas price, in wei, at which a batch is sent. Left out, the chain's
  /// default applies; see `resolveMaxGasPrice`.
  maxGasPrice?: bigint;
}

export interface Checkpoint {
  lastProcessedLineNumber: number;
  totalProcessed: number;
  totalExpected: number;
  successCount: number;
  renewedCount: number;
  /// CSV line numbers whose name has failed and has not since succeeded. Held as
  /// lines rather than as a count so a resumed run can retry exactly those rows,
  /// and so a row that later succeeds stops being reported as a failure.
  failedLines: number[];
  /// Aggregate of the skip sub-counters below (names not claimable on v1).
  skippedCount: number;
  /// Names skipped because they were never registered on v1.
  skippedNeverRegisteredCount: number;
  /// Names skipped because their v1 registration lapsed past the grace period.
  skippedPastGraceCount: number;
  /// Names skipped because a Graveyard is their v1 registrant.
  skippedGraveyardCount: number;
  /// Names skipped because they are already registered (owned) on v2. Tracked
  /// separately from genuine failures.
  alreadyRegisteredCount: number;
  /// Names already reserved on v2 with an expiry at least as long as the one this
  /// run would set. Submitting them would be a no-op on-chain, so they are not sent.
  upToDateCount: number;
  invalidLabelCount: number;
  timestamp: string;
}

// Constants
export const CHECKPOINT_FILE = "preMigration-checkpoint.json";
const ERROR_LOG_FILE = "preMigration-errors.log";
const INFO_LOG_FILE = "preMigration.log";

const RPC_TIMEOUT_MS = 30000;

// ENS v1 BaseRegistrar on Ethereum mainnet
const BASE_REGISTRAR_ADDRESS =
  "0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85" as Address;

/// Hard-coded ENSv1 grace period (in days). Defines the window after a name's
/// v1 expiry during which the original owner retains exclusive renewal rights
/// on v1. Sourced from `BaseRegistrarImplementation.GRACE_PERIOD = 90 days`.
/// Used as the v1-side eligibility gate for migration: a name is migratable
/// only while its v1 owner can still renew it.
export const V1_GRACE_PERIOD_DAYS = 90n;
export const V1_GRACE_PERIOD_SECONDS = V1_GRACE_PERIOD_DAYS * 86400n;

/// Whether a v1 name's expiry still leaves it claimable. A name that was never
/// registered, or whose grace period has elapsed, is not: pre-migration will not
/// reserve it, and nothing downstream may treat it as something the migration
/// carries over. Judge against chain time — on a fork the wall clock disagrees, and
/// a wall-clock now admits names the chain has released.
///
/// This is the expiry half of `v1Eligibility`. On its own it suits only a question
/// about expiries, such as whether two exports agree on how many names are live.
export function isClaimableOnV1(expiry: bigint, now: bigint): boolean {
  return expiry > 0n && expiry + V1_GRACE_PERIOD_SECONDS > now;
}

/// A v1 `.eth` registration: its expiry, and the account that holds it (see
/// `readV1Registrations`), or null when nobody does.
export type V1Registration = { expiry: bigint; registrant: Address | null };

/// Whether a v1 name is within the migration's remit, and why not when it is not.
export type V1Eligibility =
  | "claimable"
  | "never-registered"
  | "past-grace"
  | "graveyard";

/// Log text for each reason a v1 name is not claimable.
export const V1_INELIGIBILITY_REASONS: Record<
  Exclude<V1Eligibility, "claimable">,
  string
> = {
  "never-registered": "never registered on v1",
  "past-grace": `past v1 ${V1_GRACE_PERIOD_DAYS}-day grace period`,
  graveyard: "v1 registrant is a Graveyard",
};

/// The single rule for whether pre-migration reserves a v1 name, and whether anything
/// that checks its work may expect a reservation.
///
/// The expiry has to leave the name claimable (see `isClaimableOnV1`), and a Graveyard
/// must not be its registrant. A Graveyard holds v1 tokens that no v1 owner can take
/// back: a migration hands it the token of a migrated name, and `Graveyard.clear`
/// re-registers an expired name to itself with an expiry near the uint64 ceiling to
/// take it out of circulation. A reservation for such a name belongs to nobody, and
/// `ETHRegistrar` never offers a reserved name, so reserving it would lock the name on
/// v2 instead of freeing it.
///
/// `graveyards` must hold every Graveyard deployed on the chain, superseded ones
/// included, since each keeps the names it took while its deployment was live.
export function v1Eligibility(
  registration: V1Registration,
  now: bigint,
  graveyards: ReadonlySet<Address>,
): V1Eligibility {
  if (registration.expiry === 0n) return "never-registered";
  if (!isClaimableOnV1(registration.expiry, now)) return "past-grace";
  if (
    registration.registrant !== null &&
    graveyards.has(getAddress(registration.registrant))
  ) {
    return "graveyard";
  }
  return "claimable";
}

/// The Graveyard addresses given, checksummed and deduplicated.
///
/// An empty set is refused rather than read as "no Graveyards": every deployment
/// carries one, so an empty set means the addresses were never supplied, and running
/// without them reserves every name a Graveyard holds.
export function graveyardSet(
  addresses: readonly string[],
): ReadonlySet<Address> {
  const set = new Set<Address>();
  for (const address of addresses) {
    const trimmed = address.trim();
    if (trimmed === "") continue;
    try {
      set.add(getAddress(trimmed));
    } catch {
      throw new Error(`not an address: ${JSON.stringify(address)}`);
    }
  }
  if (set.size === 0) {
    throw new Error(
      "no Graveyard address given: without one, every v1 name a Graveyard holds would be reserved",
    );
  }
  return set;
}

/// Parses a comma-separated `--graveyards` value for a command line.
export function parseGraveyardAddresses(value: string): Address[] {
  try {
    return [...graveyardSet(value.split(","))];
  } catch (error) {
    throw new InvalidArgumentError((error as Error).message);
  }
}

/// The v1 contracts a registrant is resolved through.
export type V1Contracts = {
  baseRegistrar: Address;
  /// The v1 `ENSRegistry`, which records who owns each name's node.
  registry: Address;
  nameWrapper: Address;
};

/// Checks that every address in the set is a Graveyard of this v1, and returns the
/// v1 contracts the Graveyards are bound to.
///
/// Pre-migration leaves a name unreserved when a listed address holds it, and the
/// reconciliation that gates the v1 freeze stops expecting it. A wrong address would
/// therefore strand every name its account holds. So each address has to answer the
/// Graveyard's `NAME_WRAPPER()`, which an externally owned account or a Safe does not,
/// and accept a simulated `clear([])`, a no-op for a Graveyard that the migration
/// controllers, which also answer `NAME_WRAPPER()`, do not have. Every Graveyard must
/// report the same `NameWrapper`, and that wrapper's registrar must be
/// `baseRegistrar`. The wrapper's registry is where a name's node owner is read.
export async function resolveV1Contracts(
  client: any,
  graveyards: ReadonlySet<Address>,
  baseRegistrar: Address,
): Promise<V1Contracts> {
  const failures: string[] = [];
  const wrappers = new Map<Address, Address[]>();
  const clearCall = encodeFunctionData({
    abi: Graveyard.clear,
    functionName: "clear",
    args: [[]],
  });
  await Promise.all(
    [...graveyards].map(async (address) => {
      try {
        const [wrapper] = await Promise.all([
          client.readContract({
            address,
            abi: Graveyard.NAME_WRAPPER,
            functionName: "NAME_WRAPPER",
          }) as Promise<Address>,
          client.call({ to: address, data: clearCall }),
        ]);
        const key = getAddress(wrapper);
        wrappers.set(key, [...(wrappers.get(key) ?? []), address]);
      } catch (error) {
        const message =
          error instanceof BaseError ? error.shortMessage : String(error);
        failures.push(`${address} (${message})`);
      }
    }),
  );
  if (failures.length > 0) {
    throw new Error(
      `not a Graveyard on the v1 chain: ${failures.sort().join(", ")}. A name held by a listed address is not reserved, so the set must name Graveyards only.`,
    );
  }
  if (wrappers.size !== 1) {
    const described = [...wrappers]
      .map(([wrapper, holders]) => `${wrapper} (${holders.join(", ")})`)
      .join("; ");
    throw new Error(
      `the Graveyards report different NameWrappers: ${described}. A Graveyard of another v1 holds none of this one's names; leave it out of the set.`,
    );
  }
  const [nameWrapper] = wrappers.keys();
  const [registrar, registry] = await Promise.all([
    client.readContract({
      address: nameWrapper,
      abi: NameWrapper.registrar,
      functionName: "registrar",
    }) as Promise<Address>,
    client.readContract({
      address: nameWrapper,
      abi: NameWrapper.ens,
      functionName: "ens",
    }) as Promise<Address>,
  ]);
  if (getAddress(registrar) !== getAddress(baseRegistrar)) {
    throw new Error(
      `the Graveyards' NameWrapper ${nameWrapper} is bound to BaseRegistrar ${registrar}, not ${baseRegistrar}: they belong to another v1`,
    );
  }
  return {
    baseRegistrar: getAddress(baseRegistrar),
    registry: getAddress(registry),
    nameWrapper,
  };
}

/// A v1 read that failed, and so says nothing about the name.
export type V1ReadError = { error: string };

// Whether an error, or anything that caused it, is of the given kind.
function hasCause(
  error: unknown,
  kind: abstract new (...args: any[]) => Error,
): boolean {
  return (
    error instanceof BaseError &&
    error.walk((cause) => cause instanceof kind) !== null
  );
}

// Whether a failed call reverted, as opposed to failing to reach or decode.
function isRevert(error: unknown): boolean {
  return hasCause(error, ContractFunctionRevertedError);
}

type CallOutcome = {
  status: "success" | "failure";
  result?: unknown;
  error?: unknown;
};

const ETH_NODE = namehash("eth");

/// The v1 node of the `.eth` 2LD with this labelhash, which the registry and the
/// `NameWrapper` key the name by.
export function ethNameNode(labelhash: bigint): Hex {
  return keccak256(concat([ETH_NODE, toHex(labelhash, { size: 32 })]));
}

// Follows a name to its registrant through the four reads `readV1Registrations` makes.
//
// The token holder is authoritative while the registration is live: they can reclaim
// the registry node whenever they like. `ownerOf` reverts once the registration has
// expired, in grace too, and then the registry's node owner is the best record left.
// The migration controllers and `Graveyard.clear` point it at the Graveyard, so a
// migrated name still reads as the Graveyard's in grace. A wrapped name's token and
// node both sit with the `NameWrapper`, so its registrant is whoever the wrapper
// names: a locked migration hands the wrapper token to the Graveyard.
function resolveRegistrant(
  v1: V1Contracts,
  ownerOf: CallOutcome,
  nodeOwner: CallOutcome,
  wrapperOwner: CallOutcome,
): Pick<V1Registration, "registrant"> | V1ReadError {
  let holder: Address;
  if (ownerOf.status === "success") {
    holder = getAddress(ownerOf.result as Address);
  } else if (!isRevert(ownerOf.error)) {
    return { error: `ownerOf: ${String(ownerOf.error)}` };
  } else if (nodeOwner.status === "success") {
    holder = getAddress(nodeOwner.result as Address);
  } else {
    return { error: `registry owner: ${String(nodeOwner.error)}` };
  }
  if (holder === v1.nameWrapper) {
    if (wrapperOwner.status === "failure") {
      return { error: `NameWrapper ownerOf: ${String(wrapperOwner.error)}` };
    }
    holder = getAddress(wrapperOwner.result as Address);
  }
  return { registrant: holder === zeroAddress ? null : holder };
}

/// Each id's v1 expiry and registrant, read in one multicall so they describe the same
/// state: `nameExpires`, `BaseRegistrar.ownerOf`, the registry's owner of the name's
/// node, and `NameWrapper.ownerOf` of that node. See `resolveRegistrant` for how the
/// three owner reads combine into the registrant.
export async function readV1Registrations(
  client: any,
  v1: V1Contracts,
  ids: readonly bigint[],
): Promise<Array<V1Registration | V1ReadError>> {
  if (ids.length === 0) return [];
  const outcomes: CallOutcome[] = await client.multicall({
    allowFailure: true,
    contracts: ids.flatMap((id) => {
      const node = ethNameNode(id);
      return [
        {
          address: v1.baseRegistrar,
          abi: BASE_REGISTRAR_ABI,
          functionName: "nameExpires",
          args: [id],
        },
        {
          address: v1.baseRegistrar,
          abi: BaseRegistrar.ownerOf,
          functionName: "ownerOf",
          args: [id],
        },
        {
          address: v1.registry,
          abi: EnsRegistry.owner,
          functionName: "owner",
          args: [node],
        },
        {
          address: v1.nameWrapper,
          abi: NameWrapper.ownerOf,
          functionName: "ownerOf",
          args: [BigInt(node)],
        },
      ];
    }),
  });
  return ids.map((_, index) => {
    const [expiry, ownerOf, nodeOwner, wrapperOwner] = outcomes.slice(
      4 * index,
      4 * index + 4,
    );
    if (expiry.status === "failure") {
      return { error: `nameExpires: ${String(expiry.error)}` };
    }
    const owner = resolveRegistrant(v1, ownerOf, nodeOwner, wrapperOwner);
    if ("error" in owner) return owner;
    return {
      expiry: BigInt(expiry.result as bigint),
      registrant: owner.registrant,
    };
  });
}

/// Whether a v2 entry still holds a pre-migration reservation. A reservation outlives
/// its expiry by the v2 grace period: `ETHRenewerV1` still renews it and `ETHRegistrar`
/// still refuses to register it. The bonus period is sized so that this window closes
/// when v1's grace period does, so a name in the last weeks of its v1 grace reads
/// `AVAILABLE` on v2 while it still belongs to its v1 owner.
export function holdsReservation(
  state: { status: number; latestOwner: Address; expiry: bigint },
  now: bigint,
): boolean {
  return (
    state.status === STATUS.RESERVED ||
    (state.status === STATUS.AVAILABLE &&
      state.latestOwner === zeroAddress &&
      now - state.expiry < GRACE_PERIOD_V2)
  );
}

export function createFreshCheckpoint(): Checkpoint {
  return {
    lastProcessedLineNumber: -1,
    totalProcessed: 0,
    totalExpected: 0,
    successCount: 0,
    renewedCount: 0,
    failedLines: [],
    skippedCount: 0,
    skippedNeverRegisteredCount: 0,
    skippedPastGraceCount: 0,
    skippedGraveyardCount: 0,
    alreadyRegisteredCount: 0,
    upToDateCount: 0,
    invalidLabelCount: 0,
    timestamp: new Date().toISOString(),
  };
}

// Pre-migration specific logger
class PreMigrationLogger extends Logger {
  constructor() {
    super({
      infoLogFile: INFO_LOG_FILE,
      errorLogFile: ERROR_LOG_FILE,
      enableFileLogging: true,
    });
  }

  processingName(name: string, index: number, total: number): void {
    this.raw(
      cyan(`[${index}/${total}] Processing: ${bold(name)}.eth`),
      `[${index}/${total}] Processing: ${name}.eth`,
    );
  }

  finishedName(
    name: string,
    result: "reserved" | "renewed" | "skipped" | "failed",
  ): void {
    const icon =
      result === "reserved"
        ? "✓"
        : result === "renewed"
          ? "↻"
          : result === "skipped"
            ? "⊘"
            : "✗";
    const color =
      result === "reserved"
        ? green
        : result === "renewed"
          ? cyan
          : result === "skipped"
            ? yellow
            : red;
    this.raw(
      color(`${icon} Done: ${bold(name)}.eth`) + dim(` (${result})`),
      `${icon} Done: ${name}.eth (${result})`,
    );
  }

  reserving(name: string, expiry: string): void {
    this.raw(
      blue(`  → Reserving on v2`) + dim(` (expires: ${expiry})`),
      `  → Reserving on v2 (expires: ${expiry})`,
    );
  }

  reserved(tx: string): void {
    this.raw(
      green(`  → ✓ Reserved successfully`) + dim(` (tx: ${tx})`),
      `  → ✓ Reserved successfully (tx: ${tx})`,
    );
  }

  alreadyReserved(): void {
    this.raw(
      yellow(`  → ⊘ Already reserved by this migration`),
      `  → ⊘ Already reserved by this migration`,
    );
  }

  renewing(name: string, currentExpiry: string, newExpiry: string): void {
    this.raw(
      blue(`  → Renewing on v2`) +
        dim(` (current: ${currentExpiry}, new: ${newExpiry})`),
      `  → Renewing on v2 (current: ${currentExpiry}, new: ${newExpiry})`,
    );
  }

  renewed(tx: string): void {
    this.raw(
      green(`  → ✓ Renewed successfully`) + dim(` (tx: ${tx})`),
      `  → ✓ Renewed successfully (tx: ${tx})`,
    );
  }

  failed(name: string, error: string): void {
    this.rawError(
      red(`  → ✗ Failed:`) + dim(` ${error}`),
      `  → ✗ Failed: ${error}`,
    );
  }

  dryRun(): void {
    this.raw(
      dim(`  → [DRY RUN] Simulated registration (no transaction sent)`),
      `  → [DRY RUN] Simulated registration (no transaction sent)`,
    );
  }

  progress(
    current: number,
    total: number,
    stats: {
      reserved: number;
      renewed: number;
      skipped: number;
      failed: number;
    },
  ): void {
    const percent = Math.round((current / total) * 100);
    this.raw(
      magenta(
        `Progress: ${bold(`${current}/${total}`)} (${percent}%) - ` +
          `${green("Reserved: " + stats.reserved)}, ` +
          `${cyan("Renewed: " + stats.renewed)}, ` +
          `${yellow("Skipped: " + stats.skipped)}, ` +
          `${red("Failed: " + stats.failed)}`,
      ),
      `Progress: ${current}/${total} (${percent}%) - Reserved: ${stats.reserved}, Renewed: ${stats.renewed}, Skipped: ${stats.skipped}, Failed: ${stats.failed}`,
    );
  }

  verifyingV1(name: string): void {
    this.raw(
      dim(`  → Checking v1 status for ${name}.eth...`),
      `  → Checking v1 status for ${name}.eth...`,
    );
  }

  v1Verified(name: string, expiry: string): void {
    this.raw(
      green(`  → ✓ Verified on v1`) + dim(` (expires: ${expiry})`),
      `  → ✓ Verified on v1 (expires: ${expiry})`,
    );
  }

  v1NotRegistered(name: string, reason: string): void {
    this.raw(
      yellow(`  → ⊘ Not claimable on v1: ${reason}`),
      `  → ⊘ Not claimable on v1: ${reason}`,
    );
  }

  skippingInvalidName(domainName: string): void {
    this.raw(
      yellow(`  → ⊘ Skipping: ${bold(domainName)}`) +
        dim(` (invalid label name)`),
      `  → ⊘ Skipping: ${domainName} (invalid label name)`,
    );
  }
}

const logger = new PreMigrationLogger();

// Checkpoint management
export function loadCheckpoint(
  path: string = CHECKPOINT_FILE,
): Checkpoint | null {
  if (!existsSync(path)) {
    return null;
  }

  try {
    const data = readFileSync(path, "utf-8");
    // Spread over a fresh checkpoint so counters added after an older run was
    // written default to 0 rather than undefined (which would break `count++`).
    return { ...createFreshCheckpoint(), ...JSON.parse(data) };
  } catch (error) {
    logger.error(`Failed to load checkpoint: ${error}`);
    return null;
  }
}

export function saveCheckpoint(checkpoint: Checkpoint): void {
  try {
    writeFileSync(CHECKPOINT_FILE, JSON.stringify(checkpoint, null, 2));
  } catch (error) {
    logger.error(`Failed to save checkpoint: ${error}`);
  }
}

// Removes any checkpoint left in the work directory so a fresh run cannot
// inherit stale counts from a previous one. A run that processes zero batches
// writes no new checkpoint, so without this a lingering file would otherwise be
// mistaken for this run's result by anything that reads the checkpoint after.
export function clearCheckpoint(path: string = CHECKPOINT_FILE): void {
  try {
    rmSync(path, { force: true });
  } catch (error) {
    logger.error(`Failed to clear checkpoint: ${error}`);
  }
}

// v1 verification
interface V1VerificationResult {
  isRegistered: boolean;
  expiry: bigint;
}

/// Largest expiry the registry can store, since expiries are `uint64`.
export const MAX_UINT64 = 2n ** 64n - 1n;

/// The v2 expiry a v1 name should end up with: its v1 expiry plus the bonus period,
/// capped at what the registry can store.
///
/// Some names carry a deliberately maximal v1 expiry, so the sum can run past
/// `uint64`. Pre-migration writes the capped value, so anything checking the result
/// has to compute it the same way — otherwise those names read as permanent expiry
/// mismatches and no reconciliation over them can ever pass.
export function bonusAdjustedExpiry(
  v1Expiry: bigint,
  bonusPeriodSeconds: bigint,
): bigint {
  const raw = v1Expiry + bonusPeriodSeconds;
  return raw > MAX_UINT64 ? MAX_UINT64 : raw;
}

// Renders an expiry as a date for logging. Expiries near the uint64 ceiling are far
// outside the range `Date` can represent, and letting one of those throw would abort
// the whole run over a log line, so they are described rather than formatted.
export function formatExpiry(expiry: bigint): string {
  const milliseconds = Number(expiry) * 1000;
  if (!Number.isFinite(milliseconds) || Math.abs(milliseconds) > 8.64e15) {
    return `${expiry} (beyond representable dates)`;
  }
  return new Date(milliseconds).toISOString().split("T")[0];
}

// Chain time on the v1 side, which is what the grace-period rule is actually about.
// Wall-clock time only agrees with it on a live network: against a fork pinned to a
// past block it runs ahead, marking names released that the chain still holds in
// grace, and against a fork that has time-travelled it runs behind.
/// Chain time on the side a rule is about: v1 for the grace-period rule, v2 for
/// whether a reservation still holds.
///
/// The error is not caught: substituting wall-clock time changes which names count as
/// claimable, and on a fork pinned to a past block it marks names released that the
/// chain still holds. A failed read has to be a failed run.
async function readChainTimestamp(client: any): Promise<bigint> {
  const block = await client.getBlock();
  return BigInt(block.timestamp);
}

/// Days added to a v1 expiry to reach the expected v2 expiry.
///
/// A value that will not parse is an error rather than a silent default: every name
/// in the run gets its v2 expiry from this, so a typo would seed the whole set
/// against the wrong bonus.
function parseBonusPeriodDays(value: string | undefined): number {
  if (value === undefined || value === "") return 62;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(
      `--bonus-period-days must be a non-negative number, got: ${JSON.stringify(value)}`,
    );
  }
  return parsed;
}

export async function verifyNameOnV1(
  labelName: string,
  client: any,
  baseRegistrarAddress: Address = BASE_REGISTRAR_ADDRESS,
): Promise<V1VerificationResult> {
  if (!isValidLabel(labelName)) {
    throw new InvalidLabelNameError(labelName);
  }

  const tokenId = keccak256(toHex(labelName));

  const expiry = await client.readContract({
    address: baseRegistrarAddress,
    abi: BASE_REGISTRAR_ABI,
    functionName: "nameExpires",
    args: [tokenId],
  });

  const currentTimestamp = await readChainTimestamp(client);
  const isRegistered = expiry > 0n && expiry > currentTimestamp;

  return { isRegistered, expiry };
}

async function validateBatchRegistrar(
  client: any,
  address: Address,
): Promise<void> {
  const code = await client.getCode({ address });
  if (!code || code === "0x") {
    throw new Error(
      `No contract deployed at BatchRegistrar address: ${address}`,
    );
  }
  logger.success(`Using BatchRegistrar at ${address}`);
}

const CSV_ROW_PREVIEW_LIMIT = 200;
const UTF8_BOM = "﻿";

function previewCSVLine(line: string): string {
  return line.length <= CSV_ROW_PREVIEW_LIMIT
    ? line
    : `${line.slice(0, CSV_ROW_PREVIEW_LIMIT)}...`;
}

// `onlyLines` restricts the walk to specific data-line numbers, which is how a
// resumed run retries just the rows that failed. The file is still streamed, but no
// row outside the set is parsed or verified — a retry must not re-read the chain for
// every name that already succeeded, and must not trip over a malformed row it was
// never asked about.
async function* readCSVInBatches(
  csvFilePath: string,
  batchSize: number,
  startLineNumber: number = -1,
  limit: number | null = null,
  onlyLines: ReadonlySet<number> | null = null,
): AsyncGenerator<ENSRegistration[]> {
  const readline = await import("node:readline");

  const fileStream = createReadStream(csvFilePath);
  const rl = readline.createInterface({
    input: fileStream,
    crlfDelay: Infinity,
  });

  let dataLineNumber = 0;
  let processedCount = 0;
  let batch: ENSRegistration[] = [];

  let rawLineNumber = 0;
  let headerParsed = false;
  let labelColumnIndex = -1;
  let expectedColumnCount = 0;
  let pendingBlankLineNumber: number | null = null;

  for await (const rawLine of rl) {
    rawLineNumber++;

    let line = rawLine;
    if (rawLineNumber === 1 && line.startsWith(UTF8_BOM)) {
      line = line.slice(UTF8_BOM.length);
    }

    if (!headerParsed) {
      let headerFields: string[];
      try {
        headerFields = parseCSVLine(line);
      } catch {
        throw new CSVFormatError(
          `CSV header at ${csvFilePath}:1 has unbalanced quotes. Row: ${previewCSVLine(line)}`,
        );
      }

      const normalized = headerFields.map((f) => f.trim().toLowerCase());
      const labelNameIdx = normalized.indexOf("labelname");
      const labelIdx = normalized.indexOf("label");
      const resolvedIdx = labelNameIdx !== -1 ? labelNameIdx : labelIdx;
      if (resolvedIdx === -1) {
        const found = headerFields.map((f) => f.trim()).join(", ");
        throw new CSVFormatError(
          `CSV header at ${csvFilePath}:1 has no "labelName" or "label" column. ` +
            `Found columns: [${found}]. ` +
            `Expected one of "labelName" or "label" (case-insensitive).`,
        );
      }
      labelColumnIndex = resolvedIdx;
      expectedColumnCount = headerFields.length;
      headerParsed = true;
      continue;
    }

    if (dataLineNumber <= startLineNumber) {
      if (line !== "") {
        dataLineNumber++;
      }
      continue;
    }

    if (onlyLines !== null && !onlyLines.has(dataLineNumber)) {
      if (line !== "") {
        dataLineNumber++;
      }
      continue;
    }

    if (limit !== null && processedCount >= limit) {
      break;
    }

    if (line === "") {
      if (pendingBlankLineNumber === null) {
        pendingBlankLineNumber = rawLineNumber;
      } else {
        throw new CSVFormatError(
          `CSV row at ${csvFilePath}:${pendingBlankLineNumber} is blank. ` +
            `Blank lines are only tolerated at end of file.`,
        );
      }
      continue;
    }

    if (pendingBlankLineNumber !== null) {
      throw new CSVFormatError(
        `CSV row at ${csvFilePath}:${pendingBlankLineNumber} is blank. ` +
          `Blank lines are only tolerated at end of file.`,
      );
    }

    let parts: string[];
    try {
      parts = parseCSVLine(line);
    } catch {
      throw new CSVFormatError(
        `CSV row at ${csvFilePath}:${rawLineNumber} has unbalanced quotes. ` +
          `Row: ${previewCSVLine(line)}`,
      );
    }

    if (parts.length !== expectedColumnCount) {
      throw new CSVFormatError(
        `CSV row at ${csvFilePath}:${rawLineNumber} has ${parts.length} columns ` +
          `but header declared ${expectedColumnCount}. ` +
          `Row: ${previewCSVLine(line)}`,
      );
    }

    const labelName = csvLabelCell(parts, labelColumnIndex);
    if (labelName === undefined) {
      throw new CSVFormatError(
        `CSV row at ${csvFilePath}:${rawLineNumber} has empty "labelName". ` +
          `Row: ${previewCSVLine(line)}`,
      );
    }

    batch.push({ labelName, lineNumber: dataLineNumber });
    processedCount++;

    if (batch.length >= batchSize) {
      yield batch;
      batch = [];
    }

    dataLineNumber++;
  }

  if (!headerParsed) {
    throw new CSVFormatError(
      `CSV file at ${csvFilePath} is empty (no header row).`,
    );
  }

  if (batch.length > 0) {
    yield batch;
  }
}

/// The label in a parsed CSV row, exactly as written, or `undefined` when the cell is
/// empty or holds only whitespace. v1 accepts labels with leading or trailing spaces,
/// so trimming the cell would name a different label from the one registered.
export function csvLabelCell(
  fields: readonly string[],
  labelIndex: number,
): string | undefined {
  const label = fields[labelIndex];
  return label?.trim() ? label : undefined;
}

export function parseCSVLine(line: string): string[] {
  const result: string[] = [];
  let current = "";
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const char = line[i];

    if (char === '"') {
      if (inQuotes && line[i + 1] === '"') {
        current += '"';
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (char === "," && !inQuotes) {
      result.push(current);
      current = "";
    } else {
      current += char;
    }
  }

  if (inQuotes) {
    throw new Error("unbalanced quotes");
  }

  result.push(current);
  return result;
}

interface MigrationClients {
  client: any;
  mainnetClient: any;
  batchRegistrar: any;
  registryAbi: any[];
  v1Contracts: V1Contracts;
}

async function createMigrationClients(
  config: PreMigrationConfig,
): Promise<MigrationClients> {
  const v2Chain = await resolveChain(config.rpcUrl, RPC_TIMEOUT_MS);

  const account = config.privateKey
    ? privateKeyToAccount(config.privateKey)
    : config.account;
  if (!account) {
    throw new Error(
      "Missing signer: provide --private-key, PREMIGRATION_PRIVATE_KEY, or --account",
    );
  }

  const client = createWalletClient({
    account,
    chain: v2Chain,
    transport: http(config.rpcUrl, { retryCount: 0, timeout: RPC_TIMEOUT_MS }),
  }).extend(publicActions);

  const mainnetClient = createPublicClient({
    chain: mainnet,
    transport: http(config.mainnetRpcUrl, {
      retryCount: 0,
      timeout: RPC_TIMEOUT_MS,
    }),
  });

  const registryArtifact = loadArtifact("PermissionedRegistry");

  await validateBatchRegistrar(client, config.batchRegistrarAddress);
  const v1Contracts = await resolveV1Contracts(
    mainnetClient,
    config.graveyards,
    config.v1BaseRegistrarAddress,
  );

  const batchRegistrarArtifact = loadArtifact("BatchRegistrar");
  const batchRegistrar = getContract({
    address: config.batchRegistrarAddress,
    abi: batchRegistrarArtifact.abi,
    client,
  });

  return {
    client,
    mainnetClient,
    batchRegistrar,
    registryAbi: registryArtifact.abi,
    v1Contracts,
  };
}

async function fetchAndReserveInBatches(
  config: PreMigrationConfig,
  checkpoint: Checkpoint,
): Promise<void> {
  const { client, mainnetClient, batchRegistrar, registryAbi, v1Contracts } =
    await createMigrationClients(config);

  const block = await client.getBlock();
  const sender: BatchSender = {
    batchRegistrar,
    client,
    resolver: config.v1ResolverAddress,
    maxGas: BigInt(
      Math.floor(Number(block.gasLimit) * GAS_LIMIT_SAFETY_FACTOR),
    ),
    maxGasPrice: resolveMaxGasPrice(config.maxGasPrice, client.chain.id),
  };
  logger.config("Block Gas Limit", block.gasLimit.toString());
  logger.config("Max Gas Per Batch", sender.maxGas.toString());
  logger.config(
    "Max Gas Price",
    sender.maxGasPrice === null
      ? "none"
      : `${formatGwei(sender.maxGasPrice)} gwei` +
          (config.maxGasPrice === undefined ? " (mainnet default)" : ""),
  );

  // The retry pass and the main scan differ only in which rows they read. A retried
  // row was already counted and already capped by an earlier run, so only the main
  // scan grows the expected total or answers to --limit.
  const walk = async (
    batches: AsyncGenerator<ENSRegistration[]>,
    mainPass: boolean,
  ): Promise<void> => {
    for await (const batch of batches) {
      try {
        if (mainPass) checkpoint.totalExpected += batch.length;
        const countedBefore = checkpoint.totalProcessed;

        let invalidLabelsInBatch = 0;
        let lastInvalidLineNumber = checkpoint.lastProcessedLineNumber;
        const validBatch = batch.filter((reg) => {
          if (!isValidLabel(reg.labelName)) {
            logger.skippingInvalidName(reg.labelName || "unknown");
            invalidLabelsInBatch++;
            checkpoint.invalidLabelCount++;
            checkpoint.totalProcessed++;
            // A row that can never be reserved is not an outstanding failure, so a
            // retry of it leaves the queue rather than sitting in it forever.
            checkpoint.failedLines = checkpoint.failedLines.filter(
              (line) => line !== reg.lineNumber,
            );
            lastInvalidLineNumber = Math.max(
              lastInvalidLineNumber,
              reg.lineNumber,
            );
            return false;
          }
          return true;
        });

        if (invalidLabelsInBatch > 0) {
          checkpoint.lastProcessedLineNumber = lastInvalidLineNumber;
          if (!config.disableCheckpoint) {
            saveCheckpoint(checkpoint);
          }
        }

        logger.info(
          `\nRead ${batch.length} names from CSV (${invalidLabelsInBatch} invalid labels filtered). ` +
            `Starting reservation of ${validBatch.length} valid names...`,
        );

        if (validBatch.length > 0) {
          checkpoint = await processBatch(
            config,
            validBatch,
            client,
            mainnetClient,
            v1Contracts,
            sender,
            checkpoint,
            registryAbi,
          );
        }
        // A retried row was counted when it first failed, so settling its outcome
        // must not count it again.
        if (!mainPass) {
          checkpoint.totalProcessed = countedBefore;
          if (!config.disableCheckpoint) {
            saveCheckpoint(checkpoint);
          }
        }

        logger.info(
          `Batch complete. Total: ${checkpoint.totalProcessed} processed ` +
            `(${checkpoint.successCount} reserved, ${checkpoint.renewedCount} renewed, ` +
            `${checkpoint.skippedCount} skipped, ${checkpoint.invalidLabelCount} invalid, ` +
            `${checkpoint.failedLines.length} failed)`,
        );

        if (
          mainPass &&
          config.limit &&
          checkpoint.totalProcessed >= config.limit
        ) {
          logger.info(`\nReached limit of ${config.limit} names. Stopping.`);
          break;
        }
      } catch (error) {
        // A whole batch failing is a different class of problem than one bad name:
        // usually the RPC rather than the data, and none of its names were written.
        // The run stops here so the checkpoint still points *before* them — carrying
        // on would advance the resume cursor past rows that were never reserved, and
        // `--continue` would then skip them permanently.
        logger.error(
          `Failed to process batch: ${error}. The checkpoint still points before this batch; re-run with --continue once the cause is fixed.`,
        );
        throw error;
      }
    }
  };

  // Rows a previous run failed on are retried before the scan continues. They sit
  // behind the resume cursor, so nothing else would reach them, and a retry that
  // succeeds takes them out of the queue rather than leaving the run reporting a
  // failure it has since fixed.
  const retryLines = new Set(checkpoint.failedLines);
  if (retryLines.size > 0) {
    logger.info(
      `\nRetrying ${retryLines.size} name(s) that failed in an earlier run...`,
    );
    await walk(
      readCSVInBatches(
        config.csvFilePath,
        config.batchSize,
        -1,
        null,
        retryLines,
      ),
      false,
    );
  }

  logger.info(
    `\nReading CSV file and reserving in batches of ${config.batchSize}...`,
  );
  logger.info(`CSV file: ${config.csvFilePath}`);

  await walk(
    readCSVInBatches(
      config.csvFilePath,
      config.batchSize,
      config.startIndex,
      config.limit,
    ),
    true,
  );

  printFinalSummary(checkpoint);
}

export interface VerificationResult {
  registration: ENSRegistration;
  v2Status: number;
  v2LatestOwner: string;
  /// Whether the name is a candidate for migration, and why not when it is not; see
  /// `v1Eligibility`. The v2 expiry is computed separately by adding the configurable
  /// `--bonus-period-days`. Null when the lookup failed.
  v1Eligibility: V1Eligibility | null;
  v1Expiry: bigint;
  /// The v1 registrant, or null when v1 has no live registration for the name.
  v1Registrant: Address | null;
  /// Current expiry recorded on v2, or 0 when the name has no v2 entry. Used to tell
  /// a reservation that needs extending from one that is already long enough.
  v2Expiry: bigint;
  /// Whether v2 still holds a reservation for the name, including one past its
  /// expiry but inside the v2 grace period.
  v2Reserved: boolean;
  error?: string;
}

export async function batchVerifyRegistrations(
  registrations: ENSRegistration[],
  client: any,
  mainnetClient: any,
  registryAddress: Address,
  registryAbi: any[],
  v1Contracts: V1Contracts,
  graveyards: ReadonlySet<Address>,
): Promise<VerificationResult[]> {
  const ids = registrations.map((r) => BigInt(keccak256(toHex(r.labelName))));
  const v2Contracts = ids.map((id) => ({
    address: registryAddress,
    abi: registryAbi,
    functionName: "getState" as const,
    args: [id],
  }));

  const [v2Settled, v1Settled] = await Promise.allSettled([
    client.multicall({ contracts: v2Contracts }),
    readV1Registrations(mainnetClient, v1Contracts, ids),
  ]);

  const buildFallback = (reason: unknown) =>
    registrations.map(() => ({ status: "failure" as const, error: reason }));

  if (v2Settled.status === "rejected") {
    logger.warning(
      `v2 multicall failed for batch of ${registrations.length}: ${v2Settled.reason}`,
    );
  }
  if (v1Settled.status === "rejected") {
    logger.warning(
      `v1 multicall failed for batch of ${registrations.length}: ${v1Settled.reason}`,
    );
  }

  const v2Results =
    v2Settled.status === "fulfilled"
      ? v2Settled.value
      : buildFallback(v2Settled.reason);
  const v1Results: Array<V1Registration | V1ReadError> =
    v1Settled.status === "fulfilled"
      ? v1Settled.value
      : registrations.map(() => ({ error: String(v1Settled.reason) }));

  const [v1Now, v2Now] = await Promise.all([
    readChainTimestamp(mainnetClient),
    readChainTimestamp(client),
  ]);

  return registrations.map((reg, i) => {
    const v2 = (v2Results as any[])[i];
    const v1 = (v1Results as any[])[i];

    if (v2.status === "failure" || "error" in v1) {
      return {
        registration: reg,
        v2Status: -1,
        v2LatestOwner: zeroAddress,
        v1Eligibility: null,
        v1Expiry: 0n,
        v1Registrant: null,
        v2Expiry: 0n,
        v2Reserved: false,
        error: v2.status === "failure" ? String(v2.error) : v1.error,
      };
    }

    const state = v2.result as any;
    const v2Expiry = BigInt(state.expiry ?? 0);
    return {
      registration: reg,
      v2Status: state.status,
      v2LatestOwner: state.latestOwner,
      v2Expiry,
      v2Reserved: holdsReservation(
        {
          status: state.status,
          latestOwner: state.latestOwner,
          expiry: v2Expiry,
        },
        v2Now,
      ),
      v1Eligibility: v1Eligibility(v1, v1Now, graveyards),
      v1Expiry: v1.expiry,
      v1Registrant: v1.registrant,
    };
  });
}

/// The median mainnet gas price, each block's base fee plus its median priority fee,
/// over the two weeks before this default was set. Unless a run sets its own limit,
/// mainnet sends wait while the market price is above it. Measure it again when the
/// market has moved.
export const DEFAULT_MAX_GAS_PRICE = parseGwei("0.146");

// How long a paused run waits before reading the gas price again: about one mainnet
// block. It is also the wait before a failed read is first tried again.
const GAS_PRICE_POLL_INTERVAL_MS = 12_000;

// The tip is a median over a few recent blocks, so one unusual block cannot decide it.
const GAS_PRICE_SAMPLE_BLOCKS = 5;

// How often a long wait, for the gas price or for a transaction to be mined, is
// reported.
const WAIT_REPORT_INTERVAL_MS = 5 * 60_000;

/// Parses `--max-gas-price`, given in gwei, for a command line.
///
/// Zero is refused: on a chain that charges for gas, the run would never send.
export function parseMaxGasPrice(value: string): bigint {
  let wei: bigint;
  try {
    wei = parseGwei(value);
  } catch {
    throw new InvalidArgumentError(
      `not an amount in gwei: ${JSON.stringify(value)}`,
    );
  }
  if (wei <= 0n) {
    throw new InvalidArgumentError(
      `must be more than 0 gwei, got: ${JSON.stringify(value)}`,
    );
  }
  return wei;
}

/// The gas price limit a run sends under, or null when it has none.
///
/// A limit that was set applies on any chain. Without one, mainnet takes
/// `DEFAULT_MAX_GAS_PRICE` and other chains have no limit, since a mainnet median
/// says nothing about another chain's gas market.
export function resolveMaxGasPrice(
  option: bigint | undefined,
  chainId: number,
): bigint | null {
  return option ?? (chainId === mainnet.id ? DEFAULT_MAX_GAS_PRICE : null);
}

/// Each block's gas price in a fee history: its base fee plus the first reward
/// percentile asked for. A fee history's base fees run one entry past its last block,
/// to the next block's, which has no reward and is left out.
export function blockGasPrices(history: FeeHistory): bigint[] {
  return (history.reward ?? []).map(
    (reward, i) => history.baseFeePerGas[i] + reward[0],
  );
}

function median(values: readonly bigint[]): bigint {
  const sorted = [...values].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const mid = sorted.length >> 1;
  return sorted.length % 2 === 1
    ? sorted[mid]
    : (sorted[mid - 1] + sorted[mid]) / 2n;
}

/// What a transaction sent now would pay per unit of gas, and the tip within that.
export interface GasPriceReading {
  price: bigint;
  tip: bigint;
}

/// The gas price a transaction sent now would pay, read from the last few blocks.
///
/// The tip is the median of their median tips: what blocks paid, not the tip the RPC
/// suggests, which differs between providers by more than the limit itself. The base
/// fee is the higher of the latest block's and the next block's. The next block's is
/// what the transaction pays when it is mined at once. The latest block's counts too,
/// because the gas estimate made before sending checks the fee cap against it.
export async function readGasPrice(client: any): Promise<GasPriceReading> {
  const history: FeeHistory = await client.getFeeHistory({
    blockCount: GAS_PRICE_SAMPLE_BLOCKS,
    blockTag: "latest",
    rewardPercentiles: [50],
  });
  const tips = (history.reward ?? []).map((reward) => reward[0]);
  if (tips.length === 0) {
    throw new Error("the fee history holds no block rewards");
  }
  const [latest, next] = history.baseFeePerGas.slice(-2);
  const tip = median(tips);
  return { price: (latest > next ? latest : next) + tip, tip };
}

/// Fees a send passes on: a cap at the gas price limit and the market tip, or none,
/// which leaves them to viem.
export type GasFees = { maxFeePerGas?: bigint; maxPriorityFeePerGas?: bigint };

function formatWait(milliseconds: number): string {
  return milliseconds < 60_000
    ? `${Math.round(milliseconds / 1000)}s`
    : `${Math.round(milliseconds / 60_000)} min`;
}

// Makes a read until it is answered. A pause lasts until the gas price comes back
// down, so an outage of the RPC has to be waited out rather than end the run. Each
// failure is logged, and the wait before the next try doubles, up to the report
// interval.
async function readUntilAnswered<T>(
  what: string,
  read: () => Promise<T>,
  firstRetryDelayMs: number,
): Promise<T> {
  for (let failures = 0; ; failures++) {
    try {
      return await read();
    } catch (error) {
      const delay = Math.min(
        firstRetryDelayMs * 2 ** Math.min(failures, 10),
        WAIT_REPORT_INTERVAL_MS,
      );
      logger.warning(
        `Could not read ${what} (${failures + 1} in a row); trying again in ${formatWait(delay)}: ${error}`,
      );
      await sleep(delay);
    }
  }
}

/// Waits until the market gas price is at or below `maxGasPrice`, and returns the fees
/// to send with: a cap at the limit and the market tip, so the transaction never pays
/// more than the limit per unit of gas. Returns no fees, at once, when there is no
/// limit.
///
/// The returned tip is at or below the cap, as a transaction requires, since the tip
/// is part of a price found to be within the limit.
///
/// There is no time limit: the wait lasts until the price comes back down, however
/// long that takes. A read that fails is tried again until it is answered.
export async function waitForGasPriceAtOrBelow(
  client: any,
  maxGasPrice: bigint | null,
  pollIntervalMs: number = GAS_PRICE_POLL_INTERVAL_MS,
): Promise<GasFees> {
  if (maxGasPrice === null) return {};
  const limit = `${formatGwei(maxGasPrice)} gwei limit`;
  let pausedAt: number | null = null;
  let reportedAt = 0;
  for (;;) {
    const reading = await readUntilAnswered(
      "the gas price",
      () => readGasPrice(client),
      pollIntervalMs,
    );
    const now = Date.now();
    const current = `${formatGwei(reading.price)} gwei`;
    if (reading.price <= maxGasPrice) {
      if (pausedAt !== null) {
        logger.info(
          `Gas price ${current} is at or below the ${limit}; resuming after ${formatWait(now - pausedAt)}.`,
        );
      }
      return { maxFeePerGas: maxGasPrice, maxPriorityFeePerGas: reading.tip };
    }
    if (pausedAt === null) {
      pausedAt = reportedAt = now;
      logger.warning(
        `Gas price ${current} is above the ${limit}; pausing until it drops.`,
      );
    } else if (now - reportedAt >= WAIT_REPORT_INTERVAL_MS) {
      reportedAt = now;
      logger.info(
        `Still paused after ${formatWait(now - pausedAt)}: gas price ${current} is above the ${limit}.`,
      );
    }
    await sleep(pollIntervalMs);
  }
}

// The receipt of the first of these transactions that was mined, or null when none was.
async function firstReceipt(
  client: any,
  hashes: readonly Hex[],
): Promise<TransactionReceipt | null> {
  for (const hash of hashes) {
    try {
      return await client.getTransactionReceipt({ hash });
    } catch (error) {
      if (!(error instanceof TransactionReceiptNotFoundError)) throw error;
    }
  }
  return null;
}

/// Waits for one of the transactions sent for a batch to be mined, however long that
/// takes, and returns its receipt. Returns null when none was mined and the node no
/// longer holds the latest: it was dropped, and the batch has to wait for the gas
/// price and be sent again.
///
/// A transaction capped at the gas price limit is not mined while the base fee is
/// above the cap. It waits in the node's pool until the base fee falls, which is part
/// of the pause the limit asks for, and a node may drop it from its pool meanwhile. A
/// transaction mined late is not a failure: splitting its batch would send the names
/// again while it could still be mined.
///
/// The latest send is watched, and every report interval each send of the batch is
/// checked, since an earlier one may be mined instead of the latest. A read that fails
/// is tried again until it is answered.
export async function waitForInclusion(
  client: any,
  hashes: readonly Hex[],
  firstRetryDelayMs: number = GAS_PRICE_POLL_INTERVAL_MS,
): Promise<TransactionReceipt | null> {
  const latest = hashes[hashes.length - 1];
  const sentAt = Date.now();
  for (;;) {
    const mined = await readUntilAnswered(
      "the transaction receipt",
      async () => {
        try {
          return await client.waitForTransactionReceipt({
            hash: latest,
            checkReplacement: false,
            timeout: WAIT_REPORT_INTERVAL_MS,
          });
        } catch (error) {
          if (error instanceof WaitForTransactionReceiptTimeoutError) {
            return null;
          }
          throw error;
        }
      },
      firstRetryDelayMs,
    );
    if (mined) return mined;
    const earlier = await readUntilAnswered(
      "the batch's transaction receipts",
      () => firstReceipt(client, hashes),
      firstRetryDelayMs,
    );
    if (earlier) return earlier;
    const held = await readUntilAnswered(
      "the pending transaction",
      async () => {
        try {
          await client.getTransaction({ hash: latest });
          return true;
        } catch (error) {
          if (error instanceof TransactionNotFoundError) return false;
          throw error;
        }
      },
      firstRetryDelayMs,
    );
    if (!held) return null;
    logger.info(
      `Transaction ${latest} is not mined yet after ${formatWait(Date.now() - sentAt)}; still waiting.`,
    );
  }
}

/// What sending a batch needs besides the names and their expiries.
export interface BatchSender {
  batchRegistrar: any;
  client: any;
  /// Fallback resolver every reserved name is given.
  resolver: Address;
  /// Most gas a batch may be estimated at before it is split.
  maxGas: bigint;
  /// Gas price a send waits to be at or below, and caps its fee at; null when there
  /// is no limit.
  maxGasPrice: bigint | null;
}

export interface BatchSubmitResult {
  succeeded: { label: string; txHash: string }[];
  failed: { label: string; error: string }[];
}

// Runs `submit` on each half of a batch in turn and combines what it reports.
async function eachHalf(
  labels: string[],
  expires: bigint[],
  submit: (labels: string[], expires: bigint[]) => Promise<BatchSubmitResult>,
): Promise<BatchSubmitResult> {
  const mid = Math.ceil(labels.length / 2);
  const left = await submit(labels.slice(0, mid), expires.slice(0, mid));
  const right = await submit(labels.slice(mid), expires.slice(mid));
  return {
    succeeded: [...left.succeeded, ...right.succeeded],
    failed: [...left.failed, ...right.failed],
  };
}

// Records a single name that could not be reserved, or sends each half of a failed
// batch in turn.
async function splitFailedBatch(
  sender: BatchSender,
  labels: string[],
  expires: bigint[],
  error: unknown,
): Promise<BatchSubmitResult> {
  const errorMsg = error instanceof Error ? error.message : String(error);
  if (labels.length <= 1) {
    return {
      succeeded: [],
      failed: [{ label: labels[0], error: errorMsg }],
    };
  }
  const mid = Math.ceil(labels.length / 2);
  logger.warning(
    `Batch of ${labels.length} failed: ${errorMsg}. Splitting into ${mid} + ${labels.length - mid}...`,
  );
  return eachHalf(labels, expires, (half, halfExpires) =>
    submitBatchWithBinaryFallback(sender, half, halfExpires),
  );
}

/// Sends a batch and, when it fails, each half of it in turn, down to single names,
/// so one name that cannot be reserved does not hold back the rest.
///
/// Each send first waits for the gas price to be within the limit, and its fee is
/// capped at the limit. If the base fee rises past the cap between that check and the
/// send, the send is refused and the batch waits again instead of being split: nothing
/// is wrong with its names.
///
/// The gas price wait and the wait for the transaction to be mined sit outside the
/// error handling that splits a batch, and neither has a time limit. A batch whose
/// transaction was dropped before it was mined is sent again once the price allows,
/// not split: nothing is wrong with its names. If sending it again is refused for any
/// reason other than a revert, an earlier send is still pending somewhere, so the
/// batch goes back to waiting on that one.
///
/// A batch that waits is sent with what was read before the wait. That stays safe:
/// nothing but pre-migration writes the v2 registry while it runs, a v1 renewal made
/// meanwhile is picked up by the final sync, and a name whose v1 grace ends meanwhile
/// gets an expiry already past the v2 grace, so it reads as available.
export async function submitBatchWithBinaryFallback(
  sender: BatchSender,
  labels: string[],
  expires: bigint[],
): Promise<BatchSubmitResult> {
  const { batchRegistrar, client } = sender;
  const sent: Hex[] = [];
  for (;;) {
    const fees = await waitForGasPriceAtOrBelow(client, sender.maxGasPrice);
    try {
      sent.push(
        await batchRegistrar.write.batchRegister(
          [zeroAddress, sender.resolver, labels, expires],
          fees,
        ),
      );
    } catch (error) {
      if (sender.maxGasPrice !== null && hasCause(error, FeeCapTooLowError)) {
        logger.warning(
          `The base fee rose past the ${formatGwei(sender.maxGasPrice)} gwei fee cap before the batch was sent; waiting again.`,
        );
        continue;
      }
      if (sent.length === 0 || isRevert(error)) {
        return splitFailedBatch(sender, labels, expires, error);
      }
      logger.warning(
        `Could not send the batch again (${error instanceof BaseError ? error.shortMessage : String(error)}); waiting on its earlier transaction.`,
      );
    }
    const receipt = await waitForInclusion(client, sent);
    if (receipt === null) {
      logger.warning(
        `Transaction ${sent[sent.length - 1]} was dropped before it was mined; the batch will be sent again once the gas price allows.`,
      );
      continue;
    }
    if (receipt.status !== "success") {
      return splitFailedBatch(
        sender,
        labels,
        expires,
        new Error(`transaction ${receipt.transactionHash} reverted`),
      );
    }
    return {
      succeeded: labels.map((label) => ({
        label,
        txHash: receipt.transactionHash,
      })),
      failed: [],
    };
  }
}

const GAS_LIMIT_SAFETY_FACTOR = 0.8;

// Only the estimate is guarded: an error from a send has to reach the caller, not be
// mistaken for a failed estimate and sent again.
async function estimateAndSplitBatch(
  sender: BatchSender,
  labels: string[],
  expires: bigint[],
): Promise<BatchSubmitResult> {
  const { maxGas } = sender;
  let estimatedGas: bigint;
  try {
    estimatedGas = await sender.batchRegistrar.estimateGas.batchRegister([
      zeroAddress,
      sender.resolver,
      labels,
      expires,
    ]);
  } catch {
    logger.warning(
      `Gas estimation failed for batch of ${labels.length}, using binary-search fallback`,
    );
    return await submitBatchWithBinaryFallback(sender, labels, expires);
  }

  if (estimatedGas <= maxGas) {
    return await submitBatchWithBinaryFallback(sender, labels, expires);
  }

  if (labels.length <= 1) {
    const msg = `single registration exceeds gas limit (${estimatedGas} > ${maxGas})`;
    logger.warning(`Label ${labels[0]}: ${msg}`);
    return {
      succeeded: [],
      failed: [{ label: labels[0], error: msg }],
    };
  }

  logger.warning(
    `Batch of ${labels.length} estimated at ${estimatedGas} gas (limit: ${maxGas}). Splitting...`,
  );
  return eachHalf(labels, expires, (half, halfExpires) =>
    estimateAndSplitBatch(sender, half, halfExpires),
  );
}

async function processBatch(
  config: PreMigrationConfig,
  registrations: ENSRegistration[],
  client: any,
  mainnetClient: any,
  v1Contracts: V1Contracts,
  sender: BatchSender,
  checkpoint: Checkpoint,
  registryAbi: any[],
): Promise<Checkpoint> {
  const batchLabels: string[] = [];
  const batchExpires: bigint[] = [];
  // Submission failures come back keyed by label, but the retry queue works in CSV
  // lines, so the two have to be joined back up.
  const lineByLabel = new Map<string, number>();
  const alreadyReservedNames = new Set<string>();
  let lastLineNumber = checkpoint.lastProcessedLineNumber;
  // A failure means nothing was written to v2, so the line is queued for retry: a
  // resumed run reaches it again instead of stepping over it and leaving the name
  // missing with nothing to report it later.
  const failedLines = new Set(checkpoint.failedLines);
  const recordFailedLine = (lineNumber: number) => {
    failedLines.add(lineNumber);
  };
  // A row that succeeds, is skipped, or turns out to need nothing done stops being a
  // failure, so a retry that works clears the entry the earlier run left behind.
  const clearFailedLine = (lineNumber: number) => {
    failedLines.delete(lineNumber);
  };

  const bonusPeriodSeconds = BigInt(config.bonusPeriodDays) * 86400n;

  const verificationResults = await batchVerifyRegistrations(
    registrations,
    client,
    mainnetClient,
    config.registryAddress,
    registryAbi,
    v1Contracts,
    config.graveyards,
  );

  const baseProcessed = checkpoint.totalProcessed;
  for (let i = 0; i < verificationResults.length; i++) {
    const result = verificationResults[i];
    const registration = result.registration;
    const globalIndex = baseProcessed + i + 1;
    lastLineNumber = registration.lineNumber;

    logger.processingName(
      registration.labelName,
      globalIndex,
      checkpoint.totalExpected,
    );

    // One bad name must never take the whole run down with it. Every failure
    // mode below is handled explicitly, but an unforeseen one — a value that
    // overflows a conversion, a malformed record — would otherwise abort a
    // multi-hour pre-migration partway through. It is recorded and skipped.
    try {
      if (result.error || result.v1Eligibility === null) {
        logger.failed(registration.labelName, result.error ?? "no v1 result");
        checkpoint.totalProcessed++;
        recordFailedLine(registration.lineNumber);
        logger.finishedName(registration.labelName, "failed");
        continue;
      }

      if (result.v2Status === STATUS.REGISTERED) {
        logger.error(
          `Name ${registration.labelName}.eth is already registered with owner: ${result.v2LatestOwner}`,
        );
        checkpoint.alreadyRegisteredCount++;
        checkpoint.totalProcessed++;
        clearFailedLine(registration.lineNumber);
        logger.finishedName(registration.labelName, "failed");
        continue;
      }
      if (result.v2Reserved) {
        alreadyReservedNames.add(registration.labelName);
      }

      const eligibility = result.v1Eligibility;
      if (eligibility !== "claimable") {
        const reason = V1_INELIGIBILITY_REASONS[eligibility];
        logger.v1NotRegistered(
          registration.labelName,
          eligibility === "graveyard"
            ? `${reason} (${result.v1Registrant})`
            : reason,
        );
        checkpoint.skippedCount++;
        if (eligibility === "never-registered") {
          checkpoint.skippedNeverRegisteredCount++;
        } else if (eligibility === "past-grace") {
          checkpoint.skippedPastGraceCount++;
        } else {
          checkpoint.skippedGraveyardCount++;
        }
        checkpoint.totalProcessed++;
        clearFailedLine(registration.lineNumber);
        logger.finishedName(registration.labelName, "skipped");
        continue;
      }

      const effectiveExpiry = bonusAdjustedExpiry(
        result.v1Expiry,
        bonusPeriodSeconds,
      );

      // A reservation is only renewed on-chain when the new expiry is longer than the
      // stored one; submitting an equal or shorter one does nothing. Leaving such
      // names out of the batch keeps the counters honest and keeps the final sync from
      // re-sending the entire CSV when almost nothing has changed.
      if (result.v2Reserved && effectiveExpiry <= result.v2Expiry) {
        checkpoint.upToDateCount++;
        checkpoint.totalProcessed++;
        clearFailedLine(registration.lineNumber);
        logger.finishedName(registration.labelName, "skipped");
        continue;
      }

      logger.v1Verified(registration.labelName, formatExpiry(effectiveExpiry));

      batchLabels.push(registration.labelName);
      batchExpires.push(effectiveExpiry);
      lineByLabel.set(registration.labelName, registration.lineNumber);
    } catch (error) {
      logger.failed(registration.labelName, String(error));
      checkpoint.totalProcessed++;
      recordFailedLine(registration.lineNumber);
      logger.finishedName(registration.labelName, "failed");
    }
  }

  if (batchLabels.length > 0 && !config.dryRun) {
    logger.info(`\n → Batch reserving ${batchLabels.length} names...\n`);

    const result = await estimateAndSplitBatch(
      sender,
      batchLabels,
      batchExpires,
    );

    for (const { label, txHash } of result.succeeded) {
      checkpoint.totalProcessed++;
      const succeededLine = lineByLabel.get(label);
      if (succeededLine !== undefined) clearFailedLine(succeededLine);
      if (alreadyReservedNames.has(label)) {
        checkpoint.renewedCount++;
        logger.renewed(txHash);
        logger.finishedName(label, "renewed");
      } else {
        checkpoint.successCount++;
        logger.reserved(txHash);
        logger.finishedName(label, "reserved");
      }
    }

    for (const { label, error } of result.failed) {
      logger.failed(label, error);
      checkpoint.totalProcessed++;
      const lineNumber = lineByLabel.get(label);
      if (lineNumber !== undefined) recordFailedLine(lineNumber);
      logger.finishedName(label, "failed");
    }
  } else if (batchLabels.length > 0 && config.dryRun) {
    logger.info(`\nDry run: Would batch reserve ${batchLabels.length} names`);

    for (const label of batchLabels) {
      logger.dryRun();
      checkpoint.totalProcessed++;
      const plannedLine = lineByLabel.get(label);
      if (plannedLine !== undefined) clearFailedLine(plannedLine);
      if (alreadyReservedNames.has(label)) {
        checkpoint.renewedCount++;
        logger.finishedName(label, "renewed");
      } else {
        checkpoint.successCount++;
        logger.finishedName(label, "reserved");
      }
    }
  }

  // The cursor is a plain high-water mark. Failed rows are not held behind it —
  // they are carried in the retry queue instead, which survives the batches that
  // follow them and so cannot be overwritten by a later clean batch.
  checkpoint.lastProcessedLineNumber = Math.max(
    checkpoint.lastProcessedLineNumber,
    lastLineNumber,
  );
  checkpoint.failedLines = [...failedLines].sort((a, b) => a - b);
  checkpoint.timestamp = new Date().toISOString();

  if (!config.disableCheckpoint) {
    saveCheckpoint(checkpoint);
  }

  return checkpoint;
}

function calculateSuccessRate(
  successCount: number,
  totalAttempts: number,
): number {
  return totalAttempts > 0
    ? Math.round((successCount / totalAttempts) * 100)
    : 0;
}

function printFinalSummary(checkpoint: Checkpoint): void {
  const failureCount = checkpoint.failedLines.length;
  const actualRegistrations =
    checkpoint.successCount + checkpoint.renewedCount + failureCount;

  logger.info("");
  logger.divider();
  logger.header("Pre-Migration Complete");
  logger.divider();

  logger.config("Total names processed", checkpoint.totalProcessed);
  logger.config(
    "Successfully reserved",
    green(checkpoint.successCount.toString()),
  );
  logger.config(
    "Successfully renewed",
    cyan(checkpoint.renewedCount.toString()),
  );
  logger.config(
    "Skipped (not claimable on v1)",
    yellow(checkpoint.skippedCount.toString()),
  );
  logger.config(
    "  → never registered on v1",
    yellow(checkpoint.skippedNeverRegisteredCount.toString()),
  );
  logger.config(
    "  → expired past v1 grace period",
    yellow(checkpoint.skippedPastGraceCount.toString()),
  );
  logger.config(
    "  → v1 registrant is a Graveyard",
    yellow(checkpoint.skippedGraveyardCount.toString()),
  );
  logger.config(
    "Already registered on v2",
    yellow(checkpoint.alreadyRegisteredCount.toString()),
  );
  logger.config(
    "Already up to date on v2",
    yellow(checkpoint.upToDateCount.toString()),
  );
  logger.config(
    "Invalid labels",
    yellow(checkpoint.invalidLabelCount.toString()),
  );
  logger.config(
    "Failed (other errors)",
    failureCount > 0 ? red(failureCount.toString()) : failureCount,
  );
  logger.config("Actual reservations/renewals attempted", actualRegistrations);

  const rate = calculateSuccessRate(
    checkpoint.successCount + checkpoint.renewedCount,
    actualRegistrations,
  );
  if (actualRegistrations > 0) {
    logger.config("Success rate", `${rate}%`);
  }

  logger.divider();

  if (failureCount > 0) {
    logger.warning(
      `\nSome registrations failed. Check ${ERROR_LOG_FILE} for details.`,
    );
  }
}

export async function main(argv = process.argv): Promise<void> {
  let failedNames = 0;
  const program = new Command()
    .name("premigrate")
    .description(
      "Pre-migrate ENS .eth 2LDs from v1 to v2 on Ethereum mainnet. By default starts fresh. Use --continue to resume from checkpoint.",
    )
    .requiredOption("--rpc-url <url>", "Ethereum mainnet RPC endpoint")
    .requiredOption("--registry <address>", "v2 ETH Registry contract address")
    .requiredOption(
      "--batch-registrar <address>",
      "Pre-deployed BatchRegistrar contract address",
    )
    .option(
      "--private-key <key>",
      "Deployer private key (default: PREMIGRATION_PRIVATE_KEY env var)",
    )
    .option(
      "--account <address>",
      "Impersonated or unlocked BatchRegistrar owner account",
    )
    .requiredOption(
      "--csv-file <path>",
      "Path to CSV file containing ENS registrations",
    )
    .option(
      "--mainnet-rpc-url <url>",
      "Mainnet RPC endpoint for v1 verification (default: public endpoint)",
      "https://eth.drpc.org",
    )
    .option(
      "--batch-size <number>",
      "Number of names to process per batch",
      "50",
    )
    .option(
      "--start-index <number>",
      "Starting index for resuming partial migrations",
      "-1",
    )
    .option(
      "--limit <number>",
      "Maximum total number of names to process and register",
    )
    .option("--dry-run", "Simulate without executing transactions", false)
    .option(
      "--continue",
      "Continue from previous checkpoint if it exists",
      false,
    )
    .option(
      "--bonus-period-days <days>",
      "Days added to each name's v1 expiry to compute its v2 expiry",
      "62",
    )
    .requiredOption(
      "--v1-resolver <address>",
      "ENSV1Resolver address deployed on v2 for fallback resolution",
    )
    .option(
      "--v1-base-registrar <address>",
      "V1 BaseRegistrar address for expiry lookups",
      BASE_REGISTRAR_ADDRESS,
    )
    .requiredOption(
      "--graveyards <addresses>",
      "Comma-separated Graveyard addresses, superseded deployments' included; v1 names any of them holds are not reserved",
      parseGraveyardAddresses,
    )
    .option(
      "--max-gas-price <gwei>",
      "Wait to send while the gas price (base fee plus median tip) is above this many gwei (default on mainnet: the median mainnet price; none elsewhere)",
      parseMaxGasPrice,
    );

  program.parse(argv);
  const opts = program.opts();

  const privateKey = (opts.privateKey ??
    process.env.PREMIGRATION_PRIVATE_KEY) as `0x${string}` | undefined;
  const account = opts.account as Address | undefined;
  if (!privateKey && !account) {
    console.error(
      "Error: signer must be provided via --private-key, PREMIGRATION_PRIVATE_KEY, or --account",
    );
    process.exit(1);
  }

  const config: PreMigrationConfig = {
    rpcUrl: opts.rpcUrl,
    mainnetRpcUrl: opts.mainnetRpcUrl,
    registryAddress: opts.registry as Address,
    batchRegistrarAddress: opts.batchRegistrar as Address,
    privateKey,
    account,
    csvFilePath: opts.csvFile,
    batchSize: parseInt(opts.batchSize) || 100,
    startIndex: parseInt(opts.startIndex) || 0,
    limit: opts.limit ? parseInt(opts.limit) : null,
    dryRun: opts.dryRun,
    continue: opts.continue,
    // A dry run reads the checkpoint but never clears or saves it. Saving would move
    // the resume cursor past rows nothing was sent for and drop them from the retry
    // queue, so a later real `--continue` would skip them for good.
    disableCheckpoint: opts.dryRun,
    bonusPeriodDays: parseBonusPeriodDays(opts.bonusPeriodDays),
    v1ResolverAddress: opts.v1Resolver as Address,
    v1BaseRegistrarAddress: opts.v1BaseRegistrar as Address,
    graveyards: graveyardSet(opts.graveyards as Address[]),
    maxGasPrice: opts.maxGasPrice as bigint | undefined,
  };

  try {
    logger.header("ENS Pre-Migration Script");
    logger.divider();

    logger.info(`Configuration:`);
    logger.config("RPC URL", config.rpcUrl);
    logger.config("Registry", config.registryAddress);
    logger.config("BatchRegistrar", config.batchRegistrarAddress);
    logger.config(
      "Signer Account",
      config.account ??
        (opts.privateKey ? "private key (CLI)" : "private key (env)"),
    );
    logger.config("Mainnet RPC (v1)", config.mainnetRpcUrl);
    logger.config("CSV File", config.csvFilePath);
    logger.config("Batch Size", config.batchSize);
    logger.config("Bonus Period Days", config.bonusPeriodDays);
    logger.config(
      "V1 Grace Period Days (hard-coded)",
      Number(V1_GRACE_PERIOD_DAYS),
    );
    logger.config("V1 Resolver", config.v1ResolverAddress);
    logger.config("Graveyards", [...config.graveyards].join(", "));
    logger.config("Limit", config.limit ?? "none");
    logger.config("Dry Run", config.dryRun);
    logger.config("Continue Mode", config.continue ?? false);

    let checkpoint = createFreshCheckpoint();
    if (config.continue) {
      const cp = loadCheckpoint();
      if (cp) {
        checkpoint = cp;
        config.startIndex = cp.lastProcessedLineNumber;
        logger.config(
          "Checkpoint Found",
          `${cp.totalProcessed} processed (${cp.successCount} reserved, ${cp.renewedCount} renewed, ${cp.skippedCount} skipped, ${cp.invalidLabelCount} invalid, ${cp.failedLines.length} failed) (last line: ${cp.lastProcessedLineNumber})`,
        );
        logger.info(`Resuming from CSV line ${config.startIndex}`);
      }
    } else if (!config.disableCheckpoint) {
      clearCheckpoint();
    }
    logger.info("");

    await fetchAndReserveInBatches(config, checkpoint);

    // A name that reverted or timed out was never written to v2. Reporting the run
    // as a success would hand the operator a green result over an incomplete
    // reservation set, so it is raised instead. Names already registered on v2 are
    // not failures: nothing was lost, there was simply nothing to do.
    failedNames = checkpoint.failedLines.length;

    if (failedNames === 0) {
      logger.success("\nPre-migration script completed successfully!");
    }
  } catch (error) {
    logger.error(`Fatal error: ${error}`);
    console.error(error);
    process.exit(1);
  }

  // Raised outside the catch so an in-process caller — the fork rehearsal runs this
  // in the same process — receives an error it can handle, rather than having the
  // whole run terminated by a process exit.
  if (failedNames > 0) {
    throw new FailedNamesError(failedNames);
  }
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
