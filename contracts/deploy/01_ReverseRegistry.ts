import { artifacts, execute } from "@rocketh";
import { labelhash } from "viem";
import { MAX_EXPIRY, ROLES } from "../script/deploy-constants.js";

// TODO: ownership
export default execute(
  async ({
    deploy,
    execute: write,
    read,
    get,
    getV1,
    namedAccounts: { deployer },
  }) => {
    const defaultReverseResolverV1 = getV1<
      (typeof artifacts.DefaultReverseResolver)["abi"]
    >("DefaultReverseResolver");

    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const registryMetadata = get<
      (typeof artifacts.SimpleRegistryMetadata)["abi"]
    >("SimpleRegistryMetadata");

    // create "reverse" registry
    const reverseRegistry = await deploy("ReverseRegistry", {
      account: deployer,
      artifact: artifacts.PermissionedRegistry,
      args: [
        hcaFactory.address,
        registryMetadata.address,
        deployer,
        ROLES.ALL,
      ],
    });

    const expiry = await read(rootRegistry, {
      functionName: "getExpiry",
      args: [BigInt(labelhash("reverse"))],
    });

    if (expiry !== 0n) {
      // already registered, update subregistry and resolver
      await write(rootRegistry, {
        account: deployer,
        functionName: "setSubregistry",
        args: [BigInt(labelhash("reverse")), reverseRegistry.address],
      });

      await write(rootRegistry, {
        account: deployer,
        functionName: "setResolver",
        args: [BigInt(labelhash("reverse")), defaultReverseResolverV1.address],
      });
    } else {
      await write(rootRegistry, {
        account: deployer,
        functionName: "register",
        args: [
          "reverse",
          deployer,
          reverseRegistry.address,
          defaultReverseResolverV1.address,
          0n,
          MAX_EXPIRY,
        ],
      });
    }
  },
  {
    tags: ["ReverseRegistry", "l1"],
    dependencies: [
      "DefaultReverseResolver",
      "RootRegistry",
      "HCAFactory",
      "SimpleRegistryMetadata",
    ],
  },
);
