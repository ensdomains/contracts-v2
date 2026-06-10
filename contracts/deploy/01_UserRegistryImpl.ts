import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer, owner } }) => {
    const labelStore = get<(typeof artifacts.ILabelStore)["abi"]>("LabelStore");

    await deploy("UserRegistryImpl", {
      account: deployer,
      artifact: artifacts.UserRegistry,
      args: [labelStore.address, owner],
    });
  },
  {
    tags: ["UserRegistryImpl", "migration:phase1:deploy-v2", "v2"],
    dependencies: ["LabelStore"],
  },
);
