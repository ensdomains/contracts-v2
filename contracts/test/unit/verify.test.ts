import { describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { keccak256, toBytes } from "viem";

import {
  backfillSourceContent,
  etherscanRefusals,
  parseArgs,
  recordFiles,
  selectTargets,
} from "../../script/verify.js";

describe("etherscanRefusals", () => {
  it("names each contract Etherscan refused", () => {
    const output = [
      "verifying BatchRegistrar (0x4a4c) ...",
      'contract BatchRegistrar failed to submit : "NOTOK" : "Max calls per sec rate limit reached (3/sec)" {"status":"0"}',
      " => contract ETHRegistry is now verified",
      'contract LabelStore failed to submit : "NOTOK" : "Max calls per sec rate limit reached (3/sec)" {"status":"0"}',
    ].join("\n");

    expect(etherscanRefusals(output)).toEqual(["BatchRegistrar", "LabelStore"]);
  });

  it("names each contract Etherscan accepted but failed to verify", () => {
    const output = [
      "waiting for result...",
      "Failed to verify contract DNSTLDResolver: NOTOK, Fail - Unable to verify",
      "Etherscan failed to verify the source provided",
    ].join("\n");

    expect(etherscanRefusals(output)).toEqual(["DNSTLDResolver"]);
  });

  // Etherscan reports an already-verified contract as a failed submission; it
  // needs nothing more, so it is not a refusal.
  it("ignores a contract that is verified already", () => {
    const output =
      'contract DNSTXTResolver failed to submit : "NOTOK" : "Contract source code already verified" {"status":"0"}';

    expect(etherscanRefusals(output)).toEqual([]);
  });

  it("finds nothing in a clean run", () => {
    expect(
      etherscanRefusals(
        "already verified: PublicResolverV2 (0xdc4a), skipping.\n => contract ETHRenewerV1 is now verified",
      ),
    ).toEqual([]);
  });
});

describe("backfillSourceContent", () => {
  // A source no longer on disk in the form a kept contract was built from.
  const sourceKey = "project/src/KeptAcrossAChange.sol";
  const built = "contract KeptAcrossAChange { uint256 constant VERSION = 1; }";

  const record = (buildContent: string) => {
    const dir = mkdtempSync(join(tmpdir(), "verify-backfill-"));
    mkdirSync(join(dir, "build-info"));
    writeFileSync(
      join(dir, "build-info", "solc-build.json"),
      JSON.stringify({
        input: { sources: { [sourceKey]: { content: buildContent } } },
      }),
    );
    const path = join(dir, "Kept.json");
    writeFileSync(
      path,
      JSON.stringify({
        contractName: "Kept",
        buildInfoId: "solc-build",
        metadata: JSON.stringify({
          compiler: { version: "0.8.25" },
          sources: { [sourceKey]: { keccak256: keccak256(toBytes(built)) } },
        }),
      }),
    );
    return path;
  };

  it("takes a missing source from the build the record was made from", () => {
    const path = record(built);
    expect(backfillSourceContent(path)).toBe(true);
    const metadata = JSON.parse(
      JSON.parse(readFileSync(path, "utf8")).metadata,
    );
    expect(metadata.sources[sourceKey].content).toBe(built);
  });

  it("ignores build input that does not hash to the recorded source", () => {
    expect(() => backfillSourceContent(record(`${built} `))).toThrow(
      "not found",
    );
  });
});

describe("--contract", () => {
  const deploymentSet = (...names: string[]) => {
    const dir = mkdtempSync(join(tmpdir(), "verify-select-"));
    writeFileSync(join(dir, ".chain"), JSON.stringify({ chainId: "1" }));
    for (const name of names) writeFileSync(join(dir, `${name}.json`), "{}");
    return dir;
  };
  const target = (srcDir: string) => ({
    srcDir,
    envName: "net",
    label: srcDir,
  });

  it("collects each named contract", () => {
    const { contracts, passthrough } = parseArgs([
      "--network",
      "mainnet-adhoc",
      "--contract",
      "DNSTLDResolver",
      "--contract",
      "ENSV2Resolver",
      "--min-interval",
      "1000",
    ]);
    expect(contracts).toEqual(["DNSTLDResolver", "ENSV2Resolver"]);
    expect(passthrough).toEqual(["--min-interval", "1000"]);
  });

  it("keeps every record when no contract is named", () => {
    const dir = deploymentSet("A", "B");
    expect(recordFiles(dir, []).sort()).toEqual(["A.json", "B.json"]);
  });

  it("keeps only the named records", () => {
    const dir = deploymentSet("A", "B", "B_Implementation");
    expect(recordFiles(dir, ["B"])).toEqual(["B.json"]);
  });

  it("drops the sets that hold none of the named contracts", () => {
    const v2 = deploymentSet("A");
    const v1 = deploymentSet("B");
    expect(selectTargets([target(v2), target(v1)], ["B"])).toEqual([
      target(v1),
    ]);
  });

  it("refuses a name that no set holds", () => {
    const dir = deploymentSet("A");
    expect(() => selectTargets([target(dir)], ["Missing"])).toThrow(
      "no record named Missing",
    );
  });
});
