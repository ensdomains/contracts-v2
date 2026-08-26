#!/usr/bin/env bun

// Builds an independent view of which v1 `.eth` 2LD names exist and when they
// expire, keyed by labelhash.
//
// Pre-migration seeds v2 from a CSV. Verifying that CSV against the indexer that
// produced it proves nothing: a name missing from that source is missing from both
// sides of the comparison and the check passes. This index therefore has to come
// from a *different* source than the CSV did, and the reconciliation refuses to run
// when the two match.
//
// Names are keyed by labelhash rather than by label because that is the only key
// every registration has. An indexer cannot always decode a label preimage, but the
// registrar emitted the hash for every name ever registered, and the v2 registry
// accepts that hash directly as a lookup id.

import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

import {
  fetchIndexedBlock,
  getGatewayEndpoint,
  type ENSRegistrationNetwork,
} from "./exportTheGraphRegistrations.js";
import { V1_GRACE_PERIOD_SECONDS } from "./preMigration.js";

export const V1_INDEX_FILE = "v1-name-index.ndjson";
export const V1_INDEX_META_FILE = "v1-name-index.meta.json";

// Build-time filtering only has to be cheap and safe, never exact: the
// reconciliation re-applies the grace rule against a chain block timestamp. Keeping
// an extra week of already-expired names means a name near the boundary can never be
// dropped here and then wanted there.
const BUILD_FILTER_MARGIN_SECONDS = 7n * 24n * 60n * 60n;

const PAGE_DELAY_MS = 200;

export type V1IndexSource = "subgraph" | "rpc";

export type V1IndexMeta = {
  source: V1IndexSource;
  network: string;
  block: number;
  /** Last registration id written; a resumed build continues after it. */
  lastId: string;
  entries: number;
  complete: boolean;
  builtAt: string;
};

export type V1NameIndex = {
  meta: V1IndexMeta;
  /** Labelhash (lowercase, 0x-prefixed) to the v1 expiry in seconds. */
  expiries: Map<string, bigint>;
};

type IndexedRegistration = { id: string; expiryDate: string | null };

function metaPath(workDir: string) {
  return join(workDir, V1_INDEX_META_FILE);
}

function indexPath(workDir: string) {
  return join(workDir, V1_INDEX_FILE);
}

function normalizeLabelhash(id: string): string {
  const hex = id.startsWith("0x") ? id.slice(2) : id;
  return `0x${hex.toLowerCase().padStart(64, "0")}`;
}

// One page of registrations ordered by id. Cursor paging is required rather than
// preferred: gateways cap `skip`, and an offset into a live result set silently
// duplicates and drops rows as new registrations are indexed.
async function fetchIndexPage(
  config: { thegraphApiKey: string; network: ENSRegistrationNetwork },
  afterId: string,
  first: number,
  block: number,
  fetchFn: typeof fetch,
): Promise<IndexedRegistration[]> {
  const query = `
    query IndexEthRegistrations($first: Int!, $afterId: ID!, $block: Int!) {
      registrations(
        first: $first
        where: { id_gt: $afterId }
        orderBy: id
        orderDirection: asc
        block: { number: $block }
      ) {
        id
        expiryDate
      }
    }
  `;

  const response = await fetchFn(getGatewayEndpoint(config), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables: { first, afterId, block } }),
  });

  if (!response.ok) {
    throw new Error(
      `HTTP error! status: ${response.status}, body: ${await response.text()}`,
    );
  }

  const result = (await response.json()) as {
    data?: { registrations?: IndexedRegistration[] };
    errors?: Array<{ message: string }>;
  };

  if (result.errors) {
    throw new Error(
      `GraphQL error: ${result.errors.map((e) => e.message).join(", ")}`,
    );
  }
  if (!result.data?.registrations) {
    throw new Error(
      "Invalid response structure from TheGraph: missing data.registrations",
    );
  }
  return result.data.registrations;
}

export type BuildV1NameIndexOptions = {
  thegraphApiKey: string;
  network: ENSRegistrationNetwork;
  workDir: string;
  batchSize?: number;
  /** Pin to a specific indexed block; defaults to the subgraph head. */
  block?: number;
  /** Continue a partial build instead of starting over. */
  resume?: boolean;
  /** Seconds since epoch used for the coarse build-time grace filter. */
  now?: bigint;
  onProgress?: (entries: number, lastId: string) => void;
};

// Streams the whole registration set into an NDJSON index. The file is appended page
// by page and the cursor recorded alongside it, so an interrupted build resumes
// where it stopped rather than repeating a multi-hour scan.
export async function buildV1NameIndex(
  opts: BuildV1NameIndexOptions,
  fetchFn: typeof fetch = fetch,
): Promise<V1IndexMeta> {
  const config = {
    thegraphApiKey: opts.thegraphApiKey,
    network: opts.network,
  };
  const batchSize = opts.batchSize ?? 1000;
  const now = opts.now ?? BigInt(Math.floor(Date.now() / 1000));
  const cutoff = now - V1_GRACE_PERIOD_SECONDS - BUILD_FILTER_MARGIN_SECONDS;

  mkdirSync(opts.workDir, { recursive: true });

  const existing = opts.resume ? readV1NameIndexMeta(opts.workDir) : null;
  if (existing && existing.complete) return existing;

  // A resumed build must continue against the same block, or the two halves of the
  // index describe different chain states.
  const block =
    existing?.block ?? opts.block ?? (await fetchIndexedBlock(config, fetchFn));
  if (existing && opts.block !== undefined && existing.block !== opts.block) {
    throw new Error(
      `cannot resume index at block ${opts.block}: partial index was built at block ${existing.block}`,
    );
  }

  let cursor = existing?.lastId ?? "";
  let entries = existing?.entries ?? 0;
  if (!existing) writeFileSync(indexPath(opts.workDir), "", "utf-8");

  const writeMeta = (complete: boolean): V1IndexMeta => {
    const meta: V1IndexMeta = {
      source: "subgraph",
      network: opts.network,
      block,
      lastId: cursor,
      entries,
      complete,
      builtAt: new Date().toISOString(),
    };
    writeFileSync(
      metaPath(opts.workDir),
      `${JSON.stringify(meta, null, 2)}\n`,
      "utf-8",
    );
    return meta;
  };

  for (;;) {
    const page = await fetchIndexPage(
      config,
      cursor,
      batchSize,
      block,
      fetchFn,
    );
    if (page.length === 0) break;

    const lines: string[] = [];
    for (const registration of page) {
      const expiry = BigInt(registration.expiryDate ?? "0");
      // A name released long ago cannot be claimed by its former owner. Dropping it
      // here keeps the index proportional to live names rather than to all history.
      if (expiry === 0n || expiry <= cutoff) continue;
      lines.push(
        `${JSON.stringify({ id: normalizeLabelhash(registration.id), expiry: expiry.toString() })}`,
      );
    }
    if (lines.length > 0) {
      appendFileSync(indexPath(opts.workDir), `${lines.join("\n")}\n`, "utf-8");
      entries += lines.length;
    }

    cursor = page[page.length - 1].id;
    writeMeta(false);
    opts.onProgress?.(entries, cursor);

    if (page.length < batchSize) break;
    await new Promise((resolve) => setTimeout(resolve, PAGE_DELAY_MS));
  }

  return writeMeta(true);
}

export function readV1NameIndexMeta(workDir: string): V1IndexMeta | null {
  const path = metaPath(workDir);
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, "utf8")) as V1IndexMeta;
}

// Loads a completed index into memory. A partial index is refused rather than
// silently under-reporting: a reconciliation reads "absent from the index" as
// "not a v1 name", which is exactly the wrong conclusion to draw from a short read.
export function loadV1NameIndex(workDir: string): V1NameIndex {
  const meta = readV1NameIndexMeta(workDir);
  if (!meta) {
    throw new Error(
      `no v1 name index in ${workDir}: run premigration build-index`,
    );
  }
  if (!meta.complete) {
    throw new Error(
      `v1 name index in ${workDir} is incomplete (${meta.entries} entries, stopped at ${meta.lastId}): resume the build before reconciling`,
    );
  }

  const expiries = new Map<string, bigint>();
  const contents = readFileSync(indexPath(workDir), "utf8");
  for (const line of contents.split("\n")) {
    if (line === "") continue;
    const entry = JSON.parse(line) as { id: string; expiry: string };
    const expiry = BigInt(entry.expiry);
    // The subgraph folds renewals into a single entity per labelhash, so a repeated
    // id means a rebuilt or appended index; keep the longest life seen.
    const previous = expiries.get(entry.id);
    if (previous === undefined || expiry > previous) {
      expiries.set(entry.id, expiry);
    }
  }
  return { meta, expiries };
}

// How a CSV was produced, when the exporter recorded it. Absent for a CSV that
// arrived out of band, which is the normal case for a manually-run Dune export.
export function readCsvSourceStamp(
  csvFile: string,
): { source?: string; network?: string; block?: number } | null {
  const path = `${csvFile}.source.json`;
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

// The reconciliation is only meaningful when its index and the CSV came from
// different indexers. This catches the circular case rather than trusting an
// operator to remember which file came from where.
export function assertIndependentSource(
  indexSource: V1IndexSource,
  csvFile: string,
): void {
  const stamp = readCsvSourceStamp(csvFile);
  if (!stamp?.source) return;
  if (stamp.source === indexSource) {
    throw new Error(
      `refusing to reconcile: ${csvFile} was produced from "${stamp.source}" and the index was built from "${indexSource}". ` +
        `Verifying a CSV against the indexer that produced it cannot detect a name missing from that indexer. ` +
        `Build the index from a different source (--source), or reconcile a CSV from a different one.`,
    );
  }
}
