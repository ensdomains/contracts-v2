import { describe, it } from "vitest";
import { forkAndAttach } from "./forkedFixture.js";
import { dnsEncodeName } from "../utils/utils.js";
import { bundleCalls, makeResolutions } from "../utils/resolutions.js";
import { KNOWN_DNS } from "./knownDNS.js";

const { connection, forkedFixture } = await forkAndAttach();

describe("DNSTLDResolver (current)", () => {
  for (const kp of KNOWN_DNS) {
    it(kp.name, async () => {
      const F = await connection.networkHelpers.loadFixture(forkedFixture);
      const bundle = bundleCalls(makeResolutions(kp));
      const answer = await F.DNSTLDResolver.read.resolve([
        dnsEncodeName(kp.name),
        bundle.call,
      ]);
      bundle.expect(answer);
    });
  }
});
