import { execFileSync } from "node:child_process";
import { readdir, readFile } from "node:fs/promises";
import { basename, join, relative } from "node:path";
import {
  DEFAULT_METRICS_DIR,
  normalizeSourcePath,
  projectOnly,
  writeMetricReport,
} from "./collect.js";
import { byteLength, decimal, type GasMetricSample } from "./schema.js";

type FoundryArtifact = {
  contractName?: string;
  sourceName?: string;
  abi?: unknown;
  bytecode?: { object?: string } | string;
  deployedBytecode?: { object?: string } | string;
  inputSourceName?: string;
  metadata?: {
    settings?: {
      compilationTarget?: Record<string, string>;
    };
    sources?: Record<string, unknown>;
  };
  rawMetadata?: string;
};

const OUT_FILE =
  process.env.METRICS_OUTPUT ?? `${DEFAULT_METRICS_DIR}/foundry.json`;
const FOUNDRY_FUZZ_SEED =
  process.env.FOUNDRY_FUZZ_SEED ??
  "0x0000000000000000000000000000000000000000000000000000000000000001";

async function main() {
  const samples: GasMetricSample[] = [];

  delete process.env.COVERAGE;
  execFileSync("forge", ["clean"], { stdio: "inherit" });
  execFileSync("forge", ["build"], { stdio: "inherit" });
  const gasReport = execFileSync(
    "forge",
    ["test", "--gas-report", "--fuzz-seed", FOUNDRY_FUZZ_SEED],
    {
      encoding: "utf8",
      env: metricsEnv({ FOUNDRY_FUZZ_SEED }),
      stdio: ["ignore", "pipe", "inherit"],
    },
  );
  process.stdout.write(gasReport);

  samples.push(...parseFoundryGasReport(gasReport));
  samples.push(...(await collectArtifactSizes("out")));

  await writeMetricReport({
    path: OUT_FILE,
    samples,
    suite: "foundry",
  });
  console.log(`Wrote ${OUT_FILE}`);
}

export function parseFoundryGasReport(output: string): GasMetricSample[] {
  const samples: GasMetricSample[] = [];
  let current:
    | {
        sourceName?: string;
        contractName: string;
        project: boolean;
      }
    | undefined;
  let mode: "deployment" | "function" | undefined;
  let functionHeader:
    | {
        name: number;
        min: number;
        avg: number;
        median: number;
        max: number;
        calls: number;
      }
    | undefined;

  for (const line of output.split(/\r?\n/)) {
    const cells = splitTableRow(line);
    if (!cells.length) continue;

    const contract = parseContractHeader(cells[0]);
    if (contract) {
      current = contract;
      mode = undefined;
      functionHeader = undefined;
      continue;
    }

    if (!current) continue;
    if (cells.some((cell) => cell === "Deployment Cost")) {
      mode = "deployment";
      continue;
    }

    if (cells.some((cell) => cell === "Function Name")) {
      mode = "function";
      functionHeader = {
        name: cells.findIndex((cell) => cell === "Function Name"),
        min: cells.findIndex((cell) => cell === "Min"),
        avg: cells.findIndex((cell) => cell === "Avg"),
        median: cells.findIndex((cell) => cell === "Median"),
        max: cells.findIndex((cell) => cell === "Max"),
        calls: cells.findIndex((cell) => cell === "# Calls"),
      };
      continue;
    }

    if (mode === "deployment" && isInteger(cells[0])) {
      samples.push({
        kind: "deployment",
        suite: "foundry",
        phase: "forge-gas-report",
        metric: "deployment-gas",
        unit: "gas",
        gasUsed: numericCell(cells[0]),
        deploymentBytes: numericCell(cells[1]),
        contractName: current.contractName,
        artifact: current.sourceName,
        project: current.project,
        raw: { row: cells },
      });
      mode = undefined;
      continue;
    }

    if (
      mode === "function" &&
      functionHeader &&
      isInteger(cells[functionHeader.avg])
    ) {
      const functionName = cells[functionHeader.name];
      samples.push({
        kind: "function",
        suite: "foundry",
        phase: "forge-gas-report",
        metric: "function-gas",
        unit: "gas",
        gasUsed: numericCell(cells[functionHeader.avg]),
        contractName: current.contractName,
        functionName,
        artifact: current.sourceName,
        project: current.project,
        raw: {
          min: numericCell(cells[functionHeader.min]),
          avg: numericCell(cells[functionHeader.avg]),
          median: numericCell(cells[functionHeader.median]),
          max: numericCell(cells[functionHeader.max]),
          calls: numericCell(cells[functionHeader.calls]),
          row: cells,
        },
      });
    }
  }

  return samples;
}

async function collectArtifactSizes(
  outDir: string,
): Promise<GasMetricSample[]> {
  const paths = await findJsonFiles(outDir);
  const samples: GasMetricSample[] = [];

  for (const path of paths) {
    if (path.includes(`${outDir}/build-info/`)) continue;
    let artifact: FoundryArtifact;
    try {
      artifact = JSON.parse(await readFile(path, "utf8")) as FoundryArtifact;
    } catch {
      continue;
    }

    const contractName =
      artifact.contractName ?? basename(path).replace(/\.json$/, "");
    const sourceName = sourceNameForArtifact(
      artifact,
      contractName,
      outDir,
      path,
    );
    const runtimeBytes = byteLength(bytecodeObject(artifact.deployedBytecode));
    const initcodeBytes = byteLength(bytecodeObject(artifact.bytecode));
    if (runtimeBytes === undefined && initcodeBytes === undefined) continue;

    samples.push({
      kind: "contract-size",
      suite: "foundry",
      phase: "forge-artifact",
      metric: "runtime-bytes",
      unit: "bytes",
      value: runtimeBytes === undefined ? undefined : decimal(runtimeBytes),
      runtimeBytes:
        runtimeBytes === undefined ? undefined : decimal(runtimeBytes),
      initcodeBytes:
        initcodeBytes === undefined ? undefined : decimal(initcodeBytes),
      contractName,
      artifact: sourceName,
      project: projectOnly(sourceName),
    });
  }

  return samples;
}

async function findJsonFiles(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true });
  const nested = await Promise.all(
    entries.map(async (entry) => {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) return findJsonFiles(path);
      if (entry.isFile() && entry.name.endsWith(".json")) return [path];
      return [];
    }),
  );
  return nested.flat();
}

function splitTableRow(line: string): string[] {
  const clean = line
    .replace(/\x1b\[[0-9;]*m/g, "")
    .replace(/[╭╮╰╯├┤┬┴─═╞╡╪╫]/g, "");
  if (clean.includes("│")) {
    return clean
      .split("│")
      .map((cell) => cell.trim())
      .filter(Boolean);
  }
  if (clean.includes("|")) {
    return clean
      .split("|")
      .map((cell) => cell.trim())
      .filter(Boolean);
  }
  return [];
}

function parseContractHeader(
  cell: string,
): { sourceName?: string; contractName: string; project: boolean } | undefined {
  const match = cell.match(/^(.+?)(?:\s+contract)?$/);
  if (!match || !cell.includes(":") || !/\bcontract$/.test(cell)) {
    return undefined;
  }
  const withoutSuffix = match[1].replace(/\s+contract$/, "");
  const [sourceName, contractName] = withoutSuffix.split(":");
  if (!contractName) return undefined;
  return {
    sourceName,
    contractName,
    project: projectOnly(sourceName),
  };
}

function isInteger(value: unknown): value is string {
  return typeof value === "string" && /^\d[\d,]*$/.test(value);
}

function numericCell(value: string | undefined): string | undefined {
  return isInteger(value) ? decimal(value.replaceAll(",", "")) : undefined;
}

function bytecodeObject(
  value: FoundryArtifact["bytecode"],
): string | undefined {
  if (typeof value === "string") return value;
  return value?.object;
}

function inferSourceName(outDir: string, path: string): string {
  const rel = relative(outDir, path);
  const [sourceFile] = rel.split("/");
  return sourceFile ?? rel;
}

function sourceNameForArtifact(
  artifact: FoundryArtifact,
  contractName: string,
  outDir: string,
  path: string,
): string {
  const metadata = artifact.metadata ?? rawMetadata(artifact.rawMetadata);
  const sourceName =
    artifact.sourceName ??
    compilationTargetSource(metadata, contractName) ??
    artifact.inputSourceName ??
    inferSourceName(outDir, path);
  return normalizeSourcePath(sourceName);
}

function rawMetadata(
  value: FoundryArtifact["rawMetadata"],
): FoundryArtifact["metadata"] | undefined {
  if (!value) return undefined;
  try {
    return JSON.parse(value) as FoundryArtifact["metadata"];
  } catch {
    return undefined;
  }
}

function compilationTargetSource(
  metadata: FoundryArtifact["metadata"],
  contractName: string,
): string | undefined {
  const targets = metadata?.settings?.compilationTarget;
  if (!targets) return undefined;
  for (const [sourceName, targetContract] of Object.entries(targets)) {
    if (targetContract === contractName) return sourceName;
  }
}

function metricsEnv(extra: Record<string, string>): NodeJS.ProcessEnv {
  const env = Object.fromEntries(
    Object.entries(process.env).filter(
      (entry): entry is [string, string] => typeof entry[1] === "string",
    ),
  );
  return { ...env, ...extra };
}

if (import.meta.main) {
  await main();
}
