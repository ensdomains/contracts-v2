import hre from "hardhat";
import { describe, expect, it } from "vitest";

import { deployV2Fixture } from "../fixtures/deployV2Fixture.js";

const network = await hre.network.connect();

async function fixture() {
  const v2 = await deployV2Fixture(network, true);
  const renderer = await network.viem.deployContract("StandardURIRenderer", [
    v2.rootRegistry.address,
    v2.labelStore.address,
  ]);
  await v2.ethRegistry.write.setURI(["", renderer.address]);
  return { v2, renderer };
}

// TODO
describe("StandardURIRenderer", () => {
  it("test", async () => {
    const F = await network.networkHelpers.loadFixture(fixture);
    const { tokenId } = await F.v2.setupName({
      name: "test.eth",
    });
    const json = await fetch(await F.v2.ethRegistry.read.uri([tokenId])).then(
      (r) => r.json(),
    );
    console.log(json);
  });
});
