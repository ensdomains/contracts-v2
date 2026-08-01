import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer, owner } }) => {
    await deploy("RegistryUpgradeSet", {
      account: deployer,
      artifact: artifacts.PermissionedAddressSet,
      args: [owner],
    });
  },
  {
    tags: ["RegistryUpgradeSet", "v2"],
  },
);
