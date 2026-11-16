import { describe, expect, it } from "bun:test";
import { getAddress } from "viem";

import { config as rockethConfig } from "../../rocketh/config.js";
import { NETWORKS } from "../../script/migrations/plumbing.js";

const MAINNET_SECURITY_COUNCIL = "0x7101B78638e34444F0a5AdE9e1149fbEeC029931";

describe("managed URP admin defaults", () => {
  it("is the ENS DAO Security Council on mainnet", () => {
    expect(NETWORKS.mainnet.defaultUrManager).toBe(
      getAddress(MAINNET_SECURITY_COUNCIL),
    );
  });

  it("follows the sepolia securityCouncil account", () => {
    expect(NETWORKS.sepolia.defaultUrManager).toBe(
      getAddress(rockethConfig.accounts.securityCouncil.sepolia),
    );
  });

  // rocketh resolves an account by environment name, then chain id, then default.
  // The local devnet runs as chain 1 under its own environment name, so a chain-1
  // key would hand the devnet's managed URP to the council.
  it("is never keyed by mainnet's chain id", () => {
    expect(Object.keys(rockethConfig.accounts.securityCouncil)).not.toContain(
      "1",
    );
    expect(rockethConfig.accounts.securityCouncil.default).toBe("deployer");
  });
});
