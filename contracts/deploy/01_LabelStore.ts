import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ get, deploy, namedAccounts: { deployer } }) => {
    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    await deploy("LabelStore", {
      account: deployer,
      artifact: artifacts.LabelStore,
      args: [contractNamer.address],
    });
  },
  {
    tags: ["LabelStore", "v2"],
    dependencies: ["ContractNamer"],
  },
);
