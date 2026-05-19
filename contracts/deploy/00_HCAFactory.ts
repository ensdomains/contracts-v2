import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer, owner } }) => {
    await deploy("HCAFactory", {
      account: deployer,
      artifact: artifacts.HCAFactory,
      args: [owner || deployer],
    });
  },
  {
    tags: ["HCAFactory", "v2"],
  },
);
