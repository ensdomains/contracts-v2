import { describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { keccak256, toBytes } from "viem";

import {
  backfillSourceContent,
  etherscanRefusals,
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
