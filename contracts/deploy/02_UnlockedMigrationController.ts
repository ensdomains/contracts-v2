import { artifacts, execute } from "@rocketh";
import { ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const nameWrapperV1 =
      get<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");

    const migrationController = await deploy("UnlockedMigrationController", {
      account: deployer,
      artifact: artifacts.UnlockedMigrationController,
      args: [ethRegistry.address, nameWrapperV1.address],
    });

    // see: UnlockedMigrationController.t.sol
    await write(ethRegistry, {
      account: deployer,
      functionName: "grantRootRoles",
      args: [ROLES.REGISTRY.REGISTER_RESERVED, migrationController.address],
    });
  },
  {
    tags: ["UnlockedMigrationController", "l1"],
    dependencies: ["NameWrapper", "ETHRegistry"],
  },
);
