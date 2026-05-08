export const METRICS_SCHEMA_VERSION = 1;

export type DecimalString = string;

export type MetricKind =
  | "contract-size"
  | "deployment"
  | "function"
  | "test-total";

export type MetricUnit = "bytes" | "gas";

export type MetricAggregate = {
  count: number;
  avg: DecimalString;
  median: DecimalString;
  min: DecimalString;
  max: DecimalString;
};

export type ToolVersions = {
  bun?: string;
  forge?: string;
  git?: string;
  hardhat?: string;
  node?: string;
};

export type MetricEnvironment = {
  ci?: boolean;
  deterministic?: boolean;
  toolVersions: ToolVersions;
};

export type GasMetricSample = {
  kind: MetricKind;
  suite: string;
  phase: string;
  metric: string;
  unit: MetricUnit;
  value?: DecimalString;
  gasUsed?: DecimalString;
  runtimeBytes?: DecimalString;
  initcodeBytes?: DecimalString;
  deploymentBytes?: DecimalString;
  contractName?: string;
  artifact?: string;
  address?: `0x${string}`;
  transactionHash?: `0x${string}`;
  functionName?: string;
  selector?: `0x${string}`;
  testName?: string;
  project?: boolean;
  raw?: Record<string, unknown>;
};

export type MetricSummary = {
  key: string;
  label: string;
  suite: string;
  phase: string;
  unit: MetricUnit;
  aggregate: MetricAggregate;
  contractName?: string;
  functionName?: string;
  selector?: `0x${string}`;
  testName?: string;
  project?: boolean;
};

export type MetricReport = {
  schemaVersion: typeof METRICS_SCHEMA_VERSION;
  repo: string;
  commit: string;
  generatedAt: string;
  environment: MetricEnvironment;
  rawSamples: GasMetricSample[];
  summaries: {
    sizes: MetricSummary[];
    deployments: MetricSummary[];
    functions: MetricSummary[];
    testTotals: MetricSummary[];
  };
};

export type MetricDiffEntry = {
  key: string;
  label: string;
  suite: string;
  phase: string;
  unit: MetricUnit;
  status: "added" | "removed" | "changed";
  base?: DecimalString;
  head?: DecimalString;
  delta?: DecimalString;
  percent?: number;
};

export type MetricDiffReport = {
  schemaVersion: typeof METRICS_SCHEMA_VERSION;
  baseCommit: string;
  headCommit: string;
  generatedAt: string;
  unchanged: boolean;
  hardLimitFailures: {
    key: string;
    label: string;
    runtimeBytes: DecimalString;
    limitBytes: DecimalString;
  }[];
  groups: {
    sizes: MetricDiffEntry[];
    deployments: MetricDiffEntry[];
    functions: MetricDiffEntry[];
    testTotals: MetricDiffEntry[];
  };
};

export function decimal(value: bigint | number | string): DecimalString {
  return BigInt(value).toString();
}

export function byteLength(hex: unknown): bigint | undefined {
  if (typeof hex !== "string" || !hex.startsWith("0x")) return undefined;
  return BigInt(Math.max(0, (hex.length - 2) / 2));
}

export function aggregateValues(
  values: (bigint | number | string | undefined)[],
): MetricAggregate | undefined {
  const sorted = values
    .filter((value): value is bigint | number | string => value !== undefined)
    .map((value) => BigInt(value))
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  if (!sorted.length) return undefined;

  const sum = sorted.reduce((total, value) => total + value, 0n);
  const middle = Math.floor(sorted.length / 2);
  const median =
    sorted.length % 2
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2n;

  return {
    count: sorted.length,
    avg: decimal(sum / BigInt(sorted.length)),
    median: decimal(median),
    min: decimal(sorted[0]),
    max: decimal(sorted[sorted.length - 1]),
  };
}

export function buildReport({
  repo,
  commit,
  environment,
  samples,
  generatedAt = new Date().toISOString(),
}: {
  repo: string;
  commit: string;
  environment: MetricEnvironment;
  samples: GasMetricSample[];
  generatedAt?: string;
}): MetricReport {
  return {
    schemaVersion: METRICS_SCHEMA_VERSION,
    repo,
    commit,
    generatedAt,
    environment,
    rawSamples: samples,
    summaries: {
      sizes: summarize(samples, "contract-size", (sample) => ({
        key: sample.contractName ?? sample.artifact ?? sample.metric,
        label: sample.contractName ?? sample.artifact ?? sample.metric,
        value: sample.runtimeBytes ?? sample.value,
      })),
      deployments: summarize(samples, "deployment", (sample) => ({
        key: [
          sample.suite,
          sample.phase,
          sample.contractName ?? sample.address ?? sample.metric,
        ].join(":"),
        label: sample.contractName ?? sample.address ?? sample.metric,
        value: sample.gasUsed ?? sample.value,
      })),
      functions: summarize(samples, "function", (sample) => ({
        key: [
          sample.suite,
          sample.phase,
          sample.contractName ?? sample.address ?? "unknown",
          sample.functionName ?? sample.selector ?? sample.metric,
        ].join(":"),
        label: [
          sample.contractName ?? sample.address ?? "unknown",
          sample.functionName ?? sample.selector ?? sample.metric,
        ].join("."),
        value: sample.gasUsed ?? sample.value,
      })),
      testTotals: summarize(samples, "test-total", (sample) => ({
        key: [
          sample.suite,
          sample.phase,
          sample.testName ?? sample.metric,
        ].join(":"),
        label: sample.testName ?? sample.metric,
        value: sample.gasUsed ?? sample.value,
      })),
    },
  };
}

export function mergeReports({
  reports,
  repo,
  commit,
  environment,
}: {
  reports: MetricReport[];
  repo?: string;
  commit?: string;
  environment?: MetricEnvironment;
}): MetricReport {
  const first = reports[0];
  return buildReport({
    repo: repo ?? first?.repo ?? "",
    commit: commit ?? first?.commit ?? "",
    environment: environment ??
      first?.environment ?? {
        toolVersions: {},
      },
    samples: reports.flatMap((report) => report.rawSamples),
  });
}

function summarize(
  samples: GasMetricSample[],
  kind: MetricKind,
  keyFor: (sample: GasMetricSample) => {
    key: string;
    label: string;
    value?: DecimalString;
  },
): MetricSummary[] {
  const buckets = new Map<
    string,
    {
      label: string;
      samples: GasMetricSample[];
      values: DecimalString[];
    }
  >();

  for (const sample of samples) {
    if (sample.kind !== kind) continue;
    const { key, label, value } = keyFor(sample);
    if (value === undefined) continue;
    const bucket = buckets.get(key) ?? { label, samples: [], values: [] };
    bucket.samples.push(sample);
    bucket.values.push(value);
    buckets.set(key, bucket);
  }

  return Array.from(buckets.entries())
    .flatMap(([key, bucket]) => {
      const aggregate = aggregateValues(bucket.values);
      if (!aggregate) return [];
      const [sample] = bucket.samples;
      return [
        {
          key,
          label: bucket.label,
          suite: sample.suite,
          phase: sample.phase,
          unit: sample.unit,
          aggregate,
          contractName: sample.contractName,
          functionName: sample.functionName,
          selector: sample.selector,
          testName: sample.testName,
          project: bucket.samples.some((item) => item.project),
        },
      ];
    })
    .sort((a, b) => a.key.localeCompare(b.key));
}
