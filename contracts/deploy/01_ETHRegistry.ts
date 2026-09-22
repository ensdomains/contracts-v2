import { execute } from "@rocketh";
import type { Abi_ILabelStore } from "generated/abis/ILabelStore.js";
import { Artifact_PermissionedRegistry } from "generated/artifacts/PermissionedRegistry.js";
import { isAddressEqual, zeroAddress } from "viem";
import { idFromLabel } from "../test/utils/utils.js";
import {
  MAX_EXPIRY,
  DEPLOYMENT_ROLES,
  ROLES,
  STATUS,
} from "../script/deploy-constants.js";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    read,
    namedAccounts: { deployer, owner },
  }) => {
    const rootRegistry =
      get<(typeof Artifact_PermissionedRegistry)["abi"]>("RootRegistry");
    const labelStore = get<Abi_ILabelStore>("LabelStore");

    console.log("Deploying ETHRegistry");
    const ethRegistry = await deploy("ETHRegistry", {
      account: deployer,
      artifact: Artifact_PermissionedRegistry,
      args: [labelStore.address, deployer, DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT],
    });

    const currentStatus = await read(rootRegistry, {
      functionName: "getStatus",
      args: [idFromLabel("eth")],
    });

    if (currentStatus === STATUS.AVAILABLE) {
      console.log("  - Registering in parent");
      await write(rootRegistry, {
        account: deployer,
        functionName: "register",
        args: [
          "eth",
          deployer,
          ethRegistry.address,
          zeroAddress,
          DEPLOYMENT_ROLES.ETH_TOKEN,
          MAX_EXPIRY,
        ],
      });
    }

    const [currentParent, currentLabel] = await read(ethRegistry, {
      functionName: "getParent",
    });

    if (
      !isAddressEqual(currentParent, rootRegistry.address) ||
      currentLabel !== "eth"
    ) {
      console.log("  - Setting canonical parent");
      await write(ethRegistry, {
        account: deployer,
        functionName: "setParent",
        args: [rootRegistry.address, "eth"],
      });
    }

    console.log("  - Granting CAN_NAME to owner");
    await write(ethRegistry, {
      functionName: "grantRootRoles",
      args: [ROLES.REGISTRY.CAN_NAME, owner],
      account: deployer,
    });
  },
  {
    tags: ["ETHRegistry", "migration:phase1:deploy-v2", "v2"],
    dependencies: ["RootRegistry", "LabelStore"],
  },
);
