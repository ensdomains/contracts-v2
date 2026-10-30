import { describe, expect, it } from "vitest";
import { zeroAddress } from "viem";
import { forkAndAttach } from "./forkedFixture.js";
import { expectVar } from "../utils/expectVar.js";
import { bundleCalls, makeResolutions } from "../utils/resolutions.js";
import { dnsEncodeName, getLabelAt, idFromLabel } from "../utils/utils.js";
import {
  DAO_TOKEN_SAFE,
  DAO_WALLET,
  DEPLOYMENT_ROLES,
  STATUS,
} from "../../script/deploy-constants.js";
import { KNOWN_DNS } from "../integration/dns/mainnet.js";

const { connection, forkedFixture } = await forkAndAttach();

async function fixture() {
  const F = await forkedFixture();

  const TemporaryDNSRegistrar = await connection.viem.deployContract(
    "TemporaryDNSRegistrar",
    [
      DAO_WALLET,
      F.v2.RootRegistry.address,
      DAO_TOKEN_SAFE,
      F.v1.SimplePublicSuffixList.address,
      F.v2.DNSTLDResolver.address,
    ],
  );

  // DAO #1: grant TemporaryDNSRegistrar roles on RootRegistry
  await F.v2.RootRegistry.write.grantRootRoles(
    [
      DEPLOYMENT_ROLES.TEMPORARY_DNS_REGISTRAR_ROOT,
      TemporaryDNSRegistrar.address,
    ],
    { account: F.namedAccounts.DAO_WALLET },
  );

  // DAO #2: grant TemporaryDNSRegistrar approval of tokens owned by DAOTokenSafe
  // note: this needs routed through SafeProxy.execTransaction()
  await F.v2.RootRegistry.write.setApprovalForAll(
    [TemporaryDNSRegistrar.address, true],
    { account: F.namedAccounts.DAO_TOKEN_SAFE },
  );

  return { ...F, TemporaryDNSRegistrar };
}

const loadFixture = () => connection.networkHelpers.loadFixture(fixture);

describe("TemporaryDNSRegistrar (before activation)", () => {
  it("syncTLD", async () => {
    const F = await loadFixture();

    const tld = "com";
    const account = F.namedAccounts.DAO_WALLET;

    // current state
    await expect(
      F.v2.RootRegistry.read.getStatus([idFromLabel(tld)]),
      "reserved",
    ).resolves.toStrictEqual(STATUS.RESERVED);

    // sync: reserved => registered + update resolver
    await F.TemporaryDNSRegistrar.write.syncTLD([tld]);
    await expect(
      F.v2.RootRegistry.read.getStatus([idFromLabel(tld)]),
      "registered",
    ).resolves.toStrictEqual(STATUS.REGISTERED);
    await expect(
      F.v2.RootRegistry.read.getResolver([tld]),
      "set resolver",
    ).resolves.toStrictEqual(F.v2.DNSTLDResolver.address);

    // change default resolver
    await F.TemporaryDNSRegistrar.write.setDefaultResolver([zeroAddress], {
      account,
    });

    // sync: update resolver
    await F.TemporaryDNSRegistrar.write.syncTLD([tld]);
    await expect(
      F.v2.RootRegistry.read.getResolver([tld]),
      "updated resolver",
    ).resolves.toStrictEqual(zeroAddress);
  });

  describe("resolve", () => {
    for (const kp of KNOWN_DNS) {
      it(kp.name, async () => {
        const F = await loadFixture();
        await F.TemporaryDNSRegistrar.write.syncTLD([getLabelAt(kp.name, -1)]);
        const bundle = bundleCalls(makeResolutions(kp));
        const [answer, resolver] = await F.UniversalResolver.read.resolve([
          dnsEncodeName(kp.name),
          bundle.call,
        ]);
        expectVar({ resolver }).toEqualAddress(F.v2.DNSTLDResolver.address);
        bundle.expect(answer);
      });
    }
  });
});
