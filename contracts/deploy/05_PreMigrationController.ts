import { artifacts, execute } from "@rocketh";
import { ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");

    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const preMigrationController = await deploy("PreMigrationController", {
      account: deployer,
      artifact: artifacts.PreMigrationController,
      args: [ethRegistry.address, hcaFactory.address, deployer, ROLES.ALL],
    });

    await write(ethRegistry, {
      account: deployer,
      functionName: "grantRootRoles",
      args: [
        ROLES.REGISTRY.SET_SUBREGISTRY | ROLES.REGISTRY.SET_RESOLVER,
        preMigrationController.address,
      ],
    });
  },
  {
    tags: ["PreMigrationController", "l1"],
    dependencies: ["ETHRegistry", "HCAFactory"],
  },
);
