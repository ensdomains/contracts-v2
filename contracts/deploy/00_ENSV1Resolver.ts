import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ get, getV1, deploy, namedAccounts: { deployer } }) => {
    const batchGatewayProvider = await getV1<
      (typeof artifacts.GatewayProvider)["abi"]
    >("BatchGatewayProvider");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const ensRegistry =
      await getV1<(typeof artifacts.ENSRegistry)["abi"]>("ENSRegistry");

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
    tags: ["ENSV1Resolver", "migration:phase1:deploy-v2", "v2"],
    dependencies: ["BatchGatewayProvider", "ContractNamer", "ENSRegistry"],
  },
);
