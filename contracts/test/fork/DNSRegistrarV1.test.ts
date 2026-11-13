import { describe, expect, it } from "vitest";
import { forkAndAttach } from "./forkedFixture.js";
import { dnsEncodeName, namehash } from "../utils/utils.js";

const { connection, forkedFixture } = await forkAndAttach();

async function fixture() {
  const F = await forkedFixture();

  await F.executeDAO({
    reason: "remove old DNSRegistrar",
    contract: F.v1.Root,
    functionName: "setController",
    args: ["0xB32cB5677a7C971689228EC835800432B339bA2B", false],
  });

  await F.executeDAO({
    reason: "add new DNSRegistrar",
    contract: F.v1.Root,
    functionName: "setController",
    args: [F.v1.DNSRegistrar.address, true],
  });

  return F;
}

describe("DNSRegistrar", () => {
  it("enableNode()", async () => {
    const F = await connection.networkHelpers.loadFixture(fixture);

    const tld = "com";
    await F.v1.DNSRegistrar.write.enableNode([dnsEncodeName(tld)]);

    await expect(
      F.v1.ENSRegistry.read.resolver([namehash(tld)]),
    ).resolves.toStrictEqual(F.v1.OffchainDNSResolver.address);
  });

  it("resolver()", async () => {
    const F = await connection.networkHelpers.loadFixture(fixture);

    await expect(F.v1.DNSRegistrar.read.resolver()).resolves.toStrictEqual(
      F.v1.OffchainDNSResolver.address,
    );
  });

  it("oracle()", async () => {
    const F = await connection.networkHelpers.loadFixture(fixture);

    await expect(F.v1.DNSRegistrar.read.oracle()).resolves.toStrictEqual(
      F.DNSSECImpl.address,
    );
  });
});
