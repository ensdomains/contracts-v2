import { artifacts, execute } from "@rocketh";
import { zeroAddress } from "viem";
import {
  MAX_EXPIRY,
  DEPLOYMENT_ROLES,
  ROLES,
} from "../script/deploy-constants.js";

// TODO: ownership
export default execute(
  async ({
    deploy,
    execute: write,
    get,
    namedAccounts: { deployer, owner },
  }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const registryMetadata = get<
      (typeof artifacts.SimpleRegistryMetadata)["abi"]
    >("SimpleRegistryMetadata");

    const labelStore = get<(typeof artifacts.ILabelStore)["abi"]>("LabelStore");

    console.log("Deploying ETHRegistry");
    const ethRegistry = await deploy("ETHRegistry", {
      account: deployer,
      artifact: artifacts.PermissionedRegistry,
      args: [
        hcaFactory.address,
        registryMetadata.address,
        labelStore.address,
        deployer,
        DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT,
      ],
    });

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

    console.log("  - Setting canonical parent");
    await write(ethRegistry, {
      account: deployer,
      functionName: "setParent",
      args: [rootRegistry.address, "eth"],
    });

    console.log("  - Granting CAN_NAME to owner");
    await write(ethRegistry, {
      functionName: "grantRootRoles",
      args: [ROLES.REGISTRY.CAN_NAME, owner],
      account: deployer,
    });
  },
  {
    tags: ["ETHRegistry", "v2"],
    dependencies: [
      "RootRegistry",
      "HCAFactory",
      "RegistryMetadata",
      "LabelStore",
    ],
  },
);
