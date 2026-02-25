import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const registryMetadata = get<
      (typeof artifacts.SimpleRegistryMetadata)["abi"]
    >("SimpleRegistryMetadata");

    await deploy("UserRegistry", {
      account: deployer,
      artifact: artifacts.UserRegistry,
      args: [hcaFactory.address, registryMetadata.address],
    });
  },
  {
    tags: ["UserRegistry", "l1"],
    dependencies: ["HCAFactory", "RegistryMetadata"],
  },
);
