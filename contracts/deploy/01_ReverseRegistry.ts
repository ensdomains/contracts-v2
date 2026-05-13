import { artifacts, execute } from "@rocketh";
import { MAX_EXPIRY, DEPLOYMENT_ROLES } from "../script/deploy-constants.js";
import { zeroAddress } from "viem";

export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const registryMetadata = get<
      (typeof artifacts.SimpleRegistryMetadata)["abi"]
    >("SimpleRegistryMetadata");

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
        registryMetadata.address,
        labelStore.address,
        deployer,
        DEPLOYMENT_ROLES.REVERSE_REGISTRY_ROOT,
      ],
    });

    console.log("  - Registering in parent");
    await write(rootRegistry, {
      account: deployer,
      functionName: "register",
      args: [
        label,
        zeroAddress,
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
    tags: ["ETHRegistry", "v2"],
    dependencies: [
      "RootRegistry",
      "HCAFactory",
      "RegistryMetadata",
      "LabelStore",
      "ENSV1Resolver",
    ],
  },
);
