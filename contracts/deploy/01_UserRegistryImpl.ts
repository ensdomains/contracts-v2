import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const registryMetadata = get<
      (typeof artifacts.SimpleRegistryMetadata)["abi"]
    >("SimpleRegistryMetadata");

    const labelStore = get<(typeof artifacts.ILabelStore)["abi"]>("LabelStore");

    await deploy("UserRegistryImpl", {
      account: deployer,
      artifact: artifacts.UserRegistry,
      args: [hcaFactory.address, registryMetadata.address, labelStore.address],
    });
  },
  {
    tags: ["UserRegistryImpl", "v2"],
    dependencies: ["HCAFactory", "RegistryMetadata", "LabelStore"],
  },
);
