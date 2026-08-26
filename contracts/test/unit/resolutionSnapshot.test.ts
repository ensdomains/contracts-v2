import { describe, expect, it } from "bun:test";
import type { Hex } from "viem";

import {
  diffResolutionSnapshots,
  recordQueries,
  type ResolutionSnapshot,
} from "../../script/resolutionSnapshot.js";

function snapshot(
  names: Array<{ name: string; records: Record<string, Hex | null> }>,
): ResolutionSnapshot {
  return {
    capturedAt: "2026-01-01T00:00:00.000Z",
    chainId: 1,
    resolverAddress: "0x00000000000000000000000000000000000000ff",
    names: names.map((entry) => ({
      name: entry.name,
      resolver: "0x00000000000000000000000000000000000000aa",
      records: entry.records,
    })),
  };
}

const ADDR_A =
  "0x000000000000000000000000000000000000000000000000000000000000000a" as Hex;
const ADDR_B =
  "0x000000000000000000000000000000000000000000000000000000000000000b" as Hex;

describe("recordQueries", () => {
  it("asks for the address, contenthash, each coin type, and each text key", () => {
    const queries = recordQueries("vitalik.eth", {
      coinTypes: [60n, 0n],
      textKeys: ["avatar"],
    });

    expect(queries.map((query) => query.label)).toEqual([
      "addr",
      "contenthash",
      "addr(60)",
      "addr(0)",
      "text(avatar)",
    ]);
    for (const query of queries) {
      expect(query.call.startsWith("0x")).toBe(true);
    }
  });

  it("distinguishes the two addr overloads, which are separate code paths", () => {
    const [plain, , withCoinType] = recordQueries("vitalik.eth", {
      coinTypes: [60n],
      textKeys: [],
    });
    expect(plain.call).not.toBe(withCoinType.call);
  });
});

describe("diffResolutionSnapshots", () => {
  it("passes when every answer is identical", () => {
    const before = snapshot([{ name: "a.eth", records: { addr: ADDR_A } }]);
    expect(diffResolutionSnapshots(before, before)).toEqual([]);
  });

  it("catches an answer that changed", () => {
    const differences = diffResolutionSnapshots(
      snapshot([{ name: "a.eth", records: { addr: ADDR_A } }]),
      snapshot([{ name: "a.eth", records: { addr: ADDR_B } }]),
    );

    expect(differences).toHaveLength(1);
    expect(differences[0]).toMatchObject({
      name: "a.eth",
      record: "addr",
      before: ADDR_A,
      after: ADDR_B,
    });
  });

  it("catches a record that stopped resolving", () => {
    const differences = diffResolutionSnapshots(
      snapshot([{ name: "a.eth", records: { "text(url)": ADDR_A } }]),
      snapshot([{ name: "a.eth", records: { "text(url)": null } }]),
    );

    expect(differences).toHaveLength(1);
    expect(differences[0].after).toBe("(reverted)");
  });

  it("catches a record that started resolving", () => {
    const differences = diffResolutionSnapshots(
      snapshot([{ name: "a.eth", records: { contenthash: null } }]),
      snapshot([{ name: "a.eth", records: { contenthash: ADDR_A } }]),
    );

    expect(differences).toHaveLength(1);
    expect(differences[0].before).toBe("(reverted)");
  });

  it("ignores a record that never resolved either side", () => {
    // A name legitimately without a contenthash must not be reported as a change.
    const before = snapshot([
      { name: "a.eth", records: { contenthash: null } },
    ]);
    expect(diffResolutionSnapshots(before, before)).toEqual([]);
  });

  it("catches a name missing from the post-cutover snapshot entirely", () => {
    const differences = diffResolutionSnapshots(
      snapshot([{ name: "a.eth", records: { addr: ADDR_A } }]),
      snapshot([]),
    );

    expect(differences).toHaveLength(1);
    expect(differences[0].record).toBe("(whole name)");
  });

  it("reports every changed record, not just the first", () => {
    const differences = diffResolutionSnapshots(
      snapshot([
        {
          name: "a.eth",
          records: { addr: ADDR_A, "text(url)": ADDR_A, contenthash: ADDR_A },
        },
      ]),
      snapshot([
        {
          name: "a.eth",
          records: { addr: ADDR_B, "text(url)": null, contenthash: ADDR_A },
        },
      ]),
    );

    expect(differences.map((difference) => difference.record).sort()).toEqual([
      "addr",
      "text(url)",
    ]);
  });
});
