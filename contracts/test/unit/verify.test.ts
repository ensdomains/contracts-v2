import { describe, expect, it } from "bun:test";

import { etherscanRefusals } from "../../script/verify.js";

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
