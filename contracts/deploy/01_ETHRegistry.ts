import { artifacts, execute } from "@rocketh";
import { zeroAddress } from "viem";
import { MAX_EXPIRY, DEPLOYMENT_ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const hcaFactory =
      get<(typeof artifacts.HCAFactory)["abi"]>("HCAFactory");

    const labelStore = get<(typeof artifacts.ILabelStore)["abi"]>("LabelStore");

    console.log("Deploying ETHRegistry");
    const ethRegistry = await deploy("ETHRegistry", {
      account: deployer,
      artifact: artifacts.PermissionedRegistry,
      args: [
        hcaFactory.address,
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

    await write(ethRegistry, {
      account: deployer,
      functionName: "setParent",
      args: [rootRegistry.address, "eth"],
    });

    console.log("  - Setting canonical parent");
    await write(ethRegistry, {
      account: deployer,
      functionName: "setParent",
      args: [rootRegistry.address, "eth"],
    });
  },
  {
    tags: ["ETHRegistry", "v2"],
    dependencies: ["RootRegistry", "SetupHCAFactory", "LabelStore"],
  },
);
