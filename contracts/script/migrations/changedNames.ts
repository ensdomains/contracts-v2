// Lists the v1 `.eth` names whose expiry changed in a block range, as a pre-migration
// CSV, so a sync checks only those names instead of every name an export lists.
//
// A v1 expiry changes only through the registrar's `NameRegistered` and `NameRenewed`
// events, so every name whose v2 reservation can need a write has one of them in the
// range. The list says nothing about what to write: pre-migration still reads each
// name's v1 and v2 state from the chain and decides.

import { createReadStream, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { type Address, keccak256, stringToBytes } from "viem";

import {
  csvLabelCell,
  csvLabelColumns,
  parseCSVLine,
} from "../preMigration.js";
import {
  PREMIGRATION_CSV_HEADER,
  premigrationCsvRow,
} from "../preMigrationUtils.js";
import {
  type LogReader,
  type RetryOptions,
  scanRegistrations,
} from "./registrationLogs.js";

/// What a changed-names list covers, saved beside it.
export type ChangedNamesMeta = {
  fromBlock: string;
  toBlock: string;
  /// Registrar and controller logs read.
  logs: number;
  /// Names with a registration or renewal in the range.
  names: number;
  /// Names labelled by a controller log in the range.
  labelledFromLogs: number;
  /// Names labelled from an earlier export.
  labelledFromCsv: number;
  /// Names written as their labelhash, which pre-migration counts invalid.
  unlabelled: number;
};

export type ChangedNamesOptions = {
  registrar: Address;
  fromBlock: bigint;
  toBlock: bigint;
  /// Most blocks per log query, and the size of the chunks the range is read in.
  span: bigint;
  concurrency?: number;
  /// Registration exports that label names no controller log in the range labels.
  labelCsvs?: readonly string[];
  out: string;
} & RetryOptions;

function labelhashHex(id: bigint): string {
  return `0x${id.toString(16).padStart(64, "0")}`;
}

/// Labels from registration exports for the labelhashes asked for. Each export is
/// read once, and a label is kept only when it hashes to the labelhash it is filed
/// under, so a garbled cell cannot name the wrong name.
export async function labelsFromCsvs(
  csvFiles: readonly string[],
  wanted: ReadonlySet<string>,
): Promise<Map<string, string>> {
  const found = new Map<string, string>();
  for (const file of csvFiles) {
    if (found.size === wanted.size) break;
    const lines = createInterface({
      input: createReadStream(file),
      crlfDelay: Infinity,
    });
    let columns: ReturnType<typeof csvLabelColumns> | undefined;
    for await (const raw of lines) {
      const line = raw.replace(/^﻿/, "");
      if (!line.trim()) continue;
      if (columns === undefined) {
        columns = csvLabelColumns(parseCSVLine(line));
        if (columns.label < 0) break;
        continue;
      }
      const fields = parseCSVLine(line);
      const filed = fields[columns.labelhash]?.trim().toLowerCase();
      // An export with a labelhash column is matched on it, which saves hashing
      // every label; one without is matched on the label's own hash.
      if (filed && (!wanted.has(filed) || found.has(filed))) continue;
      const label = csvLabelCell(fields, columns);
      if (label === undefined) continue;
      const hash = keccak256(stringToBytes(label));
      if (wanted.has(hash) && !found.has(hash)) found.set(hash, label);
    }
    lines.close();
  }
  return found;
}

/// Writes every name with a registrar registration or renewal in the range to `out`
/// as a pre-migration CSV, in labelhash order, and its coverage to `<out>.meta.json`.
/// A name's label comes from a controller log in the range, else from the label
/// exports; a name neither labels is written as `[labelhash]`.
export async function writeChangedNames(
  read: LogReader,
  opts: ChangedNamesOptions,
): Promise<ChangedNamesMeta> {
  const scan = await scanRegistrations(read, {
    registrar: opts.registrar,
    graveyards: new Set(),
    fromBlock: opts.fromBlock,
    toBlock: opts.toBlock,
    span: opts.span,
    concurrency: opts.concurrency,
    retryDelayMs: opts.retryDelayMs,
    onRetry: opts.onRetry,
  });
  const ids = [...scan.expiries.keys()].sort((a, b) =>
    a < b ? -1 : a > b ? 1 : 0,
  );
  const missing = new Set(
    ids.filter((id) => !scan.labels.has(id)).map(labelhashHex),
  );
  const fromCsv =
    missing.size > 0 && opts.labelCsvs?.length
      ? await labelsFromCsvs(opts.labelCsvs, missing)
      : new Map<string, string>();

  const rows = [PREMIGRATION_CSV_HEADER];
  for (const id of ids) {
    const hash = labelhashHex(id);
    rows.push(
      premigrationCsvRow(
        scan.labels.get(id) ?? fromCsv.get(hash) ?? `[${hash.slice(2)}]`,
      ),
    );
  }
  writeFileSync(opts.out, `${rows.join("\n")}\n`);

  const meta: ChangedNamesMeta = {
    fromBlock: opts.fromBlock.toString(),
    toBlock: opts.toBlock.toString(),
    logs: scan.logs,
    names: ids.length,
    labelledFromLogs: ids.length - missing.size,
    labelledFromCsv: fromCsv.size,
    unlabelled: missing.size - fromCsv.size,
  };
  writeFileSync(`${opts.out}.meta.json`, `${JSON.stringify(meta, null, 2)}\n`);
  return meta;
}
