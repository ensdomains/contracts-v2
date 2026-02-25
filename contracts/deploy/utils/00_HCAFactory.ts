import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer } }) => {
    // TODO: deploy the actual HCAFactory
    await deploy("HCAFactory", {
      account: deployer,
      artifact: artifacts.MockHCAFactoryBasic,
      args: [],
    });
  },
  {
    tags: ["HCAFactory", "l1"],
  },
);
