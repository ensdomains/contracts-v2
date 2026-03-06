import { artifacts, execute } from "@rocketh";
import { ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const nameWrapperV1 =
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
        ethRegistry.address,
        nameWrapperV1.address,
        verifiableFactory.address,
        wrapperRegistryImpl.address,
      ],
    });

    // see: LockedMigrationController.t.sol
    await write(ethRegistry, {
      account: deployer,
      functionName: "grantRootRoles",
      args: [ROLES.REGISTRY.REGISTER_RESERVED, migrationController.address],
    });
  },
  {
    tags: ["LockedMigrationController", "l1"],
    dependencies: [
      "NameWrapper",
      "ETHRegistry",
      "VerifiableFactory",
      "WrapperRegistryImpl",
    ],
  },
);
