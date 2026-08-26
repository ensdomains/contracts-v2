import { describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  checkPrecondition,
  describePreconditionFailure,
  readVerification,
  recordVerification,
  type VerificationRecord,
} from "../../script/phaseGate.js";

const NAMESPACE = "mainnet";

function namespaceDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "phase-gate-"));
  mkdirSync(join(dir, NAMESPACE), { recursive: true });
  return dir;
}

function record(
  overrides: Partial<VerificationRecord> = {},
): VerificationRecord {
  return {
    check: "premigration-reconcile",
    chainId: 1,
    blockNumber: "100",
    verifiedAt: "2026-01-01T00:00:00.000Z",
    ...overrides,
  };
}

describe("verification records", () => {
  it("round-trips a recorded pass", () => {
    const dir = namespaceDir();
    recordVerification(dir, NAMESPACE, record());

    const read = readVerification(dir, NAMESPACE, "premigration-reconcile");
    expect(read?.blockNumber).toBe("100");
    expect(read?.chainId).toBe(1);
  });

  it("keeps only the latest pass, so a stale one cannot gate anything", () => {
    const dir = namespaceDir();
    recordVerification(dir, NAMESPACE, record({ blockNumber: "100" }));
    recordVerification(dir, NAMESPACE, record({ blockNumber: "200" }));

    expect(
      readVerification(dir, NAMESPACE, "premigration-reconcile")?.blockNumber,
    ).toBe("200");
  });

  it("keeps checks independent of one another", () => {
    const dir = namespaceDir();
    recordVerification(dir, NAMESPACE, record({ check: "a" }));
    recordVerification(dir, NAMESPACE, record({ check: "b" }));

    expect(readVerification(dir, NAMESPACE, "a")).not.toBeNull();
    expect(readVerification(dir, NAMESPACE, "b")).not.toBeNull();
  });

  it("reports no record rather than throwing on a missing namespace", () => {
    const dir = mkdtempSync(join(tmpdir(), "phase-gate-empty-"));
    expect(readVerification(dir, NAMESPACE, "anything")).toBeNull();
  });

  it("treats a corrupt gate file as no record rather than crashing a phase", () => {
    const dir = namespaceDir();
    writeFileSync(join(dir, NAMESPACE, ".verifications.json"), "not json");
    expect(readVerification(dir, NAMESPACE, "anything")).toBeNull();
  });
});

describe("checkPrecondition", () => {
  it("passes when the check ran on this chain", () => {
    expect(
      checkPrecondition({
        record: record(),
        chainId: 1,
        currentBlock: 150n,
      }),
    ).toBeNull();
  });

  it("fails when the check never ran", () => {
    expect(
      checkPrecondition({ record: null, chainId: 1, currentBlock: 150n }),
    ).toEqual({ kind: "missing" });
  });

  it("fails when the check ran against a different chain", () => {
    // A pass recorded on a fork must not authorise a mainnet freeze.
    expect(
      checkPrecondition({
        record: record({ chainId: 11155111 }),
        chainId: 1,
        currentBlock: 150n,
      }),
    ).toEqual({ kind: "wrong-chain", recordedChainId: 11155111 });
  });

  it("fails when the pass is older than the allowed window", () => {
    const failure = checkPrecondition({
      record: record({ blockNumber: "100" }),
      chainId: 1,
      currentBlock: 500n,
      maxAgeBlocks: 100n,
    });
    expect(failure).toEqual({
      kind: "stale",
      verifiedBlock: 100n,
      currentBlock: 500n,
    });
  });

  it("accepts a pass inside the allowed window", () => {
    expect(
      checkPrecondition({
        record: record({ blockNumber: "100" }),
        chainId: 1,
        currentBlock: 150n,
        maxAgeBlocks: 100n,
      }),
    ).toBeNull();
  });

  it("explains every failure in terms of what to do next", () => {
    for (const failure of [
      { kind: "missing" } as const,
      { kind: "wrong-chain", recordedChainId: 5 } as const,
      { kind: "stale", verifiedBlock: 1n, currentBlock: 2n } as const,
    ]) {
      const described = describePreconditionFailure("some-check", failure);
      expect(described).toContain("some-check");
      expect(described.length).toBeGreaterThan(20);
    }
  });
});
