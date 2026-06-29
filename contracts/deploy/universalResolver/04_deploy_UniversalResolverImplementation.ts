import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, getV1, namedAccounts: { deployer } }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");
    const batchGatewayProvider =
      await getV1<(typeof artifacts.GatewayProvider)["abi"]>(
        "BatchGatewayProvider",
      );
    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    await deploy("UniversalResolverV2", {
      account: deployer,
      artifact: artifacts.UniversalResolverV2,
      args: [
        rootRegistry.address,
        batchGatewayProvider.address,
        contractNamer.address,
      ],
    });
    return true;
  },
  {
    id: "universal-resolver:deploy-universal-resolver-implementation:v1",
    tags: [
      "UniversalResolverMigration",
      "migration:phase1:deploy-v2",
      "UniversalResolverImplementation",
      "UniversalResolverV2",
      "v2",
    ],
    dependencies: [
      "RootRegistry",
      "BatchGatewayProvider",
      "ContractNamer",
      "ManagedUniversalResolverProxy",
    ],
  },
);
