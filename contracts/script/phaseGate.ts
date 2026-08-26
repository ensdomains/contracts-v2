// Records which verifications have passed, so a phase can refuse to run before the
// check that is supposed to precede it.
//
// The phases are ordered for a reason — freezing v1 before every claimable name is
// reserved on v2 strands the ones that were missed — but nothing enforces that
// ordering. The runbook says to run the checks; a tired operator at 3am can skip one
// and the next phase proceeds regardless. This turns the runbook's ordering into
// something the tool knows about.

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export const PHASE_GATE_FILE = ".verifications.json";

export type VerificationRecord = {
  check: string;
  chainId: number;
  /** Block the verification observed, so a stale pass can be recognised. */
  blockNumber: string;
  verifiedAt: string;
  details?: Record<string, unknown>;
};

type GateFile = { records: VerificationRecord[] };

function gatePath(deploymentsDir: string, namespace: string): string {
  return join(deploymentsDir, namespace, PHASE_GATE_FILE);
}

function readGate(path: string): GateFile {
  if (!existsSync(path)) return { records: [] };
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as GateFile;
    return { records: parsed.records ?? [] };
  } catch {
    return { records: [] };
  }
}

// A check records its most recent pass, replacing any earlier one: only the latest
// result can gate anything, and keeping the history would invite reading a stale
// pass as a current one.
export function recordVerification(
  deploymentsDir: string,
  namespace: string,
  record: VerificationRecord,
): void {
  const path = gatePath(deploymentsDir, namespace);
  const dir = join(deploymentsDir, namespace);
  if (!existsSync(dir)) return;

  const gate = readGate(path);
  const records = gate.records.filter((entry) => entry.check !== record.check);
  records.push(record);
  writeFileSync(path, `${JSON.stringify({ records }, null, 2)}\n`, "utf8");
}

export function readVerification(
  deploymentsDir: string,
  namespace: string,
  check: string,
): VerificationRecord | null {
  const gate = readGate(gatePath(deploymentsDir, namespace));
  return gate.records.find((entry) => entry.check === check) ?? null;
}

export type PreconditionFailure =
  | { kind: "missing" }
  | { kind: "wrong-chain"; recordedChainId: number }
  | { kind: "stale"; verifiedBlock: bigint; currentBlock: bigint };

// Whether a check's recorded pass still stands for the chain and block in question.
//
// A verification is tied to the block it observed. Chain state moves, so a pass from
// far enough back says nothing about now — `maxAgeBlocks` is what makes "verified"
// mean "verified recently" rather than "verified once, ever".
export function checkPrecondition(opts: {
  record: VerificationRecord | null;
  chainId: number;
  currentBlock: bigint;
  maxAgeBlocks?: bigint;
}): PreconditionFailure | null {
  if (!opts.record) return { kind: "missing" };
  if (opts.record.chainId !== opts.chainId) {
    return { kind: "wrong-chain", recordedChainId: opts.record.chainId };
  }
  if (opts.maxAgeBlocks !== undefined) {
    const verifiedBlock = BigInt(opts.record.blockNumber);
    if (opts.currentBlock > verifiedBlock + opts.maxAgeBlocks) {
      return {
        kind: "stale",
        verifiedBlock,
        currentBlock: opts.currentBlock,
      };
    }
  }
  return null;
}

export function describePreconditionFailure(
  check: string,
  failure: PreconditionFailure,
): string {
  switch (failure.kind) {
    case "missing":
      return `${check} has not passed for this deployment; run it first, or pass --skip-preconditions to proceed anyway`;
    case "wrong-chain":
      return `${check} was verified against chain ${failure.recordedChainId}, not this one; re-run it here`;
    case "stale":
      return `${check} last passed at block ${failure.verifiedBlock} and the chain is now at ${failure.currentBlock}; re-run it`;
  }
}
