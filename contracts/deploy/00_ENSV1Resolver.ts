import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ get, deploy, namedAccounts: { deployer } }) => {
    const batchGatewayProvider = get<(typeof artifacts.GatewayProvider)["abi"]>(
      "BatchGatewayProvider",
    );

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const ensRegistry =
      get<(typeof artifacts.ENSRegistry)["abi"]>("ENSRegistry");

    await deploy("ENSV1Resolver", {
      account: deployer,
      artifact: artifacts.ENSV1Resolver,
      args: [
        batchGatewayProvider.address,
        contractNamer.address,
        ensRegistry.address,
      ],
    });
  },
  {
    tags: ["ENSV1Resolver", "v2"],
    dependencies: ["BatchGatewayProvider", "ContractNamer", "ENSRegistry"],
  },
);
