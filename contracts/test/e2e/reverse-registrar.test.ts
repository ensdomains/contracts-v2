import { artifacts } from "@rocketh";
import { describe, it } from "bun:test";
import {
  encodeAbiParameters,
  encodeFunctionData,
  getContract,
  namehash,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";

import { MAX_EXPIRY } from "../../script/deploy-constants.js";
import { deployArtifact } from "../integration/fixtures/deployArtifact.js";
import { expectVar } from "../utils/expectVar.js";
import {
  COIN_TYPE_DEFAULT,
  COIN_TYPE_ETH,
  coinTypeFromChain,
  getReverseName,
} from "../utils/utils.js";

const COIN_TYPE_OPTIMISM = coinTypeFromChain(10);
const executorAbi = [
  {
    type: "function",
    name: "initialize",
    inputs: [{ name: "owner_", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "execute",
    inputs: [
      { name: "target", type: "address" },
      { name: "data", type: "bytes" },
    ],
    outputs: [{ name: "result", type: "bytes" }],
    stateMutability: "nonpayable",
  },
] as const;

describe("Reverse registrars", () => {
  const { env, setupEnv } = process.env.TEST_GLOBALS!;
  let hcaFixture: {
    deferredImplementation: Address;
    executorImplementation: Address;
  };

  setupEnv({
    resetOnEach: true,
    initialize: async () => {
      const parser = await deployArtifact(env.client, {
        file: new URL(
          "../../artifacts/test/mocks/MockHCAFixture.sol/MockHCAInitDataParser.json",
          import.meta.url,
        ),
      });
      const executorImplementation = await deployArtifact(env.client, {
        file: new URL(
          "../../artifacts/test/mocks/MockHCAFixture.sol/MockHCAExecutorImplementation.json",
          import.meta.url,
        ),
      });
      const deferredImplementation =
        await env.v2.HCAFactory.read.DEFERRED_IMPLEMENTATION();

      await env.v2.HCAFactory.write.setImplementation(
        [deferredImplementation, parser],
        { account: env.namedAccounts.owner },
      );

      hcaFixture = { deferredImplementation, executorImplementation };
    },
  });

  async function createExecutableHCA(account: typeof env.namedAccounts.owner) {
    const initData = encodeAbiParameters(
      [{ name: "owner", type: "address" }],
      [account.address],
    );
    const hca = await env.v2.HCAFactory.read.computeAccountAddress([
      account.address,
    ]);

    await env.v2.HCAFactory.write.setAccountImplementation(
      [hcaFixture.deferredImplementation],
      { account },
    );

    await env.v2.HCAFactory.write.createAccount([initData], {
      account: env.namedAccounts.user2,
    });

    const initializeData = encodeFunctionData({
      abi: executorAbi,
      functionName: "initialize",
      args: [account.address],
    });

    await env.waitFor(
      env.client.writeContract({
        address: hca,
        abi: artifacts.HCADeferredImplementation.abi,
        functionName: "upgradeToAndCall",
        args: [hcaFixture.executorImplementation, initializeData],
        account,
      }),
    );

    return getContract({
      address: hca,
      abi: executorAbi,
      client: env.client,
    });
  }

  async function executeFromHCA({
    hca,
    account,
    target,
    data,
  }: {
    hca: Awaited<ReturnType<typeof createExecutableHCA>>;
    account: typeof env.namedAccounts.owner;
    target: Address;
    data: Hex;
  }) {
    await env.waitFor(
      hca.write.execute([target, data], {
        account,
      }),
    );
  }

  async function registerForwardName({
    label,
    coinType,
  }: {
    label: string;
    coinType: bigint;
  }) {
    const account = env.namedAccounts.owner;
    const hca = await createExecutableHCA(account);
    const name = `${label}.eth`;
    const resolver = account.resolver;

    await env.v2.ETHRegistry.write.register([
      label,
      account.address,
      zeroAddress,
      resolver.address,
      0n,
      MAX_EXPIRY,
    ]);
    await executeFromHCA({
      hca,
      account,
      target: resolver.address,
      data: encodeFunctionData({
        abi: resolver.abi,
        functionName: "setAddr",
        args: [namehash(name), coinType, account.address],
      }),
    });

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

      await executeFromHCA({
        hca,
        account,
        target: env.shared.ReverseRegistrarHCAAdapter.address,
        data: encodeFunctionData({
          abi: env.shared.ReverseRegistrarHCAAdapter.abi,
          functionName: "claimForAddr",
          args: [resolver.address],
        }),
      });

      const owner = await env.v1.ENSRegistry.read.owner([reverseNode]);
      const reverseResolver = await env.v1.ENSRegistry.read.resolver([
        reverseNode,
      ]);
      expectVar({ owner }).toEqualAddress(account.address);
      expectVar({ reverseResolver }).toEqualAddress(resolver.address);

      await executeFromHCA({
        hca,
        account,
        target: resolver.address,
        data: encodeFunctionData({
          abi: resolver.abi,
          functionName: "setName",
          args: [reverseNode, name],
        }),
      });

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

      await executeFromHCA({
        hca,
        account,
        target: env.shared.DefaultReverseRegistrarHCAAdapter.address,
        data: encodeFunctionData({
          abi: env.shared.DefaultReverseRegistrarHCAAdapter.abi,
          functionName: "setNameForAddr",
          args: [name],
        }),
      });

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
