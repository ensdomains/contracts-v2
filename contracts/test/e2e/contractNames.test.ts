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
import {
  dnsEncodeName,
  getReverseName,
  idFromLabel,
  namehash,
} from "../utils/utils.js";
import {
  type NamingInfo,
  createClaimTransactions,
  createDeployResolverTransaction,
  createMigrationTransaction,
  createResolverCalls,
  expectedResolverAddress,
  filterContractInfos,
  getContractNames,
} from "../../script/contractNames.js";

describe("Contract Names", () => {
  const { env, setupEnv } = process.TEST_GLOBALS!;

  const v1 = toAddresses(env.v1);
  const v2 = toAddresses(env.v2);
  const { owner } = env.namedAccounts;

  const info: NamingInfo = {
    label: "ensv2", // devnet already does setupEnsDotEth()
    v1Owner: owner.address,
    isWrapped: false,
    v2Owner: owner.address,
    resolverSaltVersion: 1n, // devnet already deploys a PermissionedResolver for "owner"
    managers: [env.namedAccounts.user.address],
  };

  setupEnv({
    resetOnEach: true,
    async initialize() {
      // register "ens.eth" in v1
      await env.v1.RegistrarSecurityController.write.addRegistrarController(
        [env.namedAccounts.deployer.address],
        { account: owner },
      );
      await env.v1.BaseRegistrarImplementation.write.register([
        idFromLabel(info.label),
        info.v1Owner,
        MAX_EXPIRY,
      ]);
      await env.v2.ETHRegistry.write.register([
        info.label,
        zeroAddress,
        zeroAddress,
        env.v2.ENSV1Resolver.address,
        0n,
        MAX_EXPIRY,
      ]);

      // fix some issues:
      // 1. NameWrapper reverse is owned by deployer
      await env.v1.ENSRegistry.write.setOwner([
        namehash(getReverseName(env.v1.NameWrapper.address)),
        owner.address,
      ]);
      // 2. BaseRegistrarImplementation is Ownable but not claimed
      await env.v1.RegistrarSecurityController.write.transferRegistrarOwnership(
        [owner.address],
        { account: owner },
      );
      await env.v1.ReverseRegistrar.write.claimForAddr(
        [
          env.v1.BaseRegistrarImplementation.address,
          owner.address,
          zeroAddress,
        ],
        { account: owner },
      );
      await env.v1.BaseRegistrarImplementation.write.transferOwnership(
        [env.v1.RegistrarSecurityController.address],
        { account: owner },
      );
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
    const trs = createClaimTransactions({ info, v1, v2, names });

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

function toAddresses(contracts: Record<string, { address: Address }>) {
  return Object.fromEntries(
    Object.entries(contracts).map(([k, v]) => [k, v.address]),
  );
}
