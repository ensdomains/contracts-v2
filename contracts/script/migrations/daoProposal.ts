/// Builds one DAO proposal from prepared owner transactions.
///
/// On mainnet the DAO timelock owns every v1 contract and the top Universal
/// Resolver proxy, so the writes the migration needs from it — those phase 1
/// defers and those the owner-gated phases prepare with `--calldata-only
/// --calldata-out` — reach the chain only through a proposal. This module merges
/// those files into the ordered call list a proposal executes, and decodes every
/// call against the contract it targets so voters read function calls, not hex.

import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import {
  decodeFunctionData,
  getAddress,
  toFunctionSelector,
  toFunctionSignature,
  type Abi,
  type AbiFunction,
  type Address,
  type Hex,
} from "viem";

import {
  readPreparedOwnerTransactions,
  type PreparedOwnerTransaction,
} from "./ownerTx.js";

/// A contract a proposal call may target, keyed by address in a `ContractIndex`.
export type IndexedContract = { name: string; abi: Abi };
export type ContractIndex = Map<string, IndexedContract>;

export type DecodedProposalCall = {
  index: number;
  label: string;
  contract: string;
  to: Address;
  value: string;
  data: Hex;
  signature: string;
  args: readonly unknown[];
};

/// Indexes every deployment artifact in `dirs` by address. Where two directories
/// record the same address, the earlier one names it.
export function indexDeploymentArtifacts(dirs: string[]): ContractIndex {
  const index: ContractIndex = new Map();
  for (const dir of dirs) {
    if (!existsSync(dir)) continue;
    for (const file of readdirSync(dir)) {
      if (!file.endsWith(".json") || file.startsWith(".")) continue;
      let artifact: { address?: unknown; abi?: unknown };
      try {
        artifact = JSON.parse(readFileSync(join(dir, file), "utf-8"));
      } catch {
        continue;
      }
      if (
        typeof artifact.address !== "string" ||
        !Array.isArray(artifact.abi)
      ) {
        continue;
      }
      const key = artifact.address.toLowerCase();
      if (!index.has(key)) {
        index.set(key, {
          name: file.replace(/\.json$/, ""),
          abi: artifact.abi as Abi,
        });
      }
    }
  }
  return index;
}

/// Concatenates prepared transactions in file order and keeps the first of any
/// identical calls (same target, value and calldata). A resumed deploy saves its
/// deferred writes again, and the same grant must not be executed twice.
export function mergeProposalCalls(
  batches: PreparedOwnerTransaction[][],
): PreparedOwnerTransaction[] {
  const seen = new Set<string>();
  const merged: PreparedOwnerTransaction[] = [];
  for (const tx of batches.flat()) {
    const key = [
      tx.to.toLowerCase(),
      BigInt(tx.value ?? "0").toString(),
      tx.data.toLowerCase(),
    ].join("|");
    if (seen.has(key)) continue;
    seen.add(key);
    merged.push(tx);
  }
  return merged;
}

function describeCall(tx: PreparedOwnerTransaction): string {
  const named = [tx.deployment, tx.functionName].filter(Boolean).join(".");
  return tx.label ?? (named || "transaction");
}

/// Decodes every call against the contract at its target. Throws, listing every
/// offender, when a target is not a known contract or its calldata does not decode
/// against that contract's ABI: a call nobody can read must not reach a vote.
export function decodeProposalCalls(
  calls: PreparedOwnerTransaction[],
  contracts: ContractIndex,
): DecodedProposalCall[] {
  const failures: string[] = [];
  const decoded: DecodedProposalCall[] = [];
  calls.forEach((tx, position) => {
    const index = position + 1;
    const label = describeCall(tx);
    const contract = contracts.get(tx.to.toLowerCase());
    if (!contract) {
      failures.push(`#${index} ${label}: ${tx.to} is not a known contract`);
      return;
    }
    try {
      const { functionName, args } = decodeFunctionData({
        abi: contract.abi,
        data: tx.data,
      });
      const selector = tx.data.slice(0, 10).toLowerCase();
      const item = contract.abi.find(
        (entry): entry is AbiFunction =>
          entry.type === "function" &&
          toFunctionSelector(entry).toLowerCase() === selector,
      );
      decoded.push({
        index,
        label,
        contract: contract.name,
        to: getAddress(tx.to),
        value: BigInt(tx.value ?? "0").toString(),
        data: tx.data,
        signature: item ? toFunctionSignature(item) : functionName,
        args: args ?? [],
      });
    } catch (error) {
      failures.push(
        `#${index} ${label}: calldata does not decode against ${contract.name} (${(error as Error).message.split("\n")[0]})`,
      );
    }
  });
  if (failures.length > 0) {
    throw new Error(
      `refusing to build the proposal:\n${failures.map((line) => `  ${line}`).join("\n")}`,
    );
  }
  return decoded;
}

function stringifyArgs(args: readonly unknown[]): string {
  return JSON.stringify(args, (_, value) =>
    typeof value === "bigint" ? value.toString() : value,
  );
}

/// The `targets`, `values` and `calldatas` arrays a Governor proposal takes, with
/// each call's signature alongside for reviewers.
export function proposalArrays(calls: DecodedProposalCall[]) {
  return {
    targets: calls.map((call) => call.to),
    values: calls.map((call) => call.value),
    calldatas: calls.map((call) => call.data),
    signatures: calls.map((call) => call.signature),
  };
}

export function renderProposalMarkdown(calls: DecodedProposalCall[]): string {
  return [
    "# DAO proposal: v1 → v2 migration calls",
    "",
    `The DAO timelock executes these ${calls.length} calls in this order, in one proposal. \`proposal.json\` holds the same calls as the \`targets\`, \`values\` and \`calldatas\` arrays a Governor proposal takes.`,
    "",
    "| # | Contract | Function | Purpose |",
    "| --- | --- | --- | --- |",
    ...calls.map(
      (call) =>
        `| ${call.index} | ${call.contract} \`${call.to}\` | \`${call.signature}\` | ${call.label} |`,
    ),
    "",
    ...calls.flatMap((call) => [
      `## ${call.index}. ${call.contract}.${call.signature.split("(")[0]}`,
      "",
      `- Purpose: ${call.label}`,
      `- Target: \`${call.to}\``,
      `- Value: ${call.value} wei`,
      `- Arguments: \`${stringifyArgs(call.args)}\``,
      "",
      "```",
      call.data,
      "```",
      "",
    ]),
  ].join("\n");
}

/// Merges the prepared-transaction files, decodes the result against `contractDirs`,
/// and writes the proposal to `outDir`:
/// - `calls.jsonl`: the ordered calls as prepared owner transactions, which
///   `phase execute-owner-txs` can play on a fork and `phase verify-owner-tx` checks
///   a transcribed call against
/// - `proposal.json`: the Governor arrays
/// - `proposal.md`: the decoded calls for review
export function buildDaoProposal(opts: {
  files: string[];
  outDir: string;
  contractDirs: string[];
}): DecodedProposalCall[] {
  const merged = mergeProposalCalls(
    opts.files.map((file) => readPreparedOwnerTransactions(file)),
  );
  if (merged.length === 0) {
    throw new Error(
      "no prepared transactions found; refusing to write an empty proposal",
    );
  }
  const decoded = decodeProposalCalls(
    merged,
    indexDeploymentArtifacts(opts.contractDirs),
  );

  mkdirSync(opts.outDir, { recursive: true });
  writeFileSync(
    join(opts.outDir, "calls.jsonl"),
    decoded
      .map((call) =>
        JSON.stringify({
          to: call.to,
          value: call.value,
          data: call.data,
          label: call.label,
          functionName: call.signature.split("(")[0],
          deployment: call.contract,
        }),
      )
      .join("\n")
      .concat("\n"),
  );
  writeFileSync(
    join(opts.outDir, "proposal.json"),
    `${JSON.stringify(proposalArrays(decoded), null, 2)}\n`,
  );
  writeFileSync(
    join(opts.outDir, "proposal.md"),
    renderProposalMarkdown(decoded),
  );
  return decoded;
}
