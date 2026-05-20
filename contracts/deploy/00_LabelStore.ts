import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer } }) => {
    await deploy("LabelStore", {
      account: deployer,
      artifact: artifacts.LabelStore,
    });
  },
  {
    tags: ["LabelStore", "v2"],
  },
);
