import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ get, deploy, namedAccounts: { deployer } }) => {
    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    await deploy("DNSTXTResolver", {
      account: deployer,
      artifact: artifacts.DNSTXTResolver,
      args: [contractNamer.address],
    });
  },
  {
    tags: ["DNSTXTResolver", "v2"],
    dependencies: ["ContractNamer"],
  },
);
