import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ get, deploy, namedAccounts: { deployer } }) => {
    const ensRegistryV1 =
      get<(typeof artifacts.ENSRegistry)["abi"]>("ENSRegistry");

    const batchGatewayProvider = get<(typeof artifacts.GatewayProvider)["abi"]>(
      "BatchGatewayProvider",
    );

    await deploy("ENSV1Resolver", {
      account: deployer,
      artifact: artifacts.ENSV1Resolver,
      args: [ensRegistryV1.address, batchGatewayProvider.address],
    });
  },
  {
    tags: ["ENSV1Resolver", "l1"],
    dependencies: ["ENSRegistry", "BatchGatewayProvider"],
  },
);
