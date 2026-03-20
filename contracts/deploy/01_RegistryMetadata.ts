import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    await deploy("SimpleRegistryMetadata", {
      account: deployer,
      artifact: artifacts.SimpleRegistryMetadata,
      args: [hcaFactory.address],
    });
  },
  { tags: ["RegistryMetadata", "v2"], dependencies: ["HCAFactory"] },
);
