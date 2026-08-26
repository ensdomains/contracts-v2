import { describe, expect, it } from "bun:test";

import {
  compareDeployedBytecode,
  describeComparison,
  maskImmutables,
} from "../../script/bytecodeCheck.js";

describe("maskImmutables", () => {
  it("leaves bytecode untouched when nothing is immutable", () => {
    expect(maskImmutables("0xdeadbeef", undefined)).toBe("deadbeef");
  });

  it("blanks the byte ranges an immutable occupies", () => {
    // Bytes: de ad be ef — blanking byte 1 (length 1) clears "ad".
    expect(
      maskImmutables("0xdeadbeef", { "1": [{ start: 1, length: 1 }] }),
    ).toBe("de00beef");
  });

  it("blanks every range of every immutable", () => {
    expect(
      maskImmutables("0xdeadbeefcafe", {
        "1": [{ start: 0, length: 1 }],
        "2": [{ start: 2, length: 1 }],
      }),
    ).toBe("00ad00efcafe");
  });

  it("ignores a range past the end rather than throwing", () => {
    expect(() =>
      maskImmutables("0xdead", { "1": [{ start: 8, length: 4 }] }),
    ).not.toThrow();
  });
});

describe("compareDeployedBytecode", () => {
  it("matches identical bytecode", () => {
    expect(
      compareDeployedBytecode({
        onChain: "0xdeadbeef",
        artifact: "0xdeadbeef",
      }),
    ).toEqual({ kind: "match" });
  });

  it("matches regardless of hex case", () => {
    expect(
      compareDeployedBytecode({
        onChain: "0xDEADBEEF",
        artifact: "0xdeadbeef",
      }),
    ).toEqual({ kind: "match" });
  });

  it("reports an address with no code", () => {
    expect(
      compareDeployedBytecode({ onChain: "0x", artifact: "0xdeadbeef" }),
    ).toEqual({ kind: "no-code" });
    expect(
      compareDeployedBytecode({ onChain: null, artifact: "0xdeadbeef" }),
    ).toEqual({ kind: "no-code" });
  });

  it("reports a different contract at the address", () => {
    const comparison = compareDeployedBytecode({
      onChain: "0xdeadbe11",
      artifact: "0xdeadbeef",
    });
    expect(comparison).toEqual({ kind: "differs", firstDifferenceOffset: 3 });
  });

  it("reports a length mismatch separately from a content difference", () => {
    expect(
      compareDeployedBytecode({ onChain: "0xdead", artifact: "0xdeadbeef" }),
    ).toEqual({ kind: "length-mismatch", expected: 4, actual: 2 });
  });

  it("matches when only the immutable values differ, as they must", () => {
    // Constructor-set immutables are baked into runtime code, so the compiler's copy
    // and the deployed copy legitimately differ exactly there.
    const comparison = compareDeployedBytecode({
      onChain: "0xdeadCAFEbeef",
      artifact: "0xdead0000beef",
      immutableReferences: { "1": [{ start: 2, length: 2 }] },
    });
    expect(comparison).toEqual({ kind: "match" });
  });

  it("still catches a difference outside the immutable range", () => {
    const comparison = compareDeployedBytecode({
      onChain: "0xdeadCAFEbe11",
      artifact: "0xdead0000beef",
      immutableReferences: { "1": [{ start: 2, length: 2 }] },
    });
    expect(comparison.kind).toBe("differs");
  });
});

describe("describeComparison", () => {
  it("names the contract and address in every outcome", () => {
    const address = "0x00000000000000000000000000000000000000ff";
    for (const comparison of [
      { kind: "match" } as const,
      { kind: "no-code" } as const,
      { kind: "length-mismatch", expected: 4, actual: 2 } as const,
      { kind: "differs", firstDifferenceOffset: 3 } as const,
    ]) {
      const described = describeComparison("ETHRegistry", address, comparison);
      expect(described).toContain("ETHRegistry");
      expect(described).toContain(address);
    }
  });
});
