import { artifacts, execute } from "@rocketh";
import { DEPLOYMENT_ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const nameWrapper =
      get<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");

    const verifiableFactory =
      get<(typeof artifacts.VerifiableFactory)["abi"]>("VerifiableFactory");

    const wrapperRegistryImpl = get<(typeof artifacts.WrapperRegistry)["abi"]>(
      "WrapperRegistryImpl",
    );

    const migrationController = await deploy("LockedMigrationController", {
      account: deployer,
      artifact: artifacts.LockedMigrationController,
      args: [
        nameWrapper.address,
        ethRegistry.address,
        verifiableFactory.address,
        wrapperRegistryImpl.address,
      ],
    });

    // see: LockedMigrationController.t.sol
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
    tags: ["LockedMigrationController", "v2"],
    dependencies: [
      "NameWrapper",
      "ETHRegistry",
      "VerifiableFactory",
      "WrapperRegistryImpl",
    ],
  },
);
