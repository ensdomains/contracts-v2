import { artifacts, execute } from "@rocketh";
import { labelhash, zeroAddress } from "viem";
import {
  MAX_EXPIRY,
  DEPLOYMENT_ROLES,
  ROLES,
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
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const labelStore = get<(typeof artifacts.ILabelStore)["abi"]>("LabelStore");

    console.log("Deploying ETHRegistry");
    const ethRegistry = await deploy("ETHRegistry", {
      account: deployer,
      artifact: artifacts.PermissionedRegistry,
      args: [labelStore.address, deployer, DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT],
    });

    const currentStatus = await read(rootRegistry, {
      functionName: "getStatus",
      args: [BigInt(labelhash("eth"))],
    });

    if (currentStatus === 0) {
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

    if (ethRegistry.newlyDeployed) {
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
