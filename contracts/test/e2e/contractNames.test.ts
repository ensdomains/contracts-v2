import { describe, it } from "bun:test";
import {
  type Address,
  decodeFunctionResult,
  encodeFunctionData,
  parseEventLogs,
  zeroAddress,
} from "viem";
import { Abi_IAddrResolver } from "generated/abis/IAddrResolver.js";
import { STATUS, MAX_EXPIRY, ROLES } from "../../script/deploy-constants.js";
import { expect } from "../utils/expectVar.js";
import { dnsEncodeName, idFromLabel, namehash } from "../utils/utils.js";
import {
  type NamingInfo,
  createReverseRegistrarTransactions,
  createDeployResolverTransaction,
  createMigrationTransaction,
  createResolverCalls,
  expectedResolverAddress,
  filterContractInfos,
  getContractNames,
} from "../../script/contractNames.js";

describe("Contract Names", () => {
  const { env, setupEnv } = process.TEST_GLOBALS!;

  function toAddresses(
    contracts: Record<string, { address: Address }>,
    missing: string[] = [],
  ) {
    return Object.fromEntries([
      ...Object.entries(contracts).map(([k, v]) => [k, v.address] as const),
      ...missing.map((name) => [name, env.rocketh.get(name).address] as const),
    ]);
  }

  const v1 = toAddresses(env.v1, [
    "ETHRegistrarController",
    "WrappedETHRegistrarController",
    "StandaloneHCAFactory",
    "UniversalResolverV1", // v1.UniversalResolver
  ]);
  const v2 = toAddresses(env.v2, [
    "UniversalResolverV2", // v2.UniversalResolver
    "PublicResolverV2", // v2.PublicResolver
  ]);
  const { owner } = env.namedAccounts;

  const info: NamingInfo = {
    label: "ensv2", // devnet already does setupEnsDotEth()
    v1Owner: owner.address,
    isWrapped: false,
    v2Owner: owner.address,
    resolverSaltVersion: 1n, // devnet already deploys a PermissionedResolver for "owner"
    managers: [env.namedAccounts.user.address],
    wallets: {},
    chain: env.client.chain,
  };

  setupEnv({
    resetOnEach: true,
    async initialize() {
      // register in v1
      await env.v1.RegistrarSecurityController.write.addRegistrarController(
        [env.namedAccounts.deployer.address],
        { account: owner },
      );
      await env.v1.BaseRegistrarImplementation.write.register([
        idFromLabel(info.label),
        info.v1Owner,
        MAX_EXPIRY,
      ]);
      // premigrate
      await env.v2.ETHRegistry.write.register([
        info.label,
        zeroAddress,
        zeroAddress,
        env.v2.ENSV1Resolver.address,
        0n,
        MAX_EXPIRY,
      ]);
    },
  });

  async function getDeployedNames() {
    const names = await getContractNames();
    const { found } = filterContractInfos({ v1, v2, names });
    return found;
  }

  async function deployResolver() {
    const tr = createDeployResolverTransaction({ info, v2 });
    const receipt = await env.waitFor(
      env.createClient(owner).sendTransaction(tr),
    );
    const [log] = parseEventLogs({
      abi: env.v2.VerifiableFactory.abi,
      eventName: "ProxyDeployed",
      logs: receipt.logs,
    });
    return env.castPermissionedResolver(log.args.proxyAddress);
  }

  it("createDeployResolverTransaction()", async () => {
    const resolver = await deployResolver();
    expect(resolver.address).toEqualAddress(
      expectedResolverAddress({ info, v2 }),
    );
    await expect(
      resolver.read.roles([0n, info.v2Owner]),
    ).resolves.toStrictEqual(ROLES.ALL);
  });

  it("createMigrationTransaction()", async () => {
    const tr = createMigrationTransaction({ info, v1, v2 });
    await env.waitFor(env.createClient(owner).sendTransaction(tr));

    await expect(
      env.v2.ETHRegistry.read.getState([idFromLabel(info.label)]),
    ).resolves.toMatchObject({
      status: STATUS.REGISTERED,
      latestOwner: owner.address,
    });
    await expect(
      env.v2.ETHRegistry.read.getResolver([info.label]),
    ).resolves.toEqualAddress(expectedResolverAddress({ info, v2 }));
  });

  it("createClaimTransactions()", async () => {
    const names = await getDeployedNames();
    const trs = createReverseRegistrarTransactions({ info, v1, v2, names });

    const client = env.createClient(owner);
    for (const tr of trs) {
      try {
        await env.waitFor(client.sendTransaction(tr));
      } catch (err) {
        console.log(tr);
      }
    }
  });

  it("createResolverCalls()", async () => {
    const resolver = await deployResolver();
    const names = await getDeployedNames();
    const calls = createResolverCalls(names);
    await resolver.write.multicall([calls], { account: owner });

    await Promise.all(
      names.map(async (x) => {
        const abi = Abi_IAddrResolver;
        const functionName = "addr";
        const address = decodeFunctionResult({
          abi,
          functionName,
          data: await resolver.read.resolve([
            dnsEncodeName(x.name),
            encodeFunctionData({
              abi,
              functionName,
              args: [namehash(x.name)],
            }),
          ]),
        });
        expect(address, x.name).toEqualAddress(x.address);
      }),
    );
  });
});
