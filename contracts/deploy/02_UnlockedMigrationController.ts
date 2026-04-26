import { artifacts, execute } from "@rocketh";
import { DEPLOYMENT_ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const nameWrapper =
      get<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    const graveyard = get<(typeof artifacts.Graveyard)["abi"]>("Graveyard");

    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");

    const migrationController = await deploy("UnlockedMigrationController", {
      account: deployer,
      artifact: artifacts.UnlockedMigrationController,
      args: [nameWrapper.address, graveyard.address, ethRegistry.address],
    });

    // see: UnlockedMigrationController.t.sol
    await write(ethRegistry, {
      account: deployer,
      functionName: "grantRootRoles",
      args: [
        DEPLOYMENT_ROLES.MIGRATION_CONTROLLER_ROOT,
        migrationController.address,
      ],
    });
  },
  {
    tags: ["UnlockedMigrationController", "v2"],
    dependencies: ["NameWrapper", "Graveyard", "ETHRegistry"],
  },
);
