import { execute } from "@rocketh";
import type { Abi_MockHCAFactoryBasic } from "generated/abis/MockHCAFactoryBasic.ts";
import type { Abi_SimpleRegistryMetadata } from "generated/abis/SimpleRegistryMetadata.ts";
import { Artifact_PermissionedRegistry } from 'generated/artifacts/PermissionedRegistry.js';
import { DEPLOYMENT_ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<Abi_MockHCAFactoryBasic>("HCAFactory");

    const registryMetadata = get<
      Abi_SimpleRegistryMetadata
    >("SimpleRegistryMetadata");

    await deploy("RootRegistry", {
      account: deployer,
      artifact: Artifact_PermissionedRegistry,
      args: [
        hcaFactory.address,
        registryMetadata.address,
        deployer,
        DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT,
      ],
    });
  },
  {
    tags: ["RootRegistry", "v2"],
    dependencies: ["HCAFactory", "RegistryMetadata"],
  },
);
