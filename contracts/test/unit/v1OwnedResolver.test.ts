import { describe, expect, it } from "bun:test";
import type { Address } from "viem";

import { extensions } from "../../rocketh/config.js";

// The `.eth` resolver each network used before any ENSv2 mirror replaced it. The
// bundled sepolia artifact names a different OwnedResolver that `.eth` never pointed
// at, so the local override must win the lookup.
const MAINNET_ETH_RESOLVER: Address =
  "0x30200E0cb040F38E474E53EF437c95A1bE723b2B";
const SEPOLIA_ETH_RESOLVER: Address =
  "0x60C7C2A24b5e86C38639Fd1586917a8FEF66a56d";

const getV1For = (name: string, extra?: Record<string, unknown>) =>
  extensions.getV1({ name, extra, deployments: {} } as never);

describe("v1 OwnedResolver lookup", () => {
  it.each([
    ["mainnet", undefined, MAINNET_ETH_RESOLVER],
    ["mainnet-fork", { v1DeploymentNetwork: "mainnet" }, MAINNET_ETH_RESOLVER],
    ["devnet-1", { v1DeploymentNetwork: "mainnet" }, MAINNET_ETH_RESOLVER],
    ["sepolia", undefined, SEPOLIA_ETH_RESOLVER],
    ["sepolia-dev", undefined, SEPOLIA_ETH_RESOLVER],
  ] as const)("resolves the ENSv1 .eth resolver for %s", async (name, extra, expected) => {
    const deployment = await getV1For(name, extra)("OwnedResolver");
    expect(deployment.address).toBe(expected);
  });
});
