import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, getV1, namedAccounts: { deployer } }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const batchGatewayProvider = getV1<
      (typeof artifacts.GatewayProvider)["abi"]
    >("BatchGatewayProvider");

    await deploy("UniversalResolverV2", {
      account: deployer,
      artifact: artifacts.UniversalResolverV2,
      args: [rootRegistry.address, batchGatewayProvider.address],
    });
  },
  {
    tags: ["UniversalResolverV2", "l1"],
    dependencies: ["RootRegistry", "BatchGatewayProvider"],
  },
);
