import type { NetworkConnection } from "hardhat/types/network";
import { type Address, zeroAddress } from "viem";
import {
  LOCAL_BATCH_GATEWAY_URL,
  ROLES,
} from "../../../script/deploy-constants.js";
import { splitName, idFromLabel } from "../../utils/utils.js";
import { deployVerifiableProxy } from "./deployVerifiableProxy.js";

export const MAX_EXPIRY = (1n << 64n) - 1n;

export async function deployV2Fixture(
  network: NetworkConnection,
  enableCcipRead = false,
) {
  const publicClient = await network.viem.getPublicClient({
    ccipRead: enableCcipRead ? undefined : false,
  });
  const [walletClient] = await network.viem.getWalletClients();
  const hcaFactory = await network.viem.deployContract("MockHCAFactoryBasic");
  const rootRegistry = await network.viem.deployContract(
    "PermissionedRegistry",
    [hcaFactory.address, zeroAddress, walletClient.account.address, ROLES.ALL],
  );
  const ethRegistry = await network.viem.deployContract(
    "PermissionedRegistry",
    [hcaFactory.address, zeroAddress, walletClient.account.address, ROLES.ALL],
  );
  const batchGatewayProvider = await network.viem.deployContract(
    "GatewayProvider",
    [walletClient.account.address, [LOCAL_BATCH_GATEWAY_URL]],
  );
  const universalResolver = await network.viem.deployContract(
    "UniversalResolverV2",
    [rootRegistry.address, batchGatewayProvider.address],
    { client: { public: publicClient } },
  );
  await rootRegistry.write.register([
    "eth",
    walletClient.account.address,
    ethRegistry.address,
    zeroAddress,
    ROLES.ALL,
    MAX_EXPIRY,
  ]);
  const verifiableFactory =
    await network.viem.deployContract("VerifiableFactory");
  const ownedResolver = await network.viem.deployContract(
    "src/resolver/OwnedResolver.sol:OwnedResolver",
    [hcaFactory.address],
  );
  return {
    network,
    publicClient,
    walletClient,
    hcaFactory,
    rootRegistry,
    ethRegistry,
    batchGatewayProvider,
    universalResolver,
    deployOwnedResolver,
    setupName,
  };
  async function deployOwnedResolver({
    owner = walletClient.account.address,
    roles = ROLES.ALL,
    salt = idFromLabel(new Date().toISOString()),
  }: {
    owner?: Address;
    roles?: bigint;
    salt?: bigint;
  } = {}) {
    return deployVerifiableProxy({
      walletClient: await network.viem.getWalletClient(owner),
      factoryAddress: verifiableFactory.address,
      implAddress: ownedResolver.address,
      abi: ownedResolver.abi,
      functionName: "initialize",
      args: [walletClient.account.address, roles],
      salt,
    });
  }
  // creates registries up to the parent name
  // if exact, exactRegistry is setup
  // if no resolverAddress, dedicatedResolver is deployed
  async function setupName<exact_ extends boolean = false>({
    name,
    owner = walletClient.account.address,
    expiry = MAX_EXPIRY,
    roles = ROLES.ALL,
    resolverAddress,
    metadataAddress = zeroAddress,
    exact,
  }: {
    name: string;
    owner?: Address;
    expiry?: bigint;
    roles?: bigint;
    resolverAddress?: Address;
    metadataAddress?: Address;
    exact?: exact_;
  }) {
    const labels = splitName(name);
    if (!labels.length) throw new Error("expected name");
    const registries = [rootRegistry];
    while (true) {
      const parentRegistry = registries[0];
      const label = labels[labels.length - registries.length];
      const state = await parentRegistry.read.getState([idFromLabel(label)]);
      const exists = state.latestOwner !== zeroAddress;
      const leaf = registries.length == labels.length;
      let registryAddress = await parentRegistry.read.getSubregistry([label]);
      if (!leaf || exact) {
        if (registryAddress === zeroAddress) {
          // registry does not exist, create it
          const registry = await network.viem.deployContract(
            "PermissionedRegistry",
            [
              hcaFactory.address,
              metadataAddress,
              walletClient.account.address,
              roles,
            ],
          );
          registryAddress = registry.address;
          if (exists) {
            // label exists but registry does not exist, set it
            await parentRegistry.write.setSubregistry([
              state.tokenId,
              registryAddress,
            ]);
          }
          registries.unshift(registry);
        } else {
          registries.unshift(
            await network.viem.getContractAt(
              "PermissionedRegistry",
              registryAddress,
            ),
          );
        }
      }
      if (!exists) {
        // child does not exist, register it
        await parentRegistry.write.register([
          label,
          owner,
          registryAddress,
          (leaf && resolverAddress) || zeroAddress,
          roles,
          expiry,
        ]);
      } else if (leaf) {
        const currentResolver = await parentRegistry.read.getResolver([label]);
        if (resolverAddress && currentResolver !== resolverAddress) {
          // leaf node exists but resolver is different, set it
          await parentRegistry.write.setResolver([
            state.tokenId,
            resolverAddress,
          ]);
        }
      }
      if (leaf) {
        // invariants:
        //            tokenId == labelToCanonicalId(labels[0])
        //  registries.length == labels.length
        //     exactRegistry? == registries[0]
        //     parentRegistry == registries[1]
        return {
          name,
          labels,
          tokenId: state.tokenId,
          parentRegistry,
          exactRegistry: (exact
            ? registries[0]
            : undefined) as exact_ extends true
            ? (typeof registries)[number]
            : undefined,
          registries: (exact
            ? registries
            : [undefined, ...registries]) as exact_ extends true
            ? typeof registries
            : [undefined, ...typeof registries],
        };
      }
    }
  }
}
