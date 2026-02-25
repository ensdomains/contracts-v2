import { shouldSupportInterfaces } from "@ensdomains/hardhat-chai-matchers-viem/behaviour";
import hre from "hardhat";
import {
  type Address,
  concat,
  encodeErrorResult,
  getAddress,
  namehash,
  stringToHex,
  zeroAddress,
} from "viem";
import { describe, expect, it } from "vitest";

import { expectVar } from "../../utils/expectVar.js";
import {
  type KnownProfile,
  bundleCalls,
  COIN_TYPE_DEFAULT,
  COIN_TYPE_ETH,
  makeResolutions,
} from "../../utils/resolutions.ts";
import { shouldSupportFeatures } from "../../utils/supportsFeatures.js";
import { dnsEncodeName } from "../../utils/utils.js";
import { deployV1Fixture } from "../fixtures/deployV1Fixture.js";
import { deployV2Fixture } from "../fixtures/deployV2Fixture.js";
import { deployArtifact } from "../fixtures/deployArtifact.js";
import { encodeRRs, makeTXT } from "./rr.js";
import { FEATURES } from "../../../lib/ens-contracts/test/utils/features.js";

const network = await hre.network.connect();

const dnsTXTResolverName = "dnstxt.ens.eth";
const extendedDNSResolverName = "dnsname.ens.eth";
const dummyBytes4 = "0x12345678";
const testAddress = "0x8000000000000000000000000000000000000001";
const testURL = "https://ens.domains";
const basicProfile: KnownProfile = {
  name: "test.com",
  addresses: [{ coinType: COIN_TYPE_ETH, value: testAddress }],
};

// sufficient to satisfy: `abi.decode(DNSSEC.RRSetWithSignature[])`
const dnsOracleGateway =
  'data:application/json,{"data":"0x0000000000000000000000000000000000000000000000000000000000000000"}';

async function fixture() {
  const mainnetV1 = await deployV1Fixture(network);
  const mainnetV2 = await deployV2Fixture(network, true); // CCIP on UR
  const ssResolver = await network.viem.deployContract(
    "DummyShapeshiftResolver",
  );
  const mockDNSSEC = await network.viem.deployContract("MockDNSSEC");
  const dnsTLDResolverV1 = await network.viem.deployContract(
    "OffchainDNSResolver",
    [mainnetV1.ensRegistry.address, mockDNSSEC.address, dnsOracleGateway],
  );
  const oracleGatewayProvider = await network.viem.deployContract(
    "GatewayProvider",
    [mainnetV2.walletClient.account.address, [dnsOracleGateway]],
  );
  const ownedResolver = await mainnetV2.deployPermissionedResolver();
  const dnsTLDResolver = await network.viem.deployContract("DNSTLDResolver", [
    mainnetV1.ensRegistry.address,
    dnsTLDResolverV1.address,
    mainnetV2.rootRegistry.address,
    mockDNSSEC.address,
    oracleGatewayProvider.address,
    mainnetV2.batchGatewayProvider.address,
  ]);
  await mainnetV1.setupName({
    name: "com",
    resolverAddress: dnsTLDResolverV1.address,
  });
  await mainnetV2.setupName({
    name: "com",
    resolverAddress: dnsTLDResolver.address,
  });
  const dnsTXTResolver = await network.viem.deployContract("DNSTXTResolver");
  await setupNamedResolver(dnsTXTResolverName, dnsTXTResolver.address);
  const dnsAliasResolver = await network.viem.deployContract(
    "DNSAliasResolver",
    [mainnetV2.rootRegistry.address, mainnetV2.batchGatewayProvider.address],
  );
  const extendedDNSResolverAddress = await deployArtifact(
    mainnetV2.walletClient,
    {
      file: new URL(
        "./ExtendedDNSResolver_53f64de872aad627467a34836be1e2b63713a438.json",
        import.meta.url,
      ),
    },
  );
  await setupNamedResolver(extendedDNSResolverName, extendedDNSResolverAddress);
  return {
    mainnetV1,
    mainnetV2,
    ssResolver,
    mockDNSSEC,
    dnsTLDResolverV1,
    oracleGatewayProvider,
    ownedResolver,
    dnsTLDResolver,
    dnsTXTResolver,
    dnsAliasResolver,
    extendedDNSResolverAddress,
    expectTXT,
    expectGasless,
    expectResolution,
    setupNamedResolver,
  };
  function expectTXT(kp: KnownProfile) {
    return expectGasless(kp, dnsTXTResolver.address);
  }
  function expectGasless(kp: KnownProfile, resolverAddress: Address) {
    return expectResolution(kp, resolverAddress, true);
  }
  async function expectResolution(
    kp: KnownProfile,
    resolverAddress: Address,
    gasless = false,
  ) {
    const bundle = bundleCalls(makeResolutions(kp));
    const [answer, resolver] = await mainnetV2.universalResolver.read.resolve([
      dnsEncodeName(kp.name),
      bundle.call,
    ]);
    expectVar({ resolver }).toEqualAddress(dnsTLDResolver.address);
    bundle.expect(answer);
    const directAnswer = await dnsTLDResolver.read.resolve([
      dnsEncodeName(kp.name),
      bundle.call,
    ]);
    expectVar({ directAnswer }).toStrictEqual(answer);
    await expect(
      dnsTLDResolver.read.requiresOffchain([dnsEncodeName(kp.name)]),
    ).resolves.toStrictEqual(gasless);
    await expect(
      dnsTLDResolver.read.getResolver([dnsEncodeName(kp.name)]),
    ).resolves.toStrictEqual([getAddress(resolverAddress), gasless]);
  }
  async function setupNamedResolver(name: string, resolver: Address) {
    await mainnetV2.setupName({
      name,
      resolverAddress: ownedResolver.address,
    });
    await ownedResolver.write.setAddr([
      namehash(name),
      COIN_TYPE_ETH,
      resolver,
    ]);
  }
}

describe("DNSTLDResolver", () => {
  shouldSupportInterfaces({
    contract: () =>
      network.networkHelpers.loadFixture(fixture).then((F) => F.dnsTLDResolver),
    interfaces: [
      "IERC165",
      "IERC7996",
      "IExtendedResolver",
      "ICompositeResolver",
      "IVerifiableResolver",
    ],
  });

  shouldSupportFeatures({
    contract: () =>
      network.networkHelpers.loadFixture(fixture).then((F) => F.dnsTLDResolver),
    features: {
      RESOLVER: ["RESOLVE_MULTICALL"],
    },
  });

  describe("parseDNSSECRecord()", () => {
    const CONTEXT = "i am context";
    it("invalid", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      const [resolver, context] = await F.dnsTLDResolver.read.parseDNSSECRecord(
        [stringToHex("i am invalid")],
      );
      expectVar({ resolver }).toEqualAddress(zeroAddress);
      expectVar({ context }).toStrictEqual("0x");
    });
    it("via address", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      const [resolver, context] = await F.dnsTLDResolver.read.parseDNSSECRecord(
        [stringToHex(`ENS1 ${F.dnsTXTResolver.address} ${CONTEXT}`)],
      );
      expectVar({ resolver }).toEqualAddress(F.dnsTXTResolver.address);
      expectVar({ context }).toStrictEqual(stringToHex(CONTEXT));
    });
    it("via name", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      const [resolver, context] = await F.dnsTLDResolver.read.parseDNSSECRecord(
        [stringToHex(`ENS1 ${dnsTXTResolverName} ${CONTEXT}`)],
      );
      expectVar({ resolver }).toEqualAddress(F.dnsTXTResolver.address);
      expectVar({ context }).toStrictEqual(stringToHex(CONTEXT));
    });
  });

  it(`getDNSSECRecords()`, async () => {
    const F = await network.networkHelpers.loadFixture(fixture);
    const contextByName = `ENS1 ${dnsTXTResolverName} 123`;
    const contextByAddr = `ENS1 ${F.dnsAliasResolver.address} abc`;
    const contextJunk = "abc";
    const encodedRRs = encodeRRs([
      makeTXT(basicProfile.name, contextByName),
      makeTXT(basicProfile.name, contextByAddr),
      makeTXT(basicProfile.name, contextJunk),
      makeTXT("different.com", contextByName),
    ]);
    await F.mockDNSSEC.write.setResponse([encodedRRs]);
    await expect(
      F.dnsTLDResolver.read.getDNSSECRecords([
        dnsEncodeName(basicProfile.name),
      ]),
    ).resolves.toStrictEqual(
      [contextByName, contextByAddr, contextJunk].map((x) => stringToHex(x)),
    );
  });

  it("verifierMetadata()", async () => {
    const F = await network.networkHelpers.loadFixture(fixture);
    const [verifier, gateways] = await F.dnsTLDResolver.read.verifierMetadata([
      dnsEncodeName(basicProfile.name),
    ]);
    expectVar({ verifier }).toEqualAddress(F.mockDNSSEC.address);
    expectVar({ gateways }).toStrictEqual([dnsOracleGateway]);
  });

  function testProfiles(
    name: string,
    factory: (kp: KnownProfile) => () => Promise<void>,
    testFn: typeof it.only = it,
  ) {
    testFn(name, factory(basicProfile));
    testFn(
      `${name} multicall`,
      factory({
        ...basicProfile,
        texts: [{ key: "url", value: testURL }],
        contenthash: { value: "0xabcd" },
      }),
    );
  }

  describe("still registered on V1", () => {
    testProfiles("immediate", (kp) => async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mainnetV1.setupName(kp);
      for (const res of makeResolutions(kp)) {
        await F.mainnetV1.publicResolver.write.multicall([[res.write]]);
      }
      await F.expectResolution(kp, F.mainnetV1.publicResolver.address);
    });

    testProfiles("onchain extended", (kp) => async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mainnetV1.setupName({
        name: kp.name,
        resolverAddress: F.ssResolver.address,
      });
      await F.ssResolver.write.setExtended([true]);
      for (const res of makeResolutions(kp)) {
        await F.ssResolver.write.setResponse([res.call, res.answer]);
      }
      await F.expectResolution(kp, F.ssResolver.address);
    });

    testProfiles("offchain extended", (kp) => async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mainnetV1.setupName({
        name: kp.name,
        resolverAddress: F.ssResolver.address,
      });
      await F.ssResolver.write.setExtended([true]);
      await F.ssResolver.write.setOffchain([true]);
      for (const res of makeResolutions(kp)) {
        await F.ssResolver.write.setResponse([res.call, res.answer]);
      }
      await F.expectResolution(kp, F.ssResolver.address);
    });
  });

  it("imported on V2", async () => {
    const F = await network.networkHelpers.loadFixture(fixture);
    const bundle = bundleCalls(makeResolutions(basicProfile));
    await F.mainnetV2.setupName({
      name: basicProfile.name,
      resolverAddress: F.ownedResolver.address,
    });
    await F.ownedResolver.write.multicall([
      bundle.resolutions.map((x) => x.write),
    ]);
    const [answer, resolver] = await F.mainnetV2.universalResolver.read.resolve(
      [dnsEncodeName(basicProfile.name), bundle.call],
    );
    expectVar({ resolver }).toEqualAddress(F.ownedResolver.address);
    bundle.expect(answer);
  });

  describe("ExtendedDNSResolver (original deployment)", () => {
    // this ensures MockDNSSEC is working as expected
    it("addr(60)", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mockDNSSEC.write.setResponse([
        encodeRRs([
          makeTXT(
            basicProfile.name,
            `ENS1 ${extendedDNSResolverName} ${testAddress}`,
          ),
        ]),
      ]);
      await F.expectGasless(
        {
          name: basicProfile.name,
          addresses: [
            {
              coinType: COIN_TYPE_ETH,
              value: testAddress,
            },
          ],
        },
        F.extendedDNSResolverAddress,
      );
    });
  });

  describe("DNSSEC", () => {
    it("no ENS1", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await expect(
        F.mainnetV2.universalResolver.read.resolve([
          dnsEncodeName(basicProfile.name),
          dummyBytes4,
        ]),
      )
        .toBeRevertedWithCustomError("ResolverError")
        .withArgs([
          encodeErrorResult({
            abi: F.dnsTLDResolver.abi,
            errorName: "UnreachableName",
            args: [dnsEncodeName(basicProfile.name)],
          }),
        ]);
    });

    describe("via address", () => {
      testProfiles("onchain immediate", (kp) => async () => {
        const F = await network.networkHelpers.loadFixture(fixture);
        await F.mockDNSSEC.write.setResponse([
          encodeRRs([makeTXT(kp.name, `ENS1 ${F.ownedResolver.address}`)]),
        ]);
        await F.ownedResolver.write.multicall([
          makeResolutions(kp).map((x) => x.write),
        ]);
        await F.expectGasless(kp, F.ownedResolver.address);
      });
    });

    describe("via name", () => {
      testProfiles("onchain immediate", (kp) => async () => {
        const F = await network.networkHelpers.loadFixture(fixture);
        const name = "myresolver.eth";
        await F.setupNamedResolver(name, F.ssResolver.address);
        for (const res of makeResolutions(kp)) {
          await F.ssResolver.write.setResponse([res.call, res.answer]);
        }
        await F.mockDNSSEC.write.setResponse([
          encodeRRs([makeTXT(kp.name, `ENS1 ${name}`)]),
        ]);
        await F.expectGasless(kp, F.ssResolver.address);
      });

      testProfiles("offchain extended", (kp) => async () => {
        const F = await network.networkHelpers.loadFixture(fixture);
        const name = "myresolver.eth";
        await F.setupNamedResolver(name, F.ssResolver.address);
        await F.ssResolver.write.setExtended([true]);
        await F.ssResolver.write.setOffchain([true]);
        for (const res of makeResolutions(kp)) {
          await F.ssResolver.write.setResponse([res.call, res.answer]);
        }
        await F.mockDNSSEC.write.setResponse([
          encodeRRs([makeTXT(kp.name, `ENS1 ${name}`)]),
        ]);
        await F.expectGasless(kp, F.ssResolver.address);
      });
    });
  });

  describe("DNSTXTResolver", () => {
    const contenthash = "0xabcdef";
    const anotherAddress = "0x1234567812345678123456781234567812345678";
    const x = `0x${"a".repeat(64)}` as const;
    const y = `0x${"b".repeat(64)}` as const;
    const context = `a[60]=${testAddress} a[e0]=${anotherAddress} t[url]='${testURL}' c=${contenthash} xy=${concat([x, y])}`;
    const encodedRRs = encodeRRs([
      makeTXT(basicProfile.name, `ENS1 ${dnsTXTResolverName} ${context}`),
    ]);

    it("unsupported", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mockDNSSEC.write.setResponse([encodedRRs]);
      await expect(
        F.mainnetV2.universalResolver.read.resolve([
          dnsEncodeName(basicProfile.name),
          dummyBytes4,
        ]),
      )
        .toBeRevertedWithCustomError("UnsupportedResolverProfile")
        .withArgs([dummyBytes4]);
    });

    it("invalid hex", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      const invalidHex = "!@#$";
      await F.mockDNSSEC.write.setResponse([
        encodeRRs([
          makeTXT(
            basicProfile.name,
            `ENS1 ${dnsTXTResolverName} a[60]=${invalidHex}`,
          ),
        ]),
      ]);
      const [res] = makeResolutions({
        name: basicProfile.name,
        addresses: [{ coinType: COIN_TYPE_ETH, value: testAddress }],
      });
      await expect(
        F.mainnetV2.universalResolver.read.resolve([
          dnsEncodeName(basicProfile.name),
          res.call,
        ]),
      )
        .toBeRevertedWithCustomError("ResolverError")
        .withArgs([
          encodeErrorResult({
            abi: F.dnsTXTResolver.abi,
            errorName: "InvalidHexData",
            args: [stringToHex(invalidHex)],
          }),
        ]);
    });

    it("invalid length: address", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mockDNSSEC.write.setResponse([
        encodeRRs([
          makeTXT(
            basicProfile.name,
            `ENS1 ${dnsTXTResolverName} a[60]=${dummyBytes4}`,
          ),
        ]),
      ]);
      const [res] = makeResolutions({
        name: basicProfile.name,
        addresses: [{ coinType: COIN_TYPE_ETH, value: testAddress }],
      });
      await expect(
        F.mainnetV2.universalResolver.read.resolve([
          dnsEncodeName(basicProfile.name),
          res.call,
        ]),
      )
        .toBeRevertedWithCustomError("ResolverError")
        .withArgs([
          encodeErrorResult({
            abi: F.dnsTXTResolver.abi,
            errorName: "InvalidDataLength",
            args: [dummyBytes4, 20n],
          }),
        ]);
    });

    it("invalid length: pubkey", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mockDNSSEC.write.setResponse([
        encodeRRs([
          makeTXT(
            basicProfile.name,
            `ENS1 ${dnsTXTResolverName} xy=${dummyBytes4}`,
          ),
        ]),
      ]);
      const [res] = makeResolutions({
        name: basicProfile.name,
        pubkey: { x, y },
      });
      await expect(
        F.mainnetV2.universalResolver.read.resolve([
          dnsEncodeName(basicProfile.name),
          res.call,
        ]),
      )
        .toBeRevertedWithCustomError("ResolverError")
        .withArgs([
          encodeErrorResult({
            abi: F.dnsTXTResolver.abi,
            errorName: "InvalidDataLength",
            args: [dummyBytes4, 64n],
          }),
        ]);
    });

    it("addr()", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mockDNSSEC.write.setResponse([encodedRRs]);
      await F.expectTXT(basicProfile);
    });

    it("addr() w/fallback", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mockDNSSEC.write.setResponse([encodedRRs]);
      await F.expectTXT({
        name: basicProfile.name,
        addresses: [
          { coinType: COIN_TYPE_DEFAULT | 1n, value: anotherAddress },
        ],
      });
    });

    it("hasAddr()", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mockDNSSEC.write.setResponse([encodedRRs]);
      await F.expectTXT({
        name: basicProfile.name,
        hasAddresses: [
          { coinType: COIN_TYPE_ETH, exists: true },
          { coinType: COIN_TYPE_DEFAULT, exists: true },
          { coinType: COIN_TYPE_DEFAULT | 1n, exists: false },
        ],
      });
    });

    it("text(url)", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mockDNSSEC.write.setResponse([encodedRRs]);
      await F.expectTXT({
        name: basicProfile.name,
        texts: [{ key: "url", value: testURL }],
      });
    });

    it("contenthash()", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mockDNSSEC.write.setResponse([encodedRRs]);
      await F.expectTXT({
        name: basicProfile.name,
        contenthash: { value: contenthash },
      });
    });

    it("pubkey()", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mockDNSSEC.write.setResponse([encodedRRs]);
      await F.expectTXT({
        name: basicProfile.name,
        pubkey: { x, y },
      });
    });

    it("multicall", async () => {
      const F = await network.networkHelpers.loadFixture(fixture);
      await F.mockDNSSEC.write.setResponse([encodedRRs]);
      await F.expectTXT({
        name: basicProfile.name,
        addresses: [
          { coinType: COIN_TYPE_ETH, value: testAddress },
          { coinType: COIN_TYPE_DEFAULT | 1n, value: anotherAddress },
          { coinType: COIN_TYPE_DEFAULT | 2n, value: anotherAddress },
        ],
        texts: [{ key: "url", value: testURL }],
        contenthash: { value: contenthash },
        pubkey: { x, y },
      });
    });
  });

  describe("DNSAliasResolver", () => {
    shouldSupportInterfaces({
      contract: () =>
        network.networkHelpers
          .loadFixture(fixture)
          .then((F) => F.dnsAliasResolver),
      interfaces: ["IERC165", "IERC7996", "IExtendedDNSResolver"],
    });

    shouldSupportFeatures({
      contract: () =>
        network.networkHelpers
          .loadFixture(fixture)
          .then((F) => F.dnsAliasResolver),
      features: {
        RESOLVER: ["RESOLVE_MULTICALL"],
      },
    });

    function parseContext(name: string, context: string) {
      const pos = context.indexOf(" ");
      if (pos == -1) return context;
      return name.replace(
        new RegExp(`(^|\.)${context.slice(0, pos)}$`),
        (_, x) => x + context.slice(pos + 1),
      );
    }

    for (const context of ["com eth", "test.com test.eth", "test.eth"]) {
      function create(
        configure: (F: Awaited<ReturnType<typeof fixture>>) => Promise<void>,
      ) {
        return async () => {
          const F = await network.networkHelpers.loadFixture(fixture);
          const oldName = "test.com";
          const newName = parseContext(oldName, context);
          expectVar({ newName }).toStrictEqual("test.eth");
          const kp = {
            name: newName,
            addresses: [{ coinType: COIN_TYPE_ETH, value: testAddress }],
            texts: [{ key: "url", value: testURL }],
          } as const satisfies KnownProfile;
          await F.mainnetV2.setupName({
            name: newName,
            resolverAddress: F.ssResolver.address,
          });
          for (const res of makeResolutions(kp)) {
            await F.ssResolver.write.setResponse([res.call, res.answer]);
          }
          await configure(F);
          await F.mockDNSSEC.write.setResponse([
            encodeRRs([
              makeTXT(oldName, `ENS1 ${F.dnsAliasResolver.address} ${context}`),
            ]),
          ]);
          await F.expectResolution(
            { ...kp, name: oldName },
            F.dnsAliasResolver.address,
            true,
          );
          await expect(
            F.dnsAliasResolver.read.rewriteNameWithContext([
              dnsEncodeName(oldName),
              stringToHex(context),
            ]),
          ).resolves.toStrictEqual(dnsEncodeName(newName));
        };
      }

      describe(context.replace(" ", " => "), () => {
        for (const multi of [false, true]) {
          for (const offchain of [false, true]) {
            for (const type of ["extended", "immediate", "old"]) {
              if (type === "old" && offchain) continue;
              it(
                `${offchain ? "offchain" : "onchain"} ${type}${multi ? " w/multicall" : ""}`,
                create(async (F) => {
                  await F.ssResolver.write.setOld([type === "old"]);
                  await F.ssResolver.write.setExtended([type === "extended"]);
                  await F.ssResolver.write.setOffchain([offchain]);
                  await F.ssResolver.write.setDeriveMulticall([multi]);
                  await F.ssResolver.write.setFeature([
                    FEATURES.RESOLVER.RESOLVE_MULTICALL,
                    multi,
                  ]);
                }),
              );
            }
          }
        }
      });
    }
  });
});
