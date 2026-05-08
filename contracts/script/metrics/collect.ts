import { execFileSync } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import {
  buildReport,
  mergeReports,
  type GasMetricSample,
  type MetricEnvironment,
  type MetricReport,
} from "./schema.js";

export const DEFAULT_METRICS_DIR = "metrics";

export function projectOnly(pathOrName: string | undefined): boolean {
  if (!pathOrName) return false;
  return normalizeSourcePath(pathOrName).startsWith("src/");
}

export function normalizeSourcePath(pathOrName: string): string {
  return pathOrName.replaceAll("\\", "/").replace(/^project\//, "");
}

export async function writeJson(path: string, value: unknown) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`);
}

export async function writeMetricReport({
  path,
  samples,
  suite,
}: {
  path: string;
  samples: GasMetricSample[];
  suite?: string;
}): Promise<MetricReport> {
  const report = buildReport({
    repo: commandOutput("git", ["config", "--get", "remote.origin.url"]),
    commit: commandOutput("git", ["rev-parse", "HEAD"]),
    environment: collectEnvironment(),
    samples: samples.map((sample) => ({
      ...sample,
      suite: sample.suite || suite || "unknown",
    })),
  });
  await writeJson(path, report);
  return report;
}

export function collectEnvironment(): MetricEnvironment {
  return {
    ci: process.env.CI === "true",
    deterministic: process.env.GAS_METRICS === "1",
    toolVersions: {
      bun: commandOutput("bun", ["--version"]),
      forge: firstLine(commandOutput("forge", ["--version"])),
      git: commandOutput("git", ["--version"]),
      hardhat: commandOutput("bun", ["hardhat", "--version"]),
      node: commandOutput("node", ["--version"]),
    },
  };
}

export function commandOutput(command: string, args: string[]): string {
  try {
    return execFileSync(command, args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "";
  }
}

export function firstLine(value: string): string {
  return value.split(/\r?\n/, 1)[0] ?? value;
}

async function main() {
  const args = process.argv.slice(2);
  const outIndex = args.indexOf("--out");
  const out =
    outIndex >= 0
      ? args.splice(outIndex, 2)[1]
      : `${DEFAULT_METRICS_DIR}/contract-metrics.json`;
  const inputPaths = args.length
    ? args
    : [
        `${DEFAULT_METRICS_DIR}/foundry.json`,
        `${DEFAULT_METRICS_DIR}/deploy.json`,
        `${DEFAULT_METRICS_DIR}/hardhat.json`,
        `${DEFAULT_METRICS_DIR}/e2e.json`,
      ];

  const reports: MetricReport[] = [];
  for (const path of inputPaths) {
    try {
      reports.push(JSON.parse(await readFile(path, "utf8")) as MetricReport);
    } catch (err) {
      if (args.length) throw err;
    }
  }

  if (!reports.length) {
    throw new Error("no metrics reports found");
  }

  const report = mergeReports({
    reports,
    repo: commandOutput("git", ["config", "--get", "remote.origin.url"]),
    commit: commandOutput("git", ["rev-parse", "HEAD"]),
    environment: collectEnvironment(),
  });
  await writeJson(out, report);
  console.log(`Wrote ${out}`);
}

if (import.meta.main) {
  await main();
}
