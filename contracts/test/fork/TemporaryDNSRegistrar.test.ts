import { describe, expect, it } from "vitest";
import { zeroAddress } from "viem";
import { encodeFunctionData } from "viem/utils";
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
import { KNOWN_DNS } from "./knownDNS.js";

// USAGE: bun run test:hardhat test/fork/TemporaryDNSRegistrar.test.ts
//   env: NEW=<any> => deploys a TemporaryDNSRegistrar instead of using latest.

const { connection, forkedFixture } = await forkAndAttach();

async function fixture() {
  const F = await forkedFixture();

  let TemporaryDNSRegistrar = F.TemporaryDNSRegistrar;
  if (process.env.NEW) {
    console.log("Using new TemporaryDNSRegistrar");
    TemporaryDNSRegistrar = await connection.viem.deployContract(
      "TemporaryDNSRegistrar",
      [
        DAO_WALLET,
        F.RootRegistry.address,
        DAO_TOKEN_SAFE,
        F.SimplePublicSuffixList.address,
        F.DNSTLDResolver.address,
      ],
    );
  }

  if (
    !(await F.RootRegistry.read.hasRootRoles([
      DEPLOYMENT_ROLES.TEMPORARY_DNS_REGISTRAR_ROOT,
      TemporaryDNSRegistrar.address,
    ]))
  ) {
    await F.executeDAO({
      reason: "grant TemporaryDNSRegistrar roles on RootRegistry",
      contract: F.RootRegistry,
      functionName: "grantRootRoles",
      args: [
        DEPLOYMENT_ROLES.TEMPORARY_DNS_REGISTRAR_ROOT,
        TemporaryDNSRegistrar.address,
      ],
    });

    await F.executeDAO({
      reason:
        "grant TemporaryDNSRegistrar approval of tokens owned by DAOTokenSafe",
      contract: F.DAOTokenSafe,
      functionName: "execTransaction",
      args: F.safeProxyCallArguments(
        F.RootRegistry.address,
        encodeFunctionData({
          abi: F.RootRegistry.abi,
          functionName: "setApprovalForAll",
          args: [TemporaryDNSRegistrar.address, true],
        }),
      ),
    });
  }

  return { ...F, TemporaryDNSRegistrar };
}

const loadFixture = () => connection.networkHelpers.loadFixture(fixture);

describe("TemporaryDNSRegistrar", () => {
  it("syncTLD", async () => {
    const F = await loadFixture();

    const tld = "com";
    const account = F.namedAccounts.DAO_WALLET;

    // current state
    await expect(
      F.RootRegistry.read.getStatus([idFromLabel(tld)]),
      "reserved",
    ).resolves.toStrictEqual(STATUS.RESERVED);

    // sync: reserved => registered + update resolver
    await F.TemporaryDNSRegistrar.write.syncTLD([tld]);
    await expect(
      F.RootRegistry.read.getStatus([idFromLabel(tld)]),
      "registered",
    ).resolves.toStrictEqual(STATUS.REGISTERED);
    await expect(
      F.RootRegistry.read.getResolver([tld]),
      "set resolver",
    ).resolves.toStrictEqual(F.DNSTLDResolver.address);

    // change default resolver
    await F.TemporaryDNSRegistrar.write.setDefaultResolver([zeroAddress], {
      account,
    });

    // sync: update resolver
    await F.TemporaryDNSRegistrar.write.syncTLD([tld]);
    await expect(
      F.RootRegistry.read.getResolver([tld]),
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
        expectVar({ resolver }).toEqualAddress(F.DNSTLDResolver.address);
        bundle.expect(answer);
      });
    }
  });
});
