import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { keccak256, stringToBytes } from "viem";

import {
  labelsFromCsvs,
  writeChangedNames,
} from "../../script/migrations/changedNames.js";
import {
  csvLabelCell,
  csvLabelColumns,
  parseCSVLine,
} from "../../script/preMigration.js";
import {
  chainOf,
  controllerLog,
  REGISTRAR,
  registered,
  renewed,
} from "./registrationLogFixtures.js";

const hashOf = (label: string) => keccak256(stringToBytes(label));

describe("writeChangedNames", () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "changed-names-"));
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  const run = (
    entries: Parameters<typeof chainOf>[0],
    labelCsvs?: string[],
    range: { fromBlock: bigint; toBlock: bigint } = {
      fromBlock: 1n,
      toBlock: 100n,
    },
  ) =>
    writeChangedNames(chainOf(entries).read, {
      registrar: REGISTRAR,
      ...range,
      span: 10n,
      concurrency: 2,
      retryDelayMs: 0,
      labelCsvs,
      out: join(dir, "changed.csv"),
    });

  // The labels pre-migration reads back from the list, in file order.
  const listedLabels = () => {
    const [header, ...rows] = readFileSync(join(dir, "changed.csv"), "utf8")
      .trimEnd()
      .split("\n");
    const columns = csvLabelColumns(parseCSVLine(header));
    return rows.map((row) => csvLabelCell(parseCSVLine(row), columns));
  };

  it("lists each name registered or renewed in the range once, labelled by its controller log", async () => {
    const meta = await run([
      [5n, registered("alpha", 1000n)],
      [5n, controllerLog(2, "alpha")],
      [20n, renewed("beta", 2000n)],
      [20n, controllerLog(4, "beta")],
      [40n, renewed("alpha", 3000n)],
      [40n, controllerLog(3, "alpha")],
    ]);

    expect(listedLabels().sort()).toEqual(["alpha", "beta"]);
    expect(meta).toEqual({
      fromBlock: "1",
      toBlock: "100",
      logs: 6,
      names: 2,
      labelledFromLogs: 2,
      labelledFromCsv: 0,
      unlabelled: 0,
    });
    const saved = JSON.parse(
      readFileSync(join(dir, "changed.csv.meta.json"), "utf8"),
    );
    expect(saved).toEqual(meta);
  });

  it("leaves out names whose only events fall outside the range", async () => {
    const meta = await run(
      [
        [5n, registered("before", 1000n)],
        [5n, controllerLog(2, "before")],
        [50n, renewed("inside", 2000n)],
        [50n, controllerLog(4, "inside")],
        [95n, registered("after", 3000n)],
      ],
      undefined,
      { fromBlock: 10n, toBlock: 90n },
    );

    expect(listedLabels()).toEqual(["inside"]);
    expect(meta.names).toBe(1);
  });

  it("labels a name no controller log labels from an export, matched on its labelhash", async () => {
    const csv = join(dir, "export.csv");
    writeFileSync(
      csv,
      [
        "name,full_name,labelhash,namehash,expiration_date,release_date,expires_raw,status",
        `direct,direct.eth,${hashOf("direct")},0x,,,1,active`,
        `other,other.eth,${hashOf("other")},0x,,,1,active`,
      ].join("\n"),
    );

    const meta = await run([[30n, registered("direct", 1000n)]], [csv]);

    expect(listedLabels()).toEqual(["direct"]);
    expect(meta.labelledFromCsv).toBe(1);
    expect(meta.unlabelled).toBe(0);
  });

  it("writes a name no log or export labels as its labelhash", async () => {
    const meta = await run([[30n, renewed("unknown", 1000n)]]);

    expect(listedLabels()).toEqual([`[${hashOf("unknown").slice(2)}]`]);
    expect(meta.unlabelled).toBe(1);
  });

  it("writes only the header when nothing changed in the range", async () => {
    const meta = await run([]);

    expect(listedLabels()).toEqual([]);
    expect(meta.names).toBe(0);
  });
});

describe("labelsFromCsvs", () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "label-csvs-"));
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("refuses a label that does not hash to the labelhash it is filed under", async () => {
    const csv = join(dir, "export.csv");
    writeFileSync(
      csv,
      ["name,labelhash", `wrong,${hashOf("right")}`].join("\n"),
    );

    const found = await labelsFromCsvs([csv], new Set([hashOf("right")]));

    expect(found.size).toBe(0);
  });

  it("hashes each label of an export with no labelhash column", async () => {
    const csv = join(dir, "labels.csv");
    writeFileSync(csv, ["labelName", "first", "second"].join("\n"));

    const found = await labelsFromCsvs([csv], new Set([hashOf("second")]));

    expect([...found]).toEqual([[hashOf("second"), "second"]]);
  });

  it("takes a label the first export lacks from a later one", async () => {
    const first = join(dir, "first.csv");
    const second = join(dir, "second.csv");
    writeFileSync(first, ["labelName", "alpha"].join("\n"));
    writeFileSync(second, ["labelName", "beta"].join("\n"));

    const found = await labelsFromCsvs(
      [first, second],
      new Set([hashOf("alpha"), hashOf("beta")]),
    );

    expect(found.get(hashOf("alpha"))).toBe("alpha");
    expect(found.get(hashOf("beta"))).toBe("beta");
  });
});
