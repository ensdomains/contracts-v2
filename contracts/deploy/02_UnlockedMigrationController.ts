import { execute } from "@rocketh";
import type { Abi_NameWrapper } from "generated/abis/NameWrapper.ts";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.ts";
import { Artifact_UnlockedMigrationController } from 'generated/artifacts/UnlockedMigrationController.js';
import { ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, execute: write, get, getV1, namedAccounts: { deployer } }) => {
    const nameWrapper =
      await getV1<Abi_NameWrapper>("NameWrapper");

    const ethRegistry =
      get<Abi_PermissionedRegistry>("ETHRegistry");

    const migrationController = await deploy("UnlockedMigrationController", {
      account: deployer,
      artifact: Artifact_UnlockedMigrationController,
      args: [nameWrapper.address, ethRegistry.address],
    });

    // see: UnlockedMigrationController.t.sol
    await write(ethRegistry, {
      account: deployer,
      functionName: "grantRootRoles",
      args: [ROLES.REGISTRY.REGISTER_RESERVED, migrationController.address],
    });
  },
  {
    tags: ["UnlockedMigrationController", "v2"],
    dependencies: ["NameWrapper", "ETHRegistry"],
  },
);
