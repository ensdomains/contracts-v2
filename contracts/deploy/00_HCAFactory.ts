import { artifacts, execute } from "@rocketh";
import { zeroAddress } from "viem";

export default execute(
  async ({ deploy, namedAccounts: { deployer, owner } }) => {
    await deploy("HCAFactory", {
      account: deployer,
      artifact: artifacts.HCAFactory,
      args: [zeroAddress, zeroAddress, owner || deployer],
    });
  },
  {
    tags: ["HCAFactory", "migration:phase1:deploy-v2", "v2"],
  },
);
