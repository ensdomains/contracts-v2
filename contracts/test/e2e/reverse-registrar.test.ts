import { describe, it } from "bun:test";
import { namehash, zeroAddress } from "viem";

import { MAX_EXPIRY } from "../../script/deploy-constants.js";
import { expectVar } from "../utils/expectVar.js";
import {
  COIN_TYPE_DEFAULT,
  COIN_TYPE_ETH,
  coinTypeFromChain,
  getReverseName,
} from "../utils/utils.js";

const COIN_TYPE_OPTIMISM = coinTypeFromChain(10);

describe("Reverse registrars", () => {
  const { env, setupEnv } = process.env.TEST_GLOBALS!;

  setupEnv({ resetOnEach: true });

  async function registerForwardName({
    label,
    coinType,
  }: {
    label: string;
    coinType: bigint;
  }) {
    const account = env.namedAccounts.owner;
    const hca = env.namedAccounts.user2;
    const name = `${label}.eth`;
    const resolver = account.resolver;

    await env.v2.HCAFactory.write.setAccountOwner([
      hca.address,
      account.address,
    ]);
    await resolver.write.setAddr([namehash(name), coinType, account.address], {
      account: hca,
    });
    await env.v2.ETHRegistry.write.register([
      label,
      account.address,
      zeroAddress,
      resolver.address,
      0n,
      MAX_EXPIRY,
    ]);

    return { account, hca, name, resolver };
  }

  describe("HCA adapters", () => {
    it("claims addr.reverse through the ReverseRegistrar adapter", async () => {
      const { account, hca, name, resolver } = await registerForwardName({
        label: "hca-addr",
        coinType: COIN_TYPE_ETH,
      });
      const reverseName = getReverseName(account.address);
      const reverseNode = namehash(reverseName);

      await env.shared.ReverseRegistrarHCAAdapter.write.claimForAddr(
        [resolver.address],
        { account: hca },
      );

      const owner = await env.v1.ENSRegistry.read.owner([reverseNode]);
      const reverseResolver = await env.v1.ENSRegistry.read.resolver([
        reverseNode,
      ]);
      expectVar({ owner }).toEqualAddress(account.address);
      expectVar({ reverseResolver }).toEqualAddress(resolver.address);

      await resolver.write.setName([reverseNode, name], { account: hca });

      const [primary] = await env.v2.UniversalResolver.read.reverse([
        account.address,
        COIN_TYPE_ETH,
      ]);
      expectVar({ primary }).toStrictEqual(name);
    });

    it("sets default.reverse through the DefaultReverseRegistrar adapter", async () => {
      const { account, hca, name } = await registerForwardName({
        label: "hca-default",
        coinType: COIN_TYPE_DEFAULT,
      });

      await env.shared.DefaultReverseRegistrarHCAAdapter.write.setNameForAddr(
        [name],
        { account: hca },
      );

      const registrarName =
        await env.shared.DefaultReverseRegistrar.read.nameForAddr([
          account.address,
        ]);
      expectVar({ registrarName }).toStrictEqual(name);

      const [primary] = await env.v2.UniversalResolver.read.reverse([
        account.address,
        COIN_TYPE_OPTIMISM,
      ]);
      expectVar({ primary }).toStrictEqual(name);
    });
  });
});
