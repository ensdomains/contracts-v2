import { execute } from "@rocketh";
import type { Abi_ILabelStore } from "generated/abis/ILabelStore.js";
import type { Abi_IRegistryURIRenderer } from "generated/abis/IRegistryURIRenderer.js";
import { Artifact_PermissionedRegistry } from "generated/artifacts/PermissionedRegistry.js";
import { isAddressEqual } from "viem";
import { DEPLOYMENT_ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({
    deploy,
    get,
    read,
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

    const [[currentURI, currentRenderer], ownerIsManager] = await Promise.all([
      read(rootRegistry, { functionName: "getURI" }),
      read(rootRegistry, {
        functionName: "hasRootRoles",
        args: [DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER, owner],
      }),
    ]);

    if (currentURI || !isAddressEqual(currentRenderer, uriRenderer.address)) {
      console.log("  - Setting initial URI");
      await write(rootRegistry, {
        account: deployer,
        functionName: "setURI",
        args: ["", uriRenderer.address],
      });
    }

    if (!ownerIsManager) {
      console.log("  - Granting manager roles");
      await write(rootRegistry, {
        account: deployer,
        functionName: "grantRootRoles",
        args: [DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER, owner],
      });
    }
  },
  {
    tags: ["RootRegistry", "migration:phase1:deploy-v2", "v2"],
    dependencies: ["LabelStore", "ENSURIRenderer"],
  },
);
