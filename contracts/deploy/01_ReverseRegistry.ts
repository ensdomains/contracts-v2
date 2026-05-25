import { artifacts, execute } from "@rocketh";
import { MAX_EXPIRY, DEPLOYMENT_ROLES } from "../script/deploy-constants.js";
import { zeroAddress } from "viem";

export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const labelStore = get<(typeof artifacts.ILabelStore)["abi"]>("LabelStore");

    const ensV1Resolver =
      get<(typeof artifacts.ENSV1Resolver)["abi"]>("ENSV1Resolver");

    const label = "reverse";

    console.log(`Deploying ReverseRegistry`);
    const reverseRegistry = await deploy("ReverseRegistry", {
      account: deployer,
      artifact: artifacts.PermissionedRegistry,
      args: [
        hcaFactory.address,
        labelStore.address,
        deployer,
        DEPLOYMENT_ROLES.REVERSE_REGISTRY_ROOT,
      ],
    });

    console.log("  - Reserving in parent");
    await write(rootRegistry, {
      account: deployer,
      functionName: "register",
      args: [
        label,
        zeroAddress, // owner
        reverseRegistry.address,
        ensV1Resolver.address,
        0n,
        MAX_EXPIRY,
      ],
    });

    console.log("  - Setting canonical parent");
    await write(reverseRegistry, {
      account: deployer,
      functionName: "setParent",
      args: [rootRegistry.address, label],
    });
  },
  {
    tags: ["ReverseRegistry", "v2"],
    dependencies: ["RootRegistry", "HCAFactory", "LabelStore", "ENSV1Resolver"],
  },
);
