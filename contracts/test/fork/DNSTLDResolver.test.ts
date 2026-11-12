import { describe, it } from "vitest";
import { forkAndAttach } from "./forkedFixture.js";
import { dnsEncodeName } from "../utils/utils.js";
import { bundleCalls, makeResolutions } from "../utils/resolutions.js";
import { KNOWN_DNS } from "./knownDNS.js";

// USAGE: bun run test:hardhat test/fork/DNSTLDResolver.test.ts
//   env: NEW=<any> => deploys a DNSTLDResolver instead of using latest.

const { connection, forkedFixture } = await forkAndAttach();

async function fixture() {
  const F = await forkedFixture();

  let DNSTLDResolver = F.DNSTLDResolver;
  if (process.env.NEW) {
    console.log("Using new DNSTLDResolver");
    DNSTLDResolver = await connection.viem.deployContract("DNSTLDResolver", [
      F.v1.ENSRegistry.address,
      F.RootRegistry.address,
      F.DNSSECImpl.address,
      F.DNSSECGatewayProvider.address,
      F.BatchGatewayProvider.address,
      F.ContractNamer.address,
    ]);
  }

  return { ...F, DNSTLDResolver };
}

describe("DNSTLDResolver", () => {
  for (const kp of KNOWN_DNS) {
    it(kp.name, async () => {
      const F = await connection.networkHelpers.loadFixture(fixture);
      const bundle = bundleCalls(makeResolutions(kp));
      const answer = await F.DNSTLDResolver.read.resolve([
        dnsEncodeName(kp.name),
        bundle.call,
      ]);
      bundle.expect(answer);
    });
  }
});
