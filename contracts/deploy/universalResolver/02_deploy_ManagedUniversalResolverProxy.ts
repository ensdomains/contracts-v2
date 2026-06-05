import { artifacts, execute } from "@rocketh";

export default execute(
  async ({
    deploy,
    getV1,
    namedAccounts: { deployer, urManager },
    tags,
  }) => {
    if (tags.local) return true;

    const v1UniversalResolver =
      await getV1<(typeof artifacts.UniversalResolver)["abi"]>(
        "UniversalResolver",
      );

    await deploy("ManagedUniversalResolverProxy", {
      account: deployer,
      artifact: artifacts.UpgradableUniversalResolverProxy,
      args: [urManager ?? deployer, v1UniversalResolver.address],
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
