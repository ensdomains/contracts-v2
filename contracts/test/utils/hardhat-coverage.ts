import { addStatementCoverageInstrumentation } from "@nomicfoundation/edr";
import hre from "hardhat";
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { toHex } from "viem";

// https://github.com/NomicFoundation/hardhat/blob/main/v-next/hardhat/src/internal/builtin-plugins/coverage/hook-handlers/hre.ts
// https://github.com/NomicFoundation/hardhat/blob/main/v-next/hardhat/src/internal/builtin-plugins/coverage/hook-handlers/solidity.ts

// hooks need to be registered super early
const activeTags: Set<string[]> = new Set();
hre.hooks.registerHandlers("network", {
  async onCoverageData(/*statements*/ _, tags) {
    for (const x of activeTags) {
      x.push(...tags);
    }
  },
});

export function injectCoverage() {
  const connect0 = hre.network.connect.bind(hre.network);
  hre.network.connect = async (params: unknown) => {
    if (params) throw new Error("expected just connect()");
    return connect0({ override: { allowUnlimitedContractSize: true } });
  };
}

// WARNING: this code sucks, but so does lcov
// forge and hardhat have different coverage instrumentation
// specifically, forge only marks the first line of a multiline instruction
// whereas, hardhat marks the first line to the semicolon.
// TODO: create forge issue
export function recordCoverage(testName: string) {
  const tags: string[] = [];
  activeTags.add(tags);
  return async () => {
    activeTags.delete(tags);
    if (!tags.length) return;

    const rootDir = new URL("../../", import.meta.url);
    // each instrumented build is recorded in artifacts/build-info/
    // <solc-...>.json, whose input lists every source plus the injected
    // __hardhat_coverage_library_*.sol; re-instrumenting the local sources
    // with that library reproduces the statement tags
    const buildInfoDir = new URL("artifacts/build-info/", rootDir);
    type SourceBuild = {
      sourceName: string;
      inputSourceName: string;
      solcVersion: string;
      coverageLibrary: string;
    };
    const sourceBuilds = new Map<string, SourceBuild>();
    for (const file of await readdir(buildInfoDir)) {
      if (!file.endsWith(".json") || file.endsWith(".output.json")) continue;
      const buildInfo = JSON.parse(
        await readFile(new URL(file, buildInfoDir), { encoding: "utf8" }),
      ) as {
        solcVersion: string;
        input: { sources: Record<string, unknown> };
      };
      const inputSourceNames = Object.keys(buildInfo.input.sources);
      const coverageLibrary = inputSourceNames.find((x) =>
        /^__hardhat_coverage_library_[a-f0-9-]+\.sol$/.test(x),
      );
      if (!coverageLibrary) continue; // not an instrumented build
      const prefix = "project/";
      for (const inputSourceName of inputSourceNames) {
        if (!inputSourceName.startsWith(prefix)) continue;
        if (sourceBuilds.has(inputSourceName)) continue;
        sourceBuilds.set(inputSourceName, {
          sourceName: inputSourceName.slice(prefix.length),
          inputSourceName,
          solcVersion: buildInfo.solcVersion,
          coverageLibrary,
        });
      }
    }
    if (!sourceBuilds.size) {
      throw new Error("expected hardhat coverage library");
    }

    type CodeUnit = { line: number; kind: string; name: string };
    type CodeBlock = CodeUnit & { unit: CodeUnit; id: string };
    type Location = {
      tag: string;
      file: string;
      line0: number;
      line1: number;
      count: number;
      block?: CodeBlock;
    };
    const tagMap = new Map<string, Location>();
    const fileMap = new Map<string, Location[]>();
    for (const rawArtifact of sourceBuilds.values()) {
      const code = await readFile(new URL(rawArtifact.sourceName, rootDir), {
        encoding: "utf8",
      });
      const { metadata } = addStatementCoverageInstrumentation(
        code,
        rawArtifact.inputSourceName, // "project/..."
        rawArtifact.solcVersion, // "0.8.25"
        rawArtifact.coverageLibrary,
      );

      // generate line numbers
      const units: CodeUnit[] = [];
      const blocks: CodeBlock[] = [];
      const lineNumbers = code.split("\n").flatMap((line, j) => {
        const lineNumber = j + 1;
        let match;
        if (
          (match = line.match(
            /^\s*(?:abstract\s+|)(contract|interface|library)\s+([_a-z][_a-z0-9]*)/i,
          ))
        ) {
          units.push({ line: lineNumber, kind: match[1], name: match[2] });
        } else if (
          (match = line.match(
            /^\s*(?:(function|modifier)\s+([_a-z][_a-z0-9]*)|(constructor))\(/i,
          ))
        ) {
          if (!units.length) {
            throw new Error("bug: block before unit");
          }
          const unit = units[units.length - 1];
          const name = match[2] || match[3];
          blocks.push({
            line: lineNumber,
            kind: match[1] || match[3],
            name,
            unit,
            id: `${unit.name}.${name}`,
          });
        }
        return Array.from({ length: line.length + 1 }, () => lineNumber);
      });

      // fix duplicates like forge does
      const buckets = new Map<string, CodeBlock[]>();
      for (const b of blocks) {
        const v = buckets.get(b.id);
        if (v) {
          v.push(b);
        } else {
          buckets.set(b.id, [b]);
        }
      }
      for (const v of buckets.values()) {
        if (v.length > 1) {
          v.forEach((x, i) => (x.id += `.${i}`));
        }
      }

      // convert statements to locations
      let remaining = blocks.slice();
      const locs = metadata
        .filter((x) => x.kind === "statement")
        .map((x) => {
          const line0 = lineNumbers[x.startUtf16];
          const loc: Location = {
            tag: toHex(x.tag).slice(2),
            file: rawArtifact.sourceName,
            line0,
            line1: lineNumbers[x.endUtf16 - 1],
            count: 0,
          };
          // assign the nearest block to the nearest statement
          let i = 0;
          while (i < remaining.length && remaining[i].line < line0) i++;
          if (i) {
            loc.block = remaining[i - 1];
            remaining.splice(0, i);
          }
          return loc;
        });

      // save locations
      const file = rawArtifact.sourceName;
      fileMap.set(file, locs);
      for (const loc of locs) {
        tagMap.set(loc.tag, loc);
      }
    }

    // count location hits
    for (const tag of tags) {
      const loc = tagMap.get(tag);
      if (loc) loc.count++;
    }

    // construct lcov file
    // https://github.com/linux-test-project/lcov/blob/df03ba434eee724bfc2b27716f794d0122951404/man/geninfo.1#L1409
    // https://github.com/NomicFoundation/hardhat/blob/main/v-next/hardhat/src/internal/builtin-plugins/coverage/coverage-manager.ts#L275

    let lcov = `TN:${testName}\n`;

    for (const [file, locs] of fileMap) {
      if (!locs.length) continue;

      // for (const loc of locs) {
      //   for (let i = loc.line0; i <= loc.line1; i++) {
      //     lcov += `BRDA:${i},0,${loc.tag},${loc.count || "-"}\n`;
      //   }
      // }
      // lcov += `BRH:${executedBranchesCount}\n`;
      // lcov += `BRF:${branchExecutionCounts.size}\n`;

      const lineCounts: number[] = [];
      for (const loc of locs) {
        for (let i = loc.line0; i <= loc.line1; i++) {
          lineCounts[i] = (lineCounts[i] ?? 0) + loc.count;
        }
      }

      lcov += `SF:${file}\n`;
      for (const loc of locs) {
        if (loc.block) {
          const count = lineCounts[loc.line0];
          lcov += `DA:${loc.block.line},${count}\n`;
          lcov += `FN:${loc.block.line},${loc.block.id}\n`;
          lcov += `FNDA:${count},${loc.block.id}\n`;
        }
      }
      for (const [line, count] of Object.entries(lineCounts)) {
        if (count) {
          // avoid forge vs hardhat multiline issue
          lcov += `DA:${line},${count}\n`;
        }
      }
      lcov += "end_of_record\n";
    }

    // write file
    const outDir = new URL("coverage/", rootDir);
    await mkdir(outDir, { recursive: true });
    await writeFile(new URL(`${testName}.lcov`, outDir), lcov);
    console.log(`Wrote Coverage: ${testName}`);
  };
}
