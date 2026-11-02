import { describe, it } from "vitest";
import { forkAndAttach } from "./forkedFixture.js";
import { dnsEncodeName } from "../utils/utils.js";
import {
  bundleCalls,
  KnownProfile,
  makeResolutions,
} from "../utils/resolutions.js";
import { KNOWN_DNS } from "./knownDNS.js";

const { connection, forkedFixture } = await forkAndAttach();

async function fixture() {
  const F = await forkedFixture();

  const newDNSTLDResolver = await connection.viem.deployContract(
    "DNSTLDResolver",
    [
      F.v1.ENSRegistry.address,
      F.RootRegistry.address,
      F.DNSSECImpl.address,
      F.DNSSECGatewayProvider.address,
      F.BatchGatewayProvider.address,
      F.ContractNamer.address,
    ],
  );

  return { ...F, newDNSTLDResolver };
}

describe("DNSTLDResolver (new)", () => {
  for (const kp of KNOWN_DNS.reverse()) {
    it(kp.name, async () => {
      const F = await connection.networkHelpers.loadFixture(fixture);
      const bundle = bundleCalls(makeResolutions(kp));
      const answer = await F.newDNSTLDResolver.read.resolve([
        dnsEncodeName(kp.name),
        bundle.call,
      ]);
      bundle.expect(answer);
    });
  }
});
