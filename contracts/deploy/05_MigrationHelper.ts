import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory = get<(typeof artifacts.HCAFactory)["abi"]>("HCAFactory");

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
      artifact: artifacts["src/migration/MigrationHelper.sol/MigrationHelper"],
      args: [
        hcaFactory.address,
        rootRegistry.address,
        unlockedMigrationController.address,
        lockedMigrationController.address,
        contractNamer.address,
      ],
    });
  },
  {
    tags: ["MigrationHelper", "v2"],
    dependencies: [
      "HCAFactory",
      "RootRegistry",
      "UnlockedMigrationController",
      "LockedMigrationController",
      "ContractNamer",
    ],
  },
);
