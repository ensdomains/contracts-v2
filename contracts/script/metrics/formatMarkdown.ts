import type {
  MetricDiffEntry,
  MetricDiffReport,
  MetricUnit,
} from "./schema.js";

export const PR_COMMENT_MARKER = "<!-- ens-contract-metrics -->";

const GROUP_LABELS = {
  sizes: "Contract size",
  deployments: "Deployment gas",
  functions: "Function call gas",
  testTotals: "E2E totals",
} as const;

export function formatMarkdown(diff: MetricDiffReport): string {
  const lines = [
    PR_COMMENT_MARKER,
    "### Contract Metrics",
    "",
    `Base \`${shortCommit(diff.baseCommit)}\` -> head \`${shortCommit(
      diff.headCommit,
    )}\`. Full raw samples are attached to this workflow run as JSON artifacts.`,
    "",
  ];

  if (diff.hardLimitFailures.length) {
    lines.push("Hard limit failures:", "");
    for (const failure of diff.hardLimitFailures) {
      lines.push(
        `- ${failure.label}: ${formatNumber(
          failure.runtimeBytes,
        )} bytes exceeds ${formatNumber(failure.limitBytes)} bytes`,
      );
    }
    lines.push("");
  }

  if (diff.unchanged) {
    lines.push("contract metrics unchanged.");
    return `${lines.join("\n")}\n`;
  }

  appendGroup(lines, GROUP_LABELS.sizes, diff.groups.sizes);
  appendGroup(lines, GROUP_LABELS.deployments, diff.groups.deployments);
  appendGroup(lines, GROUP_LABELS.functions, diff.groups.functions);
  appendGroup(lines, GROUP_LABELS.testTotals, diff.groups.testTotals);

  return `${lines.join("\n")}\n`;
}

function appendGroup(
  lines: string[],
  label: string,
  entries: MetricDiffEntry[],
) {
  if (!entries.length) return;

  const shown = entries
    .slice()
    .sort((a, b) => absDelta(b) - absDelta(a))
    .slice(0, 8);

  lines.push(`#### ${label}`, "");
  lines.push("| Metric | Base | Head | Delta |");
  lines.push("| --- | ---: | ---: | ---: |");

  for (const entry of shown) {
    lines.push(
      `| ${escapePipe(entry.label)} | ${formatValue(
        entry.base,
        entry.unit,
      )} | ${formatValue(entry.head, entry.unit)} | ${formatDelta(
        entry.delta,
        entry.unit,
      )} |`,
    );
  }

  if (entries.length > shown.length) {
    lines.push(
      `| _${entries.length - shown.length} more in artifacts_ |  |  |  |`,
    );
  }
  lines.push("");
}

function formatValue(value: string | undefined, unit: MetricUnit): string {
  if (value === undefined) return "-";
  return `${formatNumber(value)}${unit === "bytes" ? " B" : ""}`;
}

function formatDelta(value: string | undefined, unit: MetricUnit): string {
  if (value === undefined) return "-";
  const big = BigInt(value);
  const sign = big > 0n ? "+" : "";
  return `${sign}${formatNumber(value)}${unit === "bytes" ? " B" : ""}`;
}

function formatNumber(value: string): string {
  const big = BigInt(value);
  const sign = big < 0n ? "-" : "";
  const digits = (big < 0n ? -big : big).toString();
  return `${sign}${digits.replace(/\B(?=(\d{3})+(?!\d))/g, ",")}`;
}

function absDelta(entry: MetricDiffEntry): number {
  if (!entry.delta) return 0;
  const value = BigInt(entry.delta);
  return Number(value < 0n ? -value : value);
}

function escapePipe(value: string): string {
  return value.replaceAll("|", "\\|");
}

function shortCommit(commit: string): string {
  return commit.slice(0, 12) || "unknown";
}
