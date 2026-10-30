import { forkAndAttach } from "./forkedFixture.ts";
import { describe, it } from "vitest";
import { dnsEncodeName } from "../utils/utils.js";
import { bundleCalls, makeResolutions } from "../utils/resolutions.js";
import { KNOWN_DNS } from "../integration/dns/mainnet.js";

const { connection, forkedFixture } = await forkAndAttach();

describe("DNSTLDResolver (isolated)", () => {
  for (const kp of KNOWN_DNS) {
    it(kp.name, async () => {
      const F = await connection.networkHelpers.loadFixture(forkedFixture);
      const bundle = bundleCalls(makeResolutions(kp));
      const answer = await F.v2.DNSTLDResolver.read.resolve([
        dnsEncodeName(kp.name),
        bundle.call,
      ]);
      bundle.expect(answer);
    });
  }
});
