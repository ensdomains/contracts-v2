import { artifacts, execute } from "@rocketh";
import { ROLES } from "../../script/deploy-constants.js";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const registryMetadata = get<
      (typeof artifacts.SimpleRegistryMetadata)["abi"]
    >("SimpleRegistryMetadata");

    await deploy("RootRegistry", {
      account: deployer,
      artifact: artifacts.PermissionedRegistry,
      args: [hcaFactory.address, registryMetadata.address, deployer, ROLES.ALL],
    });
  },
  {
    tags: ["RootRegistry", "l1"],
    dependencies: ["HCAFactory", "RegistryMetadata"],
  },
);
