import { execute } from "@rocketh";
import type { Abi_ILabelStore } from "generated/abis/ILabelStore.js";
import type { Abi_IRegistryURIRenderer } from "generated/abis/IRegistryURIRenderer.js";
import { Artifact_PermissionedRegistry } from "generated/artifacts/PermissionedRegistry.js";
import { DEPLOYMENT_ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({
    deploy,
    get,
    execute: write,
    namedAccounts: { deployer, owner },
  }) => {
    const labelStore = get<Abi_ILabelStore>("LabelStore");
    const uriRenderer = get<Abi_IRegistryURIRenderer>("ENSURIRenderer");

    console.log("Deploying RootRegistry");
    const rootRegistry = await deploy("RootRegistry", {
      account: deployer,
      artifact: Artifact_PermissionedRegistry,
      args: [labelStore.address, deployer, DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT],
    });

    console.log("  - Setting initial URI");
    await write(rootRegistry, {
      account: deployer,
      functionName: "setURI",
      args: ["", uriRenderer.address],
    });

    console.log("  - Granting manager roles");
    await write(rootRegistry, {
      account: deployer,
      functionName: "grantRootRoles",
      args: [DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER, owner],
    });
  },
  {
    tags: ["RootRegistry", "migration:phase1:deploy-v2", "v2"],
    dependencies: ["LabelStore", "ENSURIRenderer"],
  },
);
