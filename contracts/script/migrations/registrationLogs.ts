// Reads the v1 `.eth` registrar's history from chain logs: the `BaseRegistrar` events
// that set an expiry, and the registrar controllers' events that carry each label in
// plain text.

import {
  decodeAbiParameters,
  getAddress,
  keccak256,
  parseAbiItem,
  stringToBytes,
  toEventSelector,
  type AbiEvent,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";

import { LEGACY_ETH_REGISTRAR_CONTROLLER_ADDRESS } from "../forkBootstrap.js";
import { isLogSpanRefusal } from "./logSpanRefusal.js";
import {
  loadV1Deployment,
  type MigrationNetwork,
  requireV1Deployment,
  type V1DeploymentOptions,
} from "./plumbing.js";
import { QueryRetry } from "./queryRetry.js";
import type { V1Contracts } from "../preMigration.js";

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

export const SCAN_TOPICS = [
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
    labelControllers: labelControllers("mainnet"),
  };
}

/// The registrar controllers on a network whose events carry plain-text labels: those
/// its v1 deployment records, and on mainnet also the controller the 2020 registrar
/// migration deployed, which no deployment record lists.
export function labelControllers(
  network: MigrationNetwork,
  opts: V1DeploymentOptions = {},
): Address[] {
  const recorded = [
    "WrappedETHRegistrarController",
    "ETHRegistrarController",
  ].flatMap((name) => {
    const deployment = loadV1Deployment(network, name, opts);
    return deployment ? [getAddress(deployment.address)] : [];
  });
  return network === "mainnet"
    ? [getAddress(LEGACY_ETH_REGISTRAR_CONTROLLER_ADDRESS), ...recorded]
    : recorded;
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

/// How a paged read retries a failed query.
export type RetryOptions = {
  /// The wait before the first retry; each failure in a row adds as much again.
  retryDelayMs?: number;
  /// Told of each failed query and the span it is asked again with.
  onRetry?: (error: unknown, span: bigint) => void;
};

/// The span of the next query of a paged read, and its run of failed queries.
export type Paging = { span: bigint; retry: QueryRetry };

/// Sends one query of a paged read. A query that is served is returned, and lets the
/// next span double, up to `maxSpan`.
///
/// A query that fails returns nothing, for the caller to ask again with half the
/// span. A refusal of the span is asked again at once, and one of a single block is
/// rethrown. Any other failure is asked again as `QueryRetry` allows.
export async function queryPage<T>(
  paging: Paging,
  maxSpan: bigint,
  onRetry: RetryOptions["onRetry"],
  query: () => Promise<T>,
): Promise<T | undefined> {
  let result: T;
  try {
    result = await query();
  } catch (error) {
    if (!isLogSpanRefusal(error)) await paging.retry.failed(error);
    else if (paging.span === 1n) throw error;
    if (paging.span > 1n) paging.span /= 2n;
    onRetry?.(error, paging.span);
    return undefined;
  }
  paging.retry.served();
  if (paging.span < maxSpan) paging.span *= 2n;
  return result;
}

/// Reads the logs of one block range, oldest first.
export type LogReader = (
  fromBlock: bigint,
  toBlock: bigint,
) => Promise<RawLog[]>;

/// Walks the registrar's and controllers' logs from `fromBlock` to `toBlock`, oldest
/// first, so a name's newest event is the last one applied.
///
/// The range is cut into chunks of `span` blocks, and up to `concurrency` chunks are
/// read at once. A chunk's logs are applied only after those of every chunk before
/// it, so the result does not depend on which read finishes first.
///
/// Within a chunk, a provider caps a log query by block span, by result count, or
/// both. A refused query is halved and asked again, and a query that is served lets
/// the next one double, up to the chunk. A query that fails for any other reason is
/// also halved and asked again, after a wait, up to a set number of failures in a
/// row; past that the scan ends, since a scan that stepped over a range would count
/// too few names.
export async function scanRegistrations(
  read: LogReader,
  opts: {
    registrar: Address;
    graveyards: ReadonlySet<Address>;
    fromBlock: bigint;
    toBlock: bigint;
    span: bigint;
    concurrency?: number;
    onProgress?: (scan: RegistrationScan, scannedTo: bigint) => void;
  } & RetryOptions,
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
  // Reads one chunk as the pages of logs its queries returned, oldest first.
  const readChunk = async (first: bigint, last: bigint) => {
    const pages: RawLog[][] = [];
    const paging: Paging = {
      span: opts.span,
      retry: new QueryRetry(opts.retryDelayMs),
    };
    let from = first;
    while (from <= last) {
      const end = from + paging.span - 1n;
      const to = end < last ? end : last;
      const logs = await queryPage(paging, opts.span, opts.onRetry, () =>
        read(from, to),
      );
      if (logs === undefined) continue;
      pages.push(logs);
      from = to + 1n;
    }
    return pages;
  };
  const queue: { last: bigint; pages: Promise<RawLog[][]> }[] = [];
  let next = opts.fromBlock;
  for (;;) {
    while (queue.length < (opts.concurrency ?? 1) && next <= opts.toBlock) {
      const end = next + opts.span - 1n;
      const last = end < opts.toBlock ? end : opts.toBlock;
      const pages = readChunk(next, last);
      // A chunk that fails is reported when its turn comes, not as an unhandled
      // rejection while an earlier chunk is still being read.
      pages.catch(() => {});
      queue.push({ last, pages });
      next = last + 1n;
    }
    const chunk = queue.shift();
    if (!chunk) return scan;
    for (const logs of await chunk.pages) {
      for (const log of logs) applyLog(scan, log, registrar, graveyards);
      scan.logs += logs.length;
    }
    opts.onProgress?.(scan, chunk.last);
  }
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

/// The first block whose timestamp is at or after `timestamp`, up to `head`.
export async function blockAtOrAfter(
  client: {
    getBlock(args: { blockNumber: bigint }): Promise<{ timestamp: bigint }>;
  },
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

/// A `LogReader` that asks an RPC for the registrar's and the label controllers' logs.
export function rpcLogReader(
  client: Pick<PublicClient, "request">,
  registrar: Address,
  labelControllers: readonly Address[],
): LogReader {
  return async (fromBlock, toBlock) =>
    (await client.request({
      method: "eth_getLogs",
      params: [
        {
          address: [registrar, ...labelControllers],
          fromBlock: `0x${fromBlock.toString(16)}`,
          toBlock: `0x${toBlock.toString(16)}`,
          topics: [SCAN_TOPICS],
        },
      ],
    })) as RawLog[];
}
