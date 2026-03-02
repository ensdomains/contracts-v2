import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ get, deploy, namedAccounts: { deployer } }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const batchGatewayProvider = get<(typeof artifacts.GatewayProvider)["abi"]>(
      "BatchGatewayProvider",
    );

    await deploy("ENSV2Resolver", {
      account: deployer,
      artifact: artifacts.ENSV2Resolver,
      args: [rootRegistry.address, batchGatewayProvider.address],
    });
  },
  {
    tags: ["ENSV2Resolver", "l1"],
    dependencies: ["RootRegistry", "BatchGatewayProvider"],
  },
);
