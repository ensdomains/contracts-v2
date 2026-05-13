import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ get, deploy, namedAccounts: { deployer } }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const batchGatewayProvider = get<(typeof artifacts.GatewayProvider)["abi"]>(
      "BatchGatewayProvider",
    );

    const ensRegistry =
      get<(typeof artifacts.ENSRegistry)["abi"]>("ENSRegistry");

    await deploy("ENSV1Resolver", {
      account: deployer,
      artifact: artifacts.ENSV1Resolver,
      args: [
        rootRegistry.address,
        batchGatewayProvider.address,
        ensRegistry.address,
      ],
    });
  },
  {
    tags: ["ENSV1Resolver", "v2"],
    dependencies: ["RootRegistry", "BatchGatewayProvider", "ENSRegistry"],
  },
);
