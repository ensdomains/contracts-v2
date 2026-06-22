import { artifacts, execute } from "@rocketh";
import { getAddress, zeroAddress } from "viem";

export default execute(
  async ({
    deploy,
    get,
    getV1,
    read,
    namedAccounts: { deployer, urManager },
    tags,
  }) => {
    if (tags.local) return true;

    // Seed the managed proxy with whatever the canonical top proxy currently
    // serves so that later switching the top proxy onto the managed proxy is
    // transparent for resolution. Only fall back to the v1 UniversalResolver
    // reference when the top proxy implementation is unset (fresh deployments).
    const topProxy =
      get<typeof artifacts.UpgradableUniversalResolverProxy.abi>(
        "UpgradableUniversalResolverProxy",
      );
    const topImplementation = (await read(topProxy, {
      functionName: "implementation",
    })) as `0x${string}`;
    const seedImplementation =
      getAddress(topImplementation) !== getAddress(zeroAddress)
        ? topImplementation
        : (
            await getV1<(typeof artifacts.UniversalResolver)["abi"]>(
              "UniversalResolver",
            )
          ).address;

    await deploy("ManagedUniversalResolverProxy", {
      account: deployer,
      artifact: artifacts.UpgradableUniversalResolverProxy,
      args: [urManager ?? deployer, seedImplementation],
    });
    return true;
  },
  {
    id: "universal-resolver:deploy-managed-urp:v1",
    tags: [
      "UniversalResolverMigration",
      "migration:phase1:deploy-v2",
      "ManagedUniversalResolverProxy",
      "v2",
    ],
    dependencies: ["UniversalResolverV1"],
  },
);
