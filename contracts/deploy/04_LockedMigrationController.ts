import { execute } from "@rocketh";
import type { Abi_NameWrapper } from "generated/abis/NameWrapper.ts";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.ts";
import type { Abi_VerifiableFactory } from "generated/abis/VerifiableFactory.ts";
import type { Abi_WrapperRegistry } from "generated/abis/WrapperRegistry.ts";
import { Artifact_LockedMigrationController } from 'generated/artifacts/LockedMigrationController.js';
import { ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, execute: write, get, getV1, namedAccounts: { deployer } }) => {
    const nameWrapper =
      await getV1<Abi_NameWrapper>("NameWrapper");

    const ethRegistry =
      get<Abi_PermissionedRegistry>("ETHRegistry");

    const verifiableFactory =
      get<Abi_VerifiableFactory>("VerifiableFactory");

    const wrapperRegistryImpl = get<Abi_WrapperRegistry>(
      "WrapperRegistryImpl",
    );

    const migrationController = await deploy("LockedMigrationController", {
      account: deployer,
      artifact: Artifact_LockedMigrationController,
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
      args: [ROLES.REGISTRY.REGISTER_RESERVED, migrationController.address],
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
