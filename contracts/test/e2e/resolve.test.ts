import { describe, it } from "bun:test";
import { type Address, getAddress, namehash, zeroAddress } from "viem";

import { MAX_EXPIRY } from "../../script/deploy-constants.js";
import { expectVar } from "../utils/expectVar.js";
import {
  bundleCalls,
  COIN_TYPE_DEFAULT,
  COIN_TYPE_ETH,
  getReverseName,
  type KnownProfile,
  makeResolutions,
} from "../utils/resolutions.js";
import { dnsEncodeName } from "../utils/utils.js";

describe("Resolve", () => {
  const { env, setupEnv } = process.env.TEST_GLOBALS!;

  setupEnv({ resetOnEach: true });

  async function expectResolve(kp: KnownProfile) {
    const bundle = bundleCalls(makeResolutions(kp));
    const [answer] =
      await env.deployment.contracts.UniversalResolverV2.read.resolve([
        dnsEncodeName(kp.name),
        bundle.call,
      ]);
    bundle.expect(answer);
  }

  describe("Protocol", () => {
    async function named(name: string, fn: () => Address) {
      it(name, async () => {
        const [resolver] =
          await env.deployment.contracts.UniversalResolverV2.read.findResolver([
            dnsEncodeName(name),
          ]);
        expectVar({ resolver }).toStrictEqual(getAddress(fn())); // toEqualAddress
      });
    }

    named(
      "reverse",
      () => env.deployment.contracts.DefaultReverseResolver.address,
    );
    named(
      "addr.reverse",
      () => env.deployment.contracts.ETHReverseResolver.address,
    );
  });

  describe("L1", () => {
    it("dnstxt.ens.eth + addr() => DNSTXTResolver", () =>
      expectResolve({
        name: "dnstxt.ens.eth",
        addresses: [
          {
            coinType: COIN_TYPE_ETH,
            value: env.deployment.contracts.DNSTXTResolver.address,
          },
        ],
      }));

    it("dnsalias.ens.eth + addr() => DNSAliasResolver", () =>
      expectResolve({
        name: "dnsalias.ens.eth",
        addresses: [
          {
            coinType: COIN_TYPE_ETH,
            value: env.deployment.contracts.DNSAliasResolver.address,
          },
        ],
      }));
  });

  describe("Reverse", () => {
    describe("addr.reverse", () => {
      const label = "user";
      const name = `${label}.eth`;

      it("addr.reverse", async () => {
        const { deployer, owner: account } = env.namedAccounts;

        // setup addr(default)
        const resolver = await env.deployment.deployPermissionedResolver({
          account,
        });
        await resolver.write.setAddr([
          namehash(name),
          COIN_TYPE_ETH,
          account.address,
        ]);
        // hack: create name
        await env.deployment.contracts.ETHRegistry.write.register(
          [
            label,
            account.address,
            zeroAddress,
            resolver.address,
            0n,
            MAX_EXPIRY,
          ],
          { account: deployer },
        );
        // setup name()
        await env.deployment.contracts.ETHReverseRegistrar.write.setName(
          [name],
          {
            account,
          },
        );

        await expectResolve({
          name: getReverseName(account.address),
          primary: { value: name },
        });
        await expectResolve({
          name,
          addresses: [{ coinType: COIN_TYPE_ETH, value: account.address }],
        });
        const [primary] =
          await env.deployment.contracts.UniversalResolverV2.read.reverse([
            account.address,
            COIN_TYPE_ETH,
          ]);
        expectVar({ primary }).toStrictEqual(name);
      });

      it("default.reverse", async () => {
        const { deployer, owner: account } = env.namedAccounts;

        // setup addr(default)
        const resolver = await env.deployment.deployPermissionedResolver({
          account,
        });
        await resolver.write.setAddr([
          namehash(name),
          COIN_TYPE_DEFAULT,
          account.address,
        ]);
        // hack: create name
        await env.deployment.contracts.ETHRegistry.write.register(
          [
            label,
            account.address,
            zeroAddress,
            resolver.address,
            0n,
            MAX_EXPIRY,
          ],
          { account: deployer },
        );
        // setup name()
        await env.deployment.contracts.DefaultReverseRegistrar.write.setName(
          [name],
          {
            account,
          },
        );

        await expectResolve({
          name: getReverseName(account.address, COIN_TYPE_DEFAULT),
          primary: { value: name },
        });
        await expectResolve({
          name,
          addresses: [{ coinType: COIN_TYPE_ETH, value: account.address }],
        });
        const [primary] =
          await env.deployment.contracts.UniversalResolverV2.read.reverse([
            account.address,
            COIN_TYPE_ETH,
          ]);
        expectVar({ primary }).toStrictEqual(name);
      });
    });
  });

  describe("DNS", () => {
    it("onchain txt: taytems.xyz", () =>
      // Uses real DNS TXT record for taytems.xyz
      expectResolve({
        name: "taytems.xyz",
        addresses: [
          {
            coinType: COIN_TYPE_ETH,
            value: "0x8e8Db5CcEF88cca9d624701Db544989C996E3216",
          },
        ],
      }));

    it("onchain txt: dnstxt.raffy.xyz", () =>
      // `dnstxt.ens.eth t[avatar]=https://raffy.xyz/ens.jpg a[e0]=0x51050ec063d393217B436747617aD1C2285Aeeee`
      expectResolve({
        name: "dnstxt.raffy.xyz",
        addresses: [
          {
            coinType: COIN_TYPE_ETH,
            value: "0x51050ec063d393217B436747617aD1C2285Aeeee",
          },
        ],
        texts: [{ key: "avatar", value: "https://raffy.xyz/ens.jpg" }],
      }));

    it("alias rewrite: dnsalias[.raffy.xyz] => dnsalias[.ens.eth]", () =>
      // `dnsalias.ens.eth raffy.xyz ens.eth`
      expectResolve({
        name: "dnsalias.raffy.xyz",
        addresses: [
          {
            coinType: COIN_TYPE_ETH,
            value: env.deployment.contracts.DNSAliasResolver.address,
          },
        ],
      }));
  });
});
