import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer, owner } }) => {
    await deploy("ContractNamer", {
      account: deployer,
      artifact: artifacts.ContractNamer,
      args: [owner],
    });
  },
  {
    tags: ["ContractNamer", "v2"],
  },
);
