import { execute } from "@rocketh";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.js";
import type { Abi_IContractNamer } from "generated/abis/IContractNamer.js";
import type { Abi_IAddressSet } from "generated/abis/IAddressSet.js";
import type { Abi_IVerifiableFactory } from "generated/abis/IVerifiableFactory.js";
import type { Abi_LockedMigrationController } from "generated/abis/LockedMigrationController.js";
import { Artifact_UniversalHelper } from "generated/artifacts/UniversalHelper.js";

export default execute(
  async ({ get, deploy, namedAccounts: { deployer } }) => {
    const rootRegistry = get<Abi_PermissionedRegistry>("RootRegistry");
    const verifiableFactory = get<Abi_IVerifiableFactory>("VerifiableFactory");
    const trustedRegistrySet = get<Abi_IAddressSet>("TrustedRegistrySet");
    const lockedMigrationController = get<Abi_LockedMigrationController>(
      "LockedMigrationController",
    );
    const contractNamer = get<Abi_IContractNamer>("ContractNamer");

    await deploy("UniversalHelper", {
      account: deployer,
      artifact: Artifact_UniversalHelper,
      args: [
        rootRegistry.address,
        verifiableFactory.address,
        trustedRegistrySet.address,
        lockedMigrationController.address,
        contractNamer.address,
      ],
    });
  },
  {
    tags: ["UniversalHelper", "v2", "migration:phase1:deploy-v2"],
    dependencies: [
      "RootRegistry",
      "VerifiableFactory",
      "TrustedRegistrySet",
      "LockedMigrationController",
      "ContractNamer",
    ],
  },
);
