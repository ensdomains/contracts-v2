import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const unlockedMigrationController = get<
      (typeof artifacts.UnlockedMigrationController)["abi"]
    >("UnlockedMigrationController");

    const lockedMigrationController = get<
      (typeof artifacts.LockedMigrationController)["abi"]
    >("LockedMigrationController");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    await deploy("MigrationHelper", {
      account: deployer,
      artifact: artifacts.MigrationHelper,
      args: [
        rootRegistry.address,
        unlockedMigrationController.address,
        lockedMigrationController.address,
        contractNamer.address,
      ],
    });
  },
  {
    tags: ["MigrationHelper", "migration:phase1:deploy-v2", "v2"],
    dependencies: [
      "RootRegistry",
      "UnlockedMigrationController",
      "LockedMigrationController",
      "ContractNamer",
    ],
  },
);
