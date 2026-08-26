import { describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  exportRegistrations,
  sourceStampPath,
  unlabelledFilePath,
} from "../../script/exportTheGraphRegistrations.js";

const HEAD_BLOCK = 21_000_000;

type Registration = {
  id: string;
  labelName: string | null;
};

function registration(id: string, labelName: string | null) {
  return {
    id,
    labelName,
    registrant: { id: "0x0000000000000000000000000000000000000001" },
    expiryDate: "1900000000",
    registrationDate: "1600000000",
    domain: {
      id: `${id}-domain`,
      name: labelName ? `${labelName}.eth` : null,
      labelhash: null,
      parent: { id: "eth" },
    },
  };
}

function labelhash(index: number): string {
  return `0x${index.toString(16).padStart(64, "0")}`;
}

// A subgraph that holds `rows` and answers cursor queries against them, recording
// every request so the test can assert on how it was paged.
function fakeSubgraph(rows: Registration[]) {
  const requests: Array<Record<string, unknown>> = [];
  const fetchFn = (async (_url: string, init: { body: string }) => {
    const body = JSON.parse(init.body);
    requests.push(body);
    if (String(body.query).includes("_meta")) {
      return Response.json({
        data: { _meta: { block: { number: HEAD_BLOCK } } },
      });
    }
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
  return { fetchFn, requests };
}

function runExport(
  rows: Registration[],
  overrides: { batchSize?: number; limit?: number | null } = {},
) {
  const dir = mkdtempSync(join(tmpdir(), "ens-export-"));
  const outputFile = join(dir, "registrations.csv");
  const { fetchFn, requests } = fakeSubgraph(rows);
  return {
    outputFile,
    requests,
    run: () =>
      exportRegistrations(
        {
          thegraphApiKey: "key",
          network: "mainnet",
          batchSize: overrides.batchSize ?? 2,
          startId: "",
          limit: overrides.limit ?? null,
          outputFile,
          block: null,
        },
        fetchFn,
      ),
  };
}

function dataRows(path: string): string[] {
  return readFileSync(path, "utf8").trim().split("\n").slice(1);
}

describe("exportTheGraphRegistrations", () => {
  it("pages by cursor until exhausted, without repeating or dropping rows", async () => {
    const rows = Array.from({ length: 7 }, (_, index) =>
      registration(labelhash(index + 1), `name${index + 1}`),
    );
    const { outputFile, requests, run } = runExport(rows);

    await run();

    const exported = dataRows(outputFile);
    expect(exported).toHaveLength(7);

    // Every registration appears exactly once, keyed by its labelhash.
    const exportedHashes = exported.map((row) => row.split(",")[2]);
    expect(new Set(exportedHashes).size).toBe(7);
    expect(exportedHashes.sort()).toEqual(rows.map((row) => row.id).sort());

    // Each page asks for rows after the previous page's last id — never an offset.
    const cursors = requests
      .filter((body) => body.variables)
      .map((body) => (body.variables as { afterId: string }).afterId);
    expect(cursors).toEqual([
      "",
      labelhash(2),
      labelhash(4),
      labelhash(6),
      labelhash(7),
    ]);
  });

  it("pins every page to a single indexed block", async () => {
    const rows = Array.from({ length: 5 }, (_, index) =>
      registration(labelhash(index + 1), `name${index + 1}`),
    );
    const { requests, run } = runExport(rows);

    await run();

    const blocks = requests
      .filter((body) => body.variables)
      .map((body) => (body.variables as { block: number }).block);
    expect(blocks.length).toBeGreaterThan(1);
    expect(new Set(blocks)).toEqual(new Set([HEAD_BLOCK]));
  });

  it("keeps undecodable labels in a sidecar instead of discarding them", async () => {
    const rows = [
      registration(labelhash(1), "alpha"),
      registration(labelhash(2), null),
      registration(labelhash(3), "gamma"),
      registration(labelhash(4), ""),
    ];
    const { outputFile, run } = runExport(rows);

    await run();

    // The main CSV stays consumable: every row carries a label.
    const exported = dataRows(outputFile);
    expect(exported).toHaveLength(2);
    for (const row of exported) {
      expect(row.split(",")[6]).not.toBe("");
    }

    // The undecodable ones survive as labelhashes rather than vanishing.
    const unlabelled = dataRows(unlabelledFilePath(outputFile));
    expect(unlabelled.map((row) => row.split(",")[0])).toEqual([
      labelhash(2),
      labelhash(4),
    ]);
  });

  it("stamps the source so a reconciliation can refuse a circular check", async () => {
    const rows = [
      registration(labelhash(1), "alpha"),
      registration(labelhash(2), null),
    ];
    const { outputFile, run } = runExport(rows);

    await run();

    const stamp = JSON.parse(readFileSync(sourceStampPath(outputFile), "utf8"));
    expect(stamp.source).toBe("subgraph");
    expect(stamp.network).toBe("mainnet");
    expect(stamp.block).toBe(HEAD_BLOCK);
    expect(stamp.totalRegistrations).toBe(2);
    expect(stamp.labelledRegistrations).toBe(1);
    expect(stamp.unlabelledRegistrations).toBe(1);
  });

  it("stops at the requested limit", async () => {
    const rows = Array.from({ length: 10 }, (_, index) =>
      registration(labelhash(index + 1), `name${index + 1}`),
    );
    const { outputFile, run } = runExport(rows, { batchSize: 4, limit: 5 });

    await run();

    expect(dataRows(outputFile)).toHaveLength(5);
  });
});
