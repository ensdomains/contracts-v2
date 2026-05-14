import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer, owner } }) => {
    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const labelStore = get<(typeof artifacts.ILabelStore)["abi"]>("LabelStore");

    await deploy("UserRegistryImpl", {
      account: deployer,
      artifact: artifacts.UserRegistry,
      args: [hcaFactory.address, labelStore.address, owner],
    });
  },
  {
    tags: ["UserRegistryImpl", "v2"],
    dependencies: ["HCAFactory", "LabelStore"],
  },
);
