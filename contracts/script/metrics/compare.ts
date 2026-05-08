import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { formatMarkdown } from "./formatMarkdown.js";
import { writeJson } from "./collect.js";
import {
  METRICS_SCHEMA_VERSION,
  decimal,
  type MetricDiffEntry,
  type MetricDiffReport,
  type MetricReport,
  type MetricSummary,
} from "./schema.js";

const DEFAULT_SIZE_LIMIT_BYTES = 24_576n;
type AggregateValueKey = "avg" | "median" | "min" | "max";

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const basePath = args.base ?? args._[0];
  const headPath = args.head ?? args._[1];
  if (!basePath || !headPath) {
    throw new Error("usage: compare.ts --base <base.json> --head <head.json>");
  }

  const outPath = args.out ?? "metrics/contract-metrics-diff.json";
  const markdownPath = args.markdown ?? "metrics/contract-metrics.md";
  const sizeLimitBytes = BigInt(
    args["size-limit"] ??
      process.env.CONTRACT_SIZE_LIMIT_BYTES ??
      DEFAULT_SIZE_LIMIT_BYTES,
  );

  const base = JSON.parse(await readFile(basePath, "utf8")) as MetricReport;
  const head = JSON.parse(await readFile(headPath, "utf8")) as MetricReport;
  const diff = compareReports(base, head, { sizeLimitBytes });

  await writeJson(outPath, diff);
  await mkdir(dirname(markdownPath), { recursive: true });
  await writeFile(markdownPath, formatMarkdown(diff));
  console.log(`Wrote ${outPath}`);
  console.log(`Wrote ${markdownPath}`);

  if (diff.hardLimitFailures.length) {
    process.exitCode = 1;
  }
}

export function compareReports(
  base: MetricReport,
  head: MetricReport,
  {
    sizeLimitBytes = DEFAULT_SIZE_LIMIT_BYTES,
  }: { sizeLimitBytes?: bigint } = {},
): MetricDiffReport {
  const groups = {
    sizes: compareSummaries(base.summaries.sizes, head.summaries.sizes, "max"),
    deployments: compareSummaries(
      base.summaries.deployments,
      head.summaries.deployments,
      "avg",
    ),
    functions: compareSummaries(
      base.summaries.functions,
      head.summaries.functions,
      "avg",
    ),
    testTotals: compareSummaries(
      base.summaries.testTotals,
      head.summaries.testTotals,
      "avg",
    ),
  };

  const hardLimitFailures = head.summaries.sizes
    .filter((summary) => summary.project)
    .filter((summary) => BigInt(summary.aggregate.max) > sizeLimitBytes)
    .map((summary) => ({
      key: summary.key,
      label: summary.label,
      runtimeBytes: summary.aggregate.max,
      limitBytes: decimal(sizeLimitBytes),
    }));

  return {
    schemaVersion: METRICS_SCHEMA_VERSION,
    baseCommit: base.commit,
    headCommit: head.commit,
    generatedAt: new Date().toISOString(),
    unchanged:
      !hardLimitFailures.length &&
      !groups.sizes.length &&
      !groups.deployments.length &&
      !groups.functions.length &&
      !groups.testTotals.length,
    hardLimitFailures,
    groups,
  };
}

function compareSummaries(
  base: MetricSummary[],
  head: MetricSummary[],
  aggregateKey: AggregateValueKey,
): MetricDiffEntry[] {
  const baseMap = summaryMap(base);
  const headMap = summaryMap(head);
  const keys = new Set([...baseMap.keys(), ...headMap.keys()]);
  const entries: MetricDiffEntry[] = [];

  for (const key of Array.from(keys).sort()) {
    const baseSummary = baseMap.get(key);
    const headSummary = headMap.get(key);
    const baseValue = baseSummary?.aggregate[aggregateKey];
    const headValue = headSummary?.aggregate[aggregateKey];
    if (baseValue === headValue) continue;

    const delta =
      baseValue !== undefined && headValue !== undefined
        ? decimal(BigInt(headValue) - BigInt(baseValue))
        : undefined;
    const status =
      baseValue === undefined
        ? "added"
        : headValue === undefined
          ? "removed"
          : "changed";
    const summary = headSummary ?? baseSummary;
    if (!summary) continue;

    entries.push({
      key,
      label: summary.label,
      suite: summary.suite,
      phase: summary.phase,
      unit: summary.unit,
      status,
      base: baseValue,
      head: headValue,
      delta,
      percent: percentDelta(baseValue, headValue),
    });
  }

  return entries;
}

function summaryMap(summaries: MetricSummary[]): Map<string, MetricSummary> {
  return new Map(
    summaries
      .filter((summary) => summary.project)
      .map((summary) => [summary.key, summary]),
  );
}

function percentDelta(
  baseValue: string | undefined,
  headValue: string | undefined,
): number | undefined {
  if (!baseValue || !headValue) return undefined;
  const base = BigInt(baseValue);
  if (base === 0n) return undefined;
  const delta = BigInt(headValue) - base;
  return Number((delta * 10_000n) / base) / 100;
}

function parseArgs(argv: string[]) {
  const parsed: Record<string, string | string[]> & { _: string[] } = {
    _: [],
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg.startsWith("--")) {
      parsed[arg.slice(2)] = argv[++i];
    } else {
      parsed._.push(arg);
    }
  }
  return parsed as Record<string, string> & { _: string[] };
}

if (import.meta.main) {
  await main();
}
