import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer, owner } }) => {
    await deploy("ApprovedUpgradeGate", {
      account: deployer,
      artifact: artifacts.ApprovedUpgradeGate,
      args: [owner],
    });
  },
  {
    tags: ["ApprovedUpgradeGate", "v2"],
  },
);
