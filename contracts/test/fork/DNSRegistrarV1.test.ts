import { describe, expect, it } from "vitest";
import { zeroAddress } from "viem";
import { forkAndAttach } from "./forkedFixture.js";
import { dnsEncodeName, namehash } from "../utils/utils.js";
import { fetchDNSSECOracleRRSets } from "../../lib/ens-contracts/test/fixtures/dnssecOracle.js";

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

  it("proveAndClaim()", async () => {
    const F = await connection.networkHelpers.loadFixture(fixture);

    const name = "raffy.xyz";
    const account = await F.impersonate(
      "0x51050ec063d393217B436747617aD1C2285Aeeee",
    );
    const rrsets = await fetchDNSSECOracleRRSets(`_ens.${name}`);

    await F.v1.ENSRegistry.write.setOwner([namehash(name), zeroAddress], {
      account,
    });
    await F.v1.DNSRegistrar.write.proveAndClaim([dnsEncodeName(name), rrsets], {
      account,
    });
    await expect(
      F.v1.ENSRegistry.read.owner([namehash(name)]),
    ).resolves.toStrictEqual(account.address);
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
