import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer } }) => {
    // create a new registrar for "addr.reverse"
    await deploy("ETHReverseRegistrar", {
      account: deployer,
      artifact: artifacts.L2ReverseRegistrar,
      args: [60n],
    });
  },
  {
    tags: ["ETHReverseRegistrar", "l1"],
  },
);
