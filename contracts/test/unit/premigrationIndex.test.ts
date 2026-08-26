import { describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  assertIndependentSource,
  buildV1NameIndex,
  loadV1NameIndex,
  readV1NameIndexMeta,
} from "../../script/premigrationIndex.js";
import { V1_GRACE_PERIOD_SECONDS } from "../../script/preMigration.js";

const HEAD_BLOCK = 21_000_000;
const NOW = 1_800_000_000n;

function labelhash(index: number): string {
  return `0x${index.toString(16).padStart(64, "0")}`;
}

type Row = { id: string; expiryDate: string };

// A subgraph holding `rows`, answering cursor queries. `failAfter` makes it throw
// part-way through so a resume can be exercised.
function fakeSubgraph(rows: Row[], failAfter?: number) {
  let pages = 0;
  const fetchFn = (async (_url: string, init: { body: string }) => {
    const body = JSON.parse(init.body);
    if (String(body.query).includes("_meta")) {
      return Response.json({
        data: { _meta: { block: { number: HEAD_BLOCK } } },
      });
    }
    if (failAfter !== undefined && pages >= failAfter) {
      throw new Error("simulated gateway failure");
    }
    pages++;
    const { first, afterId } = body.variables as {
      first: number;
      afterId: string;
    };
    const page = rows
      .filter((row) => row.id > afterId)
      .sort((a, b) => (a.id < b.id ? -1 : 1))
      .slice(0, first);
    return Response.json({ data: { registrations: page } });
  }) as unknown as typeof fetch;
  return fetchFn;
}

function workDir() {
  return mkdtempSync(join(tmpdir(), "ens-index-"));
}

function build(
  dir: string,
  rows: Row[],
  opts: { batchSize?: number; resume?: boolean; failAfter?: number } = {},
) {
  return buildV1NameIndex(
    {
      thegraphApiKey: "key",
      network: "mainnet",
      workDir: dir,
      batchSize: opts.batchSize ?? 2,
      resume: opts.resume,
      now: NOW,
    },
    fakeSubgraph(rows, opts.failAfter),
  );
}

const live = (index: number, offset = 1_000_000n): Row => ({
  id: labelhash(index),
  expiryDate: (NOW + offset).toString(),
});

describe("premigrationIndex", () => {
  it("indexes every live name keyed by labelhash", async () => {
    const dir = workDir();
    const rows = [live(1), live(2), live(3), live(4), live(5)];

    const meta = await build(dir, rows);

    expect(meta.complete).toBe(true);
    expect(meta.entries).toBe(5);
    expect(meta.block).toBe(HEAD_BLOCK);
    expect(meta.source).toBe("subgraph");

    const index = loadV1NameIndex(dir);
    expect(index.expiries.size).toBe(5);
    expect(index.expiries.get(labelhash(3))).toBe(NOW + 1_000_000n);
  });

  it("drops names released long ago but keeps names inside grace", async () => {
    const dir = workDir();
    const rows: Row[] = [
      live(1),
      // Expired but still inside the 90-day grace: the owner can still claim it.
      { id: labelhash(2), expiryDate: (NOW - 10n).toString() },
      // Released long ago — no longer its former owner's to migrate.
      {
        id: labelhash(3),
        expiryDate: (NOW - V1_GRACE_PERIOD_SECONDS - 400n * 86400n).toString(),
      },
      // Never registered.
      { id: labelhash(4), expiryDate: "0" },
    ];

    await build(dir, rows);

    const index = loadV1NameIndex(dir);
    expect([...index.expiries.keys()].sort()).toEqual([
      labelhash(1),
      labelhash(2),
    ]);
  });

  it("normalizes labelhashes so short ids still join correctly", async () => {
    const dir = workDir();
    // Some indexers drop leading zeros when hex-encoding an id.
    const rows: Row[] = [{ id: "0xabc", expiryDate: (NOW + 100n).toString() }];

    await build(dir, rows);

    const index = loadV1NameIndex(dir);
    expect(index.expiries.has(`0x${"abc".padStart(64, "0")}`)).toBe(true);
  });

  it("resumes an interrupted build without losing or repeating entries", async () => {
    const dir = workDir();
    const rows = Array.from({ length: 9 }, (_, i) => live(i + 1));

    // Fail after two pages of two, leaving a partial index behind.
    await expect(build(dir, rows, { failAfter: 2 })).rejects.toThrow(
      "simulated gateway failure",
    );

    const partial = readV1NameIndexMeta(dir);
    expect(partial?.complete).toBe(false);
    expect(partial?.entries).toBe(4);

    // Loading a partial index must fail loudly rather than under-report.
    expect(() => loadV1NameIndex(dir)).toThrow(/incomplete/);

    const meta = await build(dir, rows, { resume: true });

    expect(meta.complete).toBe(true);
    expect(meta.entries).toBe(9);
    // The resumed half stays pinned to the block the first half used.
    expect(meta.block).toBe(HEAD_BLOCK);

    const index = loadV1NameIndex(dir);
    expect(index.expiries.size).toBe(9);
    expect([...index.expiries.keys()].sort()).toEqual(
      rows.map((row) => row.id).sort(),
    );
  });

  it("refuses to verify a CSV against the indexer that produced it", () => {
    const dir = workDir();
    const csv = join(dir, "registrations.csv");
    writeFileSync(csv, "label\n", "utf-8");
    writeFileSync(
      `${csv}.source.json`,
      JSON.stringify({ source: "subgraph", network: "mainnet" }),
      "utf-8",
    );

    expect(() => assertIndependentSource("subgraph", csv)).toThrow(
      /refusing to reconcile/,
    );
    // A different source is the whole point, so it passes.
    expect(() => assertIndependentSource("rpc", csv)).not.toThrow();
  });

  it("allows a CSV with no source stamp, as a manual export has none", () => {
    const dir = workDir();
    const csv = join(dir, "dune.csv");
    writeFileSync(csv, "label\n", "utf-8");

    expect(() => assertIndependentSource("subgraph", csv)).not.toThrow();
  });

  it("records progress so a partial build is inspectable", async () => {
    const dir = workDir();
    const rows = Array.from({ length: 6 }, (_, i) => live(i + 1));
    const seen: number[] = [];

    await buildV1NameIndex(
      {
        thegraphApiKey: "key",
        network: "mainnet",
        workDir: dir,
        batchSize: 2,
        now: NOW,
        onProgress: (entries) => seen.push(entries),
      },
      fakeSubgraph(rows),
    );

    expect(seen).toEqual([2, 4, 6]);
    const written = readFileSync(join(dir, "v1-name-index.ndjson"), "utf8");
    expect(written.trim().split("\n")).toHaveLength(6);
  });
});
