#!/usr/bin/env bun

// Estimates what the initial pre-migration (phase 2 of the migration) costs on
// mainnet: the gas to reserve every claimable v1 `.eth` 2LD on v2, priced at the mean
// and the median gas price of recent mainnet blocks.
//
// The names come from the v1 registrar's own logs, read up to one pinned block. Its
// `NameRegistered` and `NameRenewed` events carry every expiry it has set, and the
// newest event of each name carries its current expiry. The registrar controllers'
// events carry the labels. The gas is measured on a local Anvil fork at the same
// block: the contracts pre-migration writes to are deployed there by the phase 1
// deploy scripts, and an evenly spread sample of the names is reserved through the
// send path pre-migration uses, in batches of the size it uses. The receipt gas per
// name is scaled up to every claimable name.
//
//   bun run premigration:cost -- --rpc-url <archive mainnet RPC>

import { Command, InvalidArgumentError, Option } from "commander";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  decodeAbiParameters,
  formatEther,
  formatGwei,
  getAddress,
  getContract,
  http,
  keccak256,
  parseAbiItem,
  publicActions,
  stringToBytes,
  toEventSelector,
  type AbiEvent,
  type Address,
  type FeeHistory,
  type Hex,
} from "viem";
import { mainnet } from "viem/chains";

import { LEGACY_ETH_REGISTRAR_CONTROLLER_ADDRESS } from "./forkBootstrap.js";
import {
  DEFAULT_ANVIL_DEPLOYER,
  deployV2,
  deploymentGraveyards,
  FORK_UPSTREAM_RETRIES,
  FORK_UPSTREAM_RETRY_BACKOFF_MS,
} from "./migrate.js";
import { isLogSpanRefusal } from "./migrations/logSpanRefusal.js";
import {
  DEFAULT_DEPLOYMENTS_DIR,
  NETWORKS,
  requireV1Deployment,
} from "./migrations/plumbing.js";
import {
  clearAccountDelegations,
  impersonate,
  setBalance,
  waitForRpc,
} from "./migrations/rpc.js";
import {
  type BatchSubmitResult,
  bonusAdjustedExpiry,
  blockGasPrices,
  DEFAULT_BATCH_SIZE,
  DEFAULT_BONUS_PERIOD_DAYS,
  DEFAULT_MAX_GAS_PRICE,
  graveyardSet,
  isClaimableOnV1,
  isValidLabel,
  median,
  readV1Registrations,
  resolveV1Contracts,
  submitBatchWithBinaryFallback,
  type V1Contracts,
  type V1Registration,
  type V1ReadError,
  v1Eligibility,
} from "./preMigration.js";
import { loadArtifact } from "./scriptUtils.js";

////////////////////////////////////////////////////////////////////////
// Mainnet v1
////////////////////////////////////////////////////////////////////////

/// The block the current `BaseRegistrar` was deployed at. Its history, and so every
/// registration it knows, starts here. The 2020 registrar migration registered every
/// name of the registrar before it again, so names older than this are covered too.
export const REGISTRAR_DEPLOY_BLOCK = 9_380_410n;

/// The `BaseRegistrar` events that set an expiry.
export const REGISTRAR_EVENTS = [
  parseAbiItem(
    "event NameRegistered(uint256 indexed id, address indexed owner, uint256 expires)",
  ),
  parseAbiItem("event NameRenewed(uint256 indexed id, uint256 expires)"),
] as const;

/// The registrar controller events that carry a plaintext label, in every shape the
/// mainnet controllers have emitted. Parameter names do not change an event's
/// selector, so each shape names its label `label` and its labelhash `labelhash`.
export const CONTROLLER_LABEL_EVENTS = [
  // The controller the 2020 registrar migration deployed.
  parseAbiItem(
    "event NameRegistered(string label, bytes32 indexed labelhash, address indexed owner, uint256 cost, uint256 expires)",
  ),
  // The controller that registers through the NameWrapper.
  parseAbiItem(
    "event NameRegistered(string label, bytes32 indexed labelhash, address indexed owner, uint256 baseCost, uint256 premium, uint256 expires)",
  ),
  // The current controller.
  parseAbiItem(
    "event NameRegistered(string label, bytes32 indexed labelhash, address indexed owner, uint256 baseCost, uint256 premium, uint256 expires, bytes32 referrer)",
  ),
  // Renewals through the first two.
  parseAbiItem(
    "event NameRenewed(string label, bytes32 indexed labelhash, uint256 cost, uint256 expires)",
  ),
  // Renewals through the current one.
  parseAbiItem(
    "event NameRenewed(string label, bytes32 indexed labelhash, uint256 cost, uint256 expires, bytes32 referrer)",
  ),
] as const;

const [NAME_REGISTERED_TOPIC, NAME_RENEWED_TOPIC] = REGISTRAR_EVENTS.map(
  (event) => toEventSelector(event),
);

// The unindexed parameters of each controller event, by selector. The label is the
// first of them in every shape.
const CONTROLLER_EVENT_DATA = new Map(
  (CONTROLLER_LABEL_EVENTS as readonly AbiEvent[]).map((event) => [
    toEventSelector(event),
    event.inputs.filter((input) => !input.indexed),
  ]),
);

const SCAN_TOPICS = [
  NAME_REGISTERED_TOPIC,
  NAME_RENEWED_TOPIC,
  ...CONTROLLER_EVENT_DATA.keys(),
];

/// The v1 contracts on mainnet, from the bundled deployment artifacts.
export function mainnetV1(): {
  contracts: V1Contracts;
  labelControllers: Address[];
} {
  const address = (name: string) =>
    getAddress(requireV1Deployment("mainnet", name).address);
  return {
    contracts: {
      baseRegistrar: address("BaseRegistrarImplementation"),
      registry: address("ENSRegistry"),
      nameWrapper: address("NameWrapper"),
    },
    labelControllers: [
      getAddress(LEGACY_ETH_REGISTRAR_CONTROLLER_ADDRESS),
      address("WrappedETHRegistrarController"),
      address("ETHRegistrarController"),
    ],
  };
}

////////////////////////////////////////////////////////////////////////
// Registrar history
////////////////////////////////////////////////////////////////////////

/// A log as `eth_getLogs` returns it.
export type RawLog = { address: string; topics: Hex[]; data: Hex };

/// What the registrar's history says about every name it has registered.
export type RegistrationScan = {
  /// Each name's current expiry, keyed by labelhash.
  expiries: Map<bigint, bigint>;
  /// Names whose newest registration was to a Graveyard: names `Graveyard.clear`
  /// took out of circulation.
  graveyardHeld: Set<bigint>;
  /// Plaintext labels a controller logged, keyed by labelhash. A label is kept only
  /// when it hashes to the labelhash logged beside it.
  labels: Map<bigint, string>;
  logs: number;
};

/// Reads the logs of one block range, oldest first.
export type LogReader = (
  fromBlock: bigint,
  toBlock: bigint,
) => Promise<RawLog[]>;

/// Walks the registrar's and controllers' logs from `fromBlock` to `toBlock`, oldest
/// first, so a name's newest event is the last one applied.
///
/// A provider caps a log query by block span, by result count, or both. A refused
/// range is halved and asked again, and a range that is accepted lets the next one
/// double, up to `maxSpan`, since the density of registrations varies by years. Any
/// other error ends the scan: a scan that stepped over a range would count too few
/// names.
export async function scanRegistrations(
  read: LogReader,
  opts: {
    registrar: Address;
    graveyards: ReadonlySet<Address>;
    fromBlock: bigint;
    toBlock: bigint;
    initialSpan: bigint;
    maxSpan?: bigint;
    onProgress?: (scan: RegistrationScan, scannedTo: bigint) => void;
  },
): Promise<RegistrationScan> {
  const scan: RegistrationScan = {
    expiries: new Map(),
    graveyardHeld: new Set(),
    labels: new Map(),
    logs: 0,
  };
  const registrar = opts.registrar.toLowerCase();
  // Logs carry addresses in lower case.
  const graveyards = new Set(
    [...opts.graveyards].map((address) => address.toLowerCase()),
  );
  const maxSpan = opts.maxSpan ?? opts.initialSpan * 16n;
  let span = opts.initialSpan;
  let from = opts.fromBlock;
  while (from <= opts.toBlock) {
    const to =
      from + span - 1n < opts.toBlock ? from + span - 1n : opts.toBlock;
    let logs: RawLog[];
    try {
      logs = await read(from, to);
    } catch (error) {
      if (!isLogSpanRefusal(error) || span === 1n) throw error;
      span /= 2n;
      continue;
    }
    for (const log of logs) applyLog(scan, log, registrar, graveyards);
    scan.logs += logs.length;
    opts.onProgress?.(scan, to);
    from = to + 1n;
    if (span < maxSpan) span *= 2n;
  }
  return scan;
}

// Reads the few fixed fields of each event directly: a full scan applies millions of
// logs, and a generic decoder spends most of its time finding the event again for
// each one.
function applyLog(
  scan: RegistrationScan,
  log: RawLog,
  registrar: string,
  graveyards: ReadonlySet<string>,
): void {
  const [topic, indexed, owner] = log.topics;
  if (log.address.toLowerCase() === registrar) {
    const registration = topic === NAME_REGISTERED_TOPIC;
    if (!registration && topic !== NAME_RENEWED_TOPIC) return;
    // A registrar event that does not have its shape is a name the scan would lose,
    // so it stops the scan instead.
    if (
      log.topics.length !== (registration ? 3 : 2) ||
      log.data.length !== 66
    ) {
      throw new Error(`undecodable registrar log: ${JSON.stringify(log)}`);
    }
    const id = BigInt(indexed);
    scan.expiries.set(id, BigInt(log.data));
    if (registration) {
      if (graveyards.has(`0x${owner.slice(26).toLowerCase()}`)) {
        scan.graveyardHeld.add(id);
      } else {
        scan.graveyardHeld.delete(id);
      }
    }
    return;
  }
  const params = CONTROLLER_EVENT_DATA.get(topic);
  if (params === undefined || indexed === undefined) return;
  let label: unknown;
  try {
    [label] = decodeAbiParameters(params, log.data);
  } catch {
    return;
  }
  // The label string is not otherwise bound to the indexed labelhash.
  if (typeof label !== "string") return;
  if (keccak256(stringToBytes(label)) !== indexed.toLowerCase()) return;
  scan.labels.set(BigInt(indexed), label);
}

/// Every labelhash the scan found, in ascending order, split by whether pre-migration
/// reserves the name at `now`.
export type ScanSummary = {
  /// Names the registrar has ever registered.
  distinct: number;
  /// Names pre-migration reserves.
  claimable: bigint[];
  /// Names whose expiry leaves them claimable but that a Graveyard holds.
  graveyardHeld: number;
  /// The claimable names with a label pre-migration accepts.
  labelled: bigint[];
};

export function summariseScan(
  scan: RegistrationScan,
  now: bigint,
): ScanSummary {
  const claimable: bigint[] = [];
  let graveyardHeld = 0;
  for (const [id, expiry] of scan.expiries) {
    if (!isClaimableOnV1(expiry, now)) continue;
    if (scan.graveyardHeld.has(id)) graveyardHeld++;
    else claimable.push(id);
  }
  claimable.sort(compareBigInt);
  const labelled = claimable.filter((id) => isValidLabel(scan.labels.get(id)));
  return {
    distinct: scan.expiries.size,
    claimable,
    graveyardHeld,
    labelled,
  };
}

function compareBigInt(a: bigint, b: bigint): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/// Up to `n` items spread evenly over the list, in order. Picked evenly rather than
/// at random so a run can be repeated. A list sorted by labelhash has no relation to
/// when a name was registered or how long its label is, so an even pick over it is
/// an unbiased sample.
export function pickEvenly<T>(items: readonly T[], n: number): T[] {
  if (n <= 0 || items.length === 0) return [];
  if (n >= items.length) return items.slice();
  const step = items.length / n;
  return Array.from({ length: n }, (_, i) => items[Math.floor(i * step)] as T);
}

/// Cross-checks a sample of the scan against the chain's own state at the same block,
/// through the reads and the eligibility rule pre-migration applies. Half the sample
/// is drawn from the claimable names and half from the rest, so a name counted by
/// mistake and a name missed by mistake both show. Any disagreement fails the run: a
/// scan that is wrong about some names cannot be trusted for the count.
export async function crossCheckScan(
  read: (ids: bigint[]) => Promise<Array<V1Registration | V1ReadError>>,
  scan: RegistrationScan,
  args: {
    now: bigint;
    graveyards: ReadonlySet<Address>;
    sample: number;
    chunkSize?: number;
  },
): Promise<number> {
  const claimable: bigint[] = [];
  const rest: bigint[] = [];
  for (const [id, expiry] of scan.expiries) {
    const counted =
      isClaimableOnV1(expiry, args.now) && !scan.graveyardHeld.has(id);
    (counted ? claimable : rest).push(id);
  }
  claimable.sort(compareBigInt);
  rest.sort(compareBigInt);
  const half = Math.ceil(args.sample / 2);
  const picks = [
    ...pickEvenly(claimable, half),
    ...pickEvenly(rest, args.sample - half),
  ];
  const chunkSize = args.chunkSize ?? 100;
  const mismatches: string[] = [];
  for (let i = 0; i < picks.length; i += chunkSize) {
    const ids = picks.slice(i, i + chunkSize);
    const results = await read(ids);
    ids.forEach((id, index) => {
      const result = results[index];
      const name = `0x${id.toString(16).padStart(64, "0")}`;
      if ("error" in result) {
        throw new Error(`could not read v1 state of ${name}: ${result.error}`);
      }
      const scanned = scan.expiries.get(id) ?? 0n;
      const counted =
        isClaimableOnV1(scanned, args.now) && !scan.graveyardHeld.has(id);
      const eligible =
        v1Eligibility(result, args.now, args.graveyards) === "claimable";
      if (result.expiry !== scanned || counted !== eligible) {
        mismatches.push(
          `${name}: logs say expiry ${scanned}${counted ? ", claimable" : ""}; chain says expiry ${result.expiry}${eligible ? ", claimable" : ""}`,
        );
      }
    });
  }
  if (mismatches.length > 0) {
    throw new Error(
      `the registrar logs disagree with the chain for ${mismatches.length} of ${picks.length} sampled names:\n` +
        mismatches.slice(0, 10).join("\n"),
    );
  }
  return picks.length;
}

////////////////////////////////////////////////////////////////////////
// Gas measurement
////////////////////////////////////////////////////////////////////////

export type MeasuredBatch = { names: number; gasUsed: bigint };

export type SampleMeasurement = {
  sampled: number;
  batches: MeasuredBatch[];
  failed: BatchSubmitResult["failed"];
};

/// Reserves the sample batch by batch through `submit`, and records the receipt gas of
/// each transaction it sent. Receipt gas includes a transaction's base cost and its
/// calldata, so it is the full cost a real run pays. A batch that pre-migration would
/// split is split here too, and each part is measured as the transaction it is.
export async function measureSample(
  names: ReadonlyArray<{ label: string; expiry: bigint }>,
  deps: {
    batchSize: number;
    submit(labels: string[], expires: bigint[]): Promise<BatchSubmitResult>;
    gasUsed(txHash: Hex): Promise<bigint>;
    onBatch?(done: number, total: number, measured: MeasuredBatch[]): void;
  },
): Promise<SampleMeasurement> {
  const batches: MeasuredBatch[] = [];
  const failed: BatchSubmitResult["failed"] = [];
  const total = Math.ceil(names.length / deps.batchSize);
  for (let i = 0; i < names.length; i += deps.batchSize) {
    const batch = names.slice(i, i + deps.batchSize);
    const result = await deps.submit(
      batch.map((name) => name.label),
      batch.map((name) => name.expiry),
    );
    const perTx = new Map<string, number>();
    for (const { txHash } of result.succeeded) {
      perTx.set(txHash, (perTx.get(txHash) ?? 0) + 1);
    }
    const measured: MeasuredBatch[] = [];
    for (const [txHash, count] of perTx) {
      measured.push({
        names: count,
        gasUsed: await deps.gasUsed(txHash as Hex),
      });
    }
    batches.push(...measured);
    failed.push(...result.failed);
    deps.onBatch?.(i / deps.batchSize + 1, total, measured);
  }
  return { sampled: names.length, batches, failed };
}

////////////////////////////////////////////////////////////////////////
// Fee history
////////////////////////////////////////////////////////////////////////

/// The most blocks one `eth_feeHistory` call may cover.
export const FEE_HISTORY_PAGE = 1024n;

const SECONDS_PER_DAY = 86_400n;

type FeeClient = {
  getBlock(args: { blockNumber: bigint }): Promise<{ timestamp: bigint }>;
  getFeeHistory(args: {
    blockCount: number;
    blockNumber: bigint;
    rewardPercentiles: number[];
  }): Promise<FeeHistory>;
};

/// The first block whose timestamp is at or after `timestamp`, up to `head`.
export async function blockAtOrAfter(
  client: Pick<FeeClient, "getBlock">,
  timestamp: bigint,
  head: bigint,
): Promise<bigint> {
  let lo = 0n;
  let hi = head;
  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    const block = await client.getBlock({ blockNumber: mid });
    if (block.timestamp < timestamp) lo = mid + 1n;
    else hi = mid;
  }
  return lo;
}

/// The gas price of each block in the `days` ending at `toBlock`, oldest first: its
/// base fee plus its median priority fee, the price pre-migration's gas price limit
/// is measured in. Paged through `eth_feeHistory` from the newest block back,
/// following what each page returns, since a provider may serve fewer blocks than
/// asked.
export async function fetchBlockGasPrices(
  client: FeeClient,
  args: { toBlock: bigint; days: number },
): Promise<bigint[]> {
  const end = await client.getBlock({ blockNumber: args.toBlock });
  const since = end.timestamp - BigInt(args.days) * SECONDS_PER_DAY;
  const fromBlock = await blockAtOrAfter(client, since, args.toBlock);
  const pages: bigint[][] = [];
  let newest = args.toBlock;
  while (newest >= fromBlock) {
    const want = newest - fromBlock + 1n;
    const history = await client.getFeeHistory({
      blockCount: Number(want < FEE_HISTORY_PAGE ? want : FEE_HISTORY_PAGE),
      blockNumber: newest,
      rewardPercentiles: [50],
    });
    const prices = blockGasPrices(history);
    if (prices.length === 0) {
      throw new Error(`eth_feeHistory returned no blocks up to ${newest}`);
    }
    pages.push(prices);
    newest = history.oldestBlock - 1n;
  }
  return pages.reverse().flat();
}

export type FeeSummary = { blocks: number; mean: bigint; median: bigint };

export function summariseFees(prices: readonly bigint[]): FeeSummary {
  if (prices.length === 0) throw new Error("no gas prices to summarise");
  const total = prices.reduce((sum, price) => sum + price, 0n);
  return {
    blocks: prices.length,
    mean: total / BigInt(prices.length),
    median: median(prices),
  };
}

////////////////////////////////////////////////////////////////////////
// Projection and report
////////////////////////////////////////////////////////////////////////

export type CostEstimate = {
  names: number;
  measuredNames: number;
  measuredTxs: number;
  failed: number;
  gasPerName: bigint;
  /// Half-width of a 95% interval on gas per name, from the spread between
  /// transactions; null with fewer than two.
  gasPerNameMargin: bigint | null;
  projectedTxs: number;
  projectedGas: bigint;
  fees: FeeSummary;
  costAtMean: bigint;
  costAtMedian: bigint;
  /// The most the run can pay under the gas price limit, which caps every
  /// transaction's fee.
  costAtLimit: bigint;
  limit: bigint;
};

/// Scales the gas the sample took up to `names` names sent `batchSize` at a time.
export function projectCost(args: {
  names: number;
  measurement: SampleMeasurement;
  fees: FeeSummary;
  batchSize: number;
  limit: bigint;
}): CostEstimate {
  const { batches, failed } = args.measurement;
  const measuredNames = batches.reduce((sum, batch) => sum + batch.names, 0);
  if (measuredNames === 0) {
    throw new Error("no sampled name was reserved; nothing to project");
  }
  const measuredGas = batches.reduce((sum, batch) => sum + batch.gasUsed, 0n);
  const projectedGas =
    (measuredGas * BigInt(args.names)) / BigInt(measuredNames);
  return {
    names: args.names,
    measuredNames,
    measuredTxs: batches.length,
    failed: failed.length,
    gasPerName: measuredGas / BigInt(measuredNames),
    gasPerNameMargin: marginOfError(batches),
    projectedTxs: Math.ceil(args.names / args.batchSize),
    projectedGas,
    fees: args.fees,
    costAtMean: projectedGas * args.fees.mean,
    costAtMedian: projectedGas * args.fees.median,
    costAtLimit: projectedGas * args.limit,
    limit: args.limit,
  };
}

function marginOfError(batches: readonly MeasuredBatch[]): bigint | null {
  if (batches.length < 2) return null;
  const perName = batches.map((batch) => Number(batch.gasUsed) / batch.names);
  const mean = perName.reduce((sum, x) => sum + x, 0) / perName.length;
  const variance =
    perName.reduce((sum, x) => sum + (x - mean) ** 2, 0) / (perName.length - 1);
  return BigInt(
    Math.round((1.96 * Math.sqrt(variance)) / Math.sqrt(perName.length)),
  );
}

export type ReportContext = {
  block: bigint;
  blockTime: bigint;
  distinct: number;
  graveyardHeld: number;
  labelled: number;
  batchSize: number;
  feeDays: number;
};

/// The report as a Markdown page.
export function formatReport(
  estimate: CostEstimate,
  context: ReportContext,
): string {
  const n = (x: number | bigint) => x.toLocaleString("en-US");
  const eth = (wei: bigint) =>
    Number(formatEther(wei)).toLocaleString("en-US", {
      maximumFractionDigits: 4,
    });
  const gwei = (wei: bigint) =>
    Number(formatGwei(wei)).toLocaleString("en-US", {
      maximumFractionDigits: 3,
    });
  const days = `${context.feeDays} day${context.feeDays === 1 ? "" : "s"}`;
  const date = new Date(Number(context.blockTime) * 1000).toISOString();
  const margin =
    estimate.gasPerNameMargin === null
      ? ""
      : ` ± ${n(estimate.gasPerNameMargin)} (95%)`;
  const graveyards =
    context.graveyardHeld === 0
      ? ""
      : `; ${n(context.graveyardHeld)} held by a Graveyard left out`;
  const rows: Array<[string, string]> = [
    [
      "Names to reserve",
      `${n(estimate.names)} claimable of ${n(context.distinct)} ever registered${graveyards}`,
    ],
    [
      "Labels known",
      `${n(context.labelled)} of the ${n(estimate.names)} from controller logs; the sample is drawn from these`,
    ],
    [
      "Sample reserved",
      `${n(estimate.measuredNames)} names in ${n(estimate.measuredTxs)} txs; ${n(estimate.failed)} failed`,
    ],
    ["Gas per name", `${n(estimate.gasPerName)}${margin}, all-in`],
    [
      "Projected",
      `${n(estimate.projectedTxs)} txs of ${n(context.batchSize)} names, ${n(estimate.projectedGas)} gas`,
    ],
    [
      `Gas price (${days})`,
      `mean ${gwei(estimate.fees.mean)} gwei, median ${gwei(estimate.fees.median)} gwei over ${n(estimate.fees.blocks)} blocks`,
    ],
    [
      "**Cost**",
      `**${eth(estimate.costAtMean)} ETH** at the mean price (${eth(estimate.costAtMedian)} ETH at the median)`,
    ],
    [
      "Gas price limit",
      `sends wait while the price is above ${gwei(estimate.limit)} gwei, so the run pays at most ${eth(estimate.costAtLimit)} ETH`,
    ],
  ];
  return [
    "# Cost of the initial pre-migration on mainnet",
    "",
    `Estimated at block ${n(context.block)} (${date}) by \`bun run premigration:cost\`.`,
    "",
    "| | |",
    "|---|---|",
    ...rows.map(([label, value]) => `| ${label} | ${value} |`),
    "",
    "## Method",
    "",
    "The names are every .eth 2LD that pre-migration reserves at the block: its v1 expiry",
    "plus the 90-day grace period lies after the block, and no Graveyard holds it. They are",
    "rebuilt from the registrar's `NameRegistered` and `NameRenewed` logs, whose newest",
    "event per name carries its expiry, and a sample of them is checked against the chain.",
    "The v2 contracts pre-migration writes to were deployed on an Anvil fork at the block by",
    "the phase 1 deploy scripts. An evenly spread sample of the names was reserved there",
    "through pre-migration's own send path, in batches of its size. Gas per name is receipt",
    "gas over names reserved, so it includes each transaction's base cost and calldata. The",
    "projection scales it to every name to reserve and prices it at the mean and the median",
    `of base fee plus median priority fee over the ${days} of blocks before the block.`,
    "",
  ].join("\n");
}

////////////////////////////////////////////////////////////////////////
// Command line
////////////////////////////////////////////////////////////////////////

type Args = {
  rpcUrl: string;
  block?: bigint;
  sample: number;
  checkSample: number;
  batchSize: number;
  feeDays: number;
  logSpan: bigint;
  graveyards?: Address[];
  port: number;
  report?: string;
};

function positiveInt(value: string): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new InvalidArgumentError(`not a positive integer: ${value}`);
  }
  return parsed;
}

function parseArgs(argv: string[]): Args {
  const program = new Command()
    .name("premigration:cost")
    .description(
      "Estimate the ETH cost of the initial pre-migration on mainnet at the mean and median gas price of recent blocks",
    )
    .addOption(
      new Option(
        "--rpc-url <url>",
        "Mainnet archive RPC; it must serve eth_getLogs over the registrar's history",
      ).env("MAINNET_RPC_URL"),
    )
    .option("--block <number>", "Block to estimate at (default: latest)")
    .addOption(
      new Option(
        "--sample <count>",
        "Names reserved on the fork to measure gas",
      )
        .default(5000)
        .argParser(positiveInt),
    )
    .addOption(
      new Option(
        "--check-sample <count>",
        "Names whose scanned expiry is checked against the chain",
      )
        .default(1000)
        .argParser(positiveInt),
    )
    .addOption(
      new Option("--batch-size <count>", "Names per batchRegister transaction")
        .default(DEFAULT_BATCH_SIZE)
        .argParser(positiveInt),
    )
    .addOption(
      new Option(
        "--fee-days <days>",
        "Days of blocks the gas price is averaged over",
      )
        .default(14)
        .argParser(positiveInt),
    )
    .addOption(
      new Option(
        "--log-span <blocks>",
        "Blocks per eth_getLogs call to start with; narrowed when the RPC refuses",
      )
        .default(50_000)
        .argParser(positiveInt),
    )
    .option(
      "--graveyards <addresses>",
      "Comma-separated Graveyard addresses whose names are left out (default: those in the mainnet deployment artifacts, if any)",
    )
    .addOption(
      new Option("--port <port>", "Local port for the Anvil fork")
        .default(8549)
        .argParser(positiveInt),
    )
    .option("--report <path>", "Also save the report as a Markdown file here")
    .parse(argv);
  const opts = program.opts();
  if (!opts.rpcUrl) {
    program.error("--rpc-url or MAINNET_RPC_URL is required");
  }
  return {
    rpcUrl: opts.rpcUrl,
    block: opts.block === undefined ? undefined : BigInt(opts.block),
    sample: opts.sample,
    checkSample: opts.checkSample,
    batchSize: opts.batchSize,
    feeDays: opts.feeDays,
    logSpan: BigInt(opts.logSpan),
    graveyards:
      opts.graveyards === undefined
        ? undefined
        : [...graveyardSet(String(opts.graveyards).split(","))],
    port: opts.port,
    report: opts.report,
  };
}

// The Graveyards on mainnet: the ones given, or else those the deployment artifacts
// record. Before v2 is deployed on mainnet there are none.
function mainnetGraveyards(given: Address[] | undefined): Address[] {
  if (given !== undefined) return given;
  if (!existsSync(join(DEFAULT_DEPLOYMENTS_DIR, "mainnet", "Graveyard.json"))) {
    return [];
  }
  return deploymentGraveyards({
    network: "mainnet",
    deploymentsDir: DEFAULT_DEPLOYMENTS_DIR,
  });
}

const progress = (message: string) => process.stderr.write(`${message}\n`);

async function main(argv = process.argv): Promise<void> {
  const args = parseArgs(argv);
  // Stdout carries only the report. The deploy code this reuses logs with
  // console.log, so that goes to stderr with the progress lines.
  console.log = console.error;
  if (!Bun.which("anvil")) {
    throw new Error("anvil is not on PATH; install Foundry first");
  }
  const upstream = createPublicClient({
    chain: mainnet,
    transport: http(args.rpcUrl, {
      retryCount: 5,
      retryDelay: 1_000,
      timeout: 120_000,
    }),
  });
  const chainId = await upstream.getChainId();
  if (chainId !== mainnet.id) {
    throw new Error(
      `the RPC serves chain ${chainId}; this estimate is for mainnet`,
    );
  }
  const block = args.block ?? (await upstream.getBlockNumber());
  const { timestamp: now } = await upstream.getBlock({ blockNumber: block });
  const v1 = mainnetV1();
  const graveyards = new Set(mainnetGraveyards(args.graveyards));
  // Reads pinned to the block, so they describe the same state as the scan.
  const pinned = {
    multicall: (call: object) =>
      upstream.multicall({ ...call, blockNumber: block } as any),
    readContract: (call: object) =>
      upstream.readContract({ ...call, blockNumber: block } as any),
    call: (call: object) =>
      upstream.call({ ...call, blockNumber: block } as any),
  };
  if (graveyards.size > 0) {
    await resolveV1Contracts(pinned, graveyards, v1.contracts.baseRegistrar);
  }
  progress(
    `estimating at block ${block}; ${graveyards.size === 0 ? "no Graveyard on mainnet" : `Graveyards ${[...graveyards].join(", ")}`}`,
  );

  const forkUrl = `http://127.0.0.1:${args.port}`;
  const anvil = Bun.spawn(
    [
      "anvil",
      "--fork-url",
      args.rpcUrl,
      "--fork-block-number",
      String(block),
      "--port",
      String(args.port),
      "--retries",
      String(FORK_UPSTREAM_RETRIES),
      "--fork-retry-backoff",
      String(FORK_UPSTREAM_RETRY_BACKOFF_MS),
      "--silent",
    ],
    { stdout: "ignore", stderr: "inherit" },
  );
  const stop = () => anvil.kill();
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => {
      stop();
      process.exit(signal === "SIGINT" ? 130 : 143);
    });
  }
  const workDir = mkdtempSync(join(tmpdir(), "premigration-cost-"));
  try {
    await waitForRpc(forkUrl, mainnet);
    // Deployed first, so a deploy that fails does so before the long scan.
    const fork = await deployOnFork(forkUrl, workDir);

    progress(`reading ${args.feeDays} days of fee history`);
    const prices = await fetchBlockGasPrices(upstream, {
      toBlock: block,
      days: args.feeDays,
    });

    progress(
      `scanning registrar logs from block ${REGISTRAR_DEPLOY_BLOCK} to ${block}`,
    );
    const scan = await scanRegistrations(
      async (fromBlock, toBlock) =>
        (await upstream.request({
          method: "eth_getLogs",
          params: [
            {
              address: [v1.contracts.baseRegistrar, ...v1.labelControllers],
              fromBlock: `0x${fromBlock.toString(16)}`,
              toBlock: `0x${toBlock.toString(16)}`,
              topics: [SCAN_TOPICS],
            },
          ],
        })) as RawLog[],
      {
        registrar: v1.contracts.baseRegistrar,
        graveyards,
        fromBlock: REGISTRAR_DEPLOY_BLOCK,
        toBlock: block,
        initialSpan: args.logSpan,
        onProgress: scanProgress(REGISTRAR_DEPLOY_BLOCK, block),
      },
    );
    const summary = summariseScan(scan, now);
    progress(
      `scan: ${scan.logs} logs, ${summary.distinct} names, ${summary.claimable.length} claimable, ${summary.labelled.length} of them labelled`,
    );

    const checked = await crossCheckScan(
      (ids) => readV1Registrations(pinned, v1.contracts, ids),
      scan,
      { now, graveyards, sample: args.checkSample },
    );
    progress(`cross-check: ${checked} sampled names agree with the chain`);

    const bonus = BigInt(DEFAULT_BONUS_PERIOD_DAYS) * SECONDS_PER_DAY;
    const sample = pickEvenly(summary.labelled, args.sample).map((id) => ({
      label: scan.labels.get(id) as string,
      expiry: bonusAdjustedExpiry(scan.expiries.get(id) as bigint, bonus),
    }));
    // The scan holds every name ever registered; only the sample is needed now.
    scan.expiries.clear();
    scan.labels.clear();
    progress(`reserving ${sample.length} sampled names on the fork`);
    const measurement = await measureSample(sample, {
      batchSize: args.batchSize,
      submit: fork.submit,
      gasUsed: fork.gasUsed,
      onBatch: (done, total, measured) => {
        const described = measured
          .map((tx) => `${tx.names} names, ${tx.gasUsed} gas`)
          .join("; ");
        progress(`  batch ${done}/${total}: ${described || "nothing sent"}`);
      },
    });
    for (const { label, error } of measurement.failed) {
      progress(`  failed to reserve ${label}: ${error}`);
    }

    const estimate = projectCost({
      names: summary.claimable.length,
      measurement,
      fees: summariseFees(prices),
      batchSize: args.batchSize,
      limit: DEFAULT_MAX_GAS_PRICE,
    });
    const report = formatReport(estimate, {
      block,
      blockTime: now,
      distinct: summary.distinct,
      graveyardHeld: summary.graveyardHeld,
      labelled: summary.labelled.length,
      batchSize: args.batchSize,
      feeDays: args.feeDays,
    });
    process.stdout.write(report);
    if (args.report !== undefined) {
      mkdirSync(dirname(args.report), { recursive: true });
      writeFileSync(args.report, report);
      progress(`saved the report to ${args.report}`);
    }
  } finally {
    stop();
    rmSync(workDir, { recursive: true, force: true });
  }
}

function scanProgress(fromBlock: bigint, toBlock: bigint) {
  const total = toBlock - fromBlock + 1n;
  const started = Date.now();
  let nextPercent = 5n;
  return (scan: RegistrationScan, scannedTo: bigint) => {
    const percent = ((scannedTo - fromBlock + 1n) * 100n) / total;
    if (percent < nextPercent) return;
    nextPercent = percent + 5n;
    const minutes = Math.round((Date.now() - started) / 60_000);
    progress(
      `  ${percent}% (block ${scannedTo}, ${minutes} min): ${scan.logs} logs, ${scan.expiries.size} names, ${scan.labels.size} labels`,
    );
  };
}

// Deploys the contracts pre-migration writes to on the fork, with the phase 1 deploy
// scripts, and returns how to send a batch the way pre-migration does.
async function deployOnFork(forkUrl: string, deploymentsDir: string) {
  const client = createPublicClient({
    chain: mainnet,
    transport: http(forkUrl),
  });
  const deployer = getAddress(DEFAULT_ANVIL_DEPLOYER);
  const owner = getAddress(NETWORKS.mainnet.defaultOwner);
  await setBalance(client, deployer);
  await impersonate(client, owner);
  // The deploy mints the `.eth` token to the deployer, which a delegated account on
  // the forked chain would refuse.
  await clearAccountDelegations(client, [
    { address: deployer, label: "deployer" },
  ]);
  progress("deploying the v2 registry and BatchRegistrar on the fork");
  const env = await deployV2({
    network: "mainnet",
    rpcUrl: forkUrl,
    chainId: String(mainnet.id),
    deploymentsDir,
    deploymentNetwork: "mainnet-premigration-cost",
    saveDeployments: false,
    tags: ["BatchRegistrar", "ENSV1Resolver"],
    deployer,
    owner,
    v1Owner: owner,
    urManager: deployer,
  });
  const wallet = createWalletClient({
    account: deployer,
    chain: mainnet,
    transport: http(forkUrl),
  }).extend(publicActions);
  const sender = {
    batchRegistrar: getContract({
      address: env.get("BatchRegistrar").address,
      abi: loadArtifact("BatchRegistrar").abi,
      client: wallet,
    }),
    client: wallet,
    resolver: env.get("ENSV1Resolver").address as Address,
    // Only the gas estimate that splits an oversized batch reads this, and the sample
    // is sent without it: a batch of pre-migration's size is far below the limit.
    maxGas: 0n,
    // The fork mines only when a transaction arrives, so its gas price never falls:
    // the sample is sent without waiting for it.
    maxGasPrice: null,
  };
  return {
    submit: (labels: string[], expires: bigint[]) =>
      submitBatchWithBinaryFallback(sender, labels, expires),
    gasUsed: async (hash: Hex) =>
      (await wallet.getTransactionReceipt({ hash })).gasUsed,
  };
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
