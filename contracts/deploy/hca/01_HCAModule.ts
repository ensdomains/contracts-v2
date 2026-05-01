import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer } }) => {
    await deploy("HCAModule", {
      account: deployer,
      artifact: artifacts.HCAModule,
      args: [],
    });
  },
  {
    tags: ["HCAModule", "v2"],
  },
);
