import { artifacts, execute } from "@rocketh";
import { DEPLOYMENT_ROLES, MAX_EXPIRY } from "../script/deploy-constants.js";

// TODO: ownership
export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const defaultReverseResolverV1 = get<
      (typeof artifacts.DefaultReverseResolver)["abi"]
    >("DefaultReverseResolver");

    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const registryMetadata = get<
      (typeof artifacts.SimpleRegistryMetadata)["abi"]
    >("SimpleRegistryMetadata");

    // ReverseRegistry root and .reverse/.addr tokens use full role bitmap
    const reverseRoles = DEPLOYMENT_ROLES.REVERSE_AND_ADDR;

    const reverseRegistry = await deploy("ReverseRegistry", {
      account: deployer,
      artifact: artifacts.PermissionedRegistry,
      args: [
        hcaFactory.address,
        registryMetadata.address,
        deployer,
        reverseRoles,
      ],
    });

    await write(rootRegistry, {
      account: deployer,
      functionName: "register",
      args: [
        "reverse",
        deployer,
        reverseRegistry.address,
        defaultReverseResolverV1.address,
        reverseRoles,
        MAX_EXPIRY,
      ],
    });

    await write(reverseRegistry, {
      account: deployer,
      functionName: "setParent",
      args: [rootRegistry.address, "reverse"],
    });
  },
  {
    tags: ["ReverseRegistry", "v2"],
    dependencies: [
      "DefaultReverseResolver",
      "RootRegistry",
      "HCAFactory",
      "SimpleRegistryMetadata",
    ],
  },
);
