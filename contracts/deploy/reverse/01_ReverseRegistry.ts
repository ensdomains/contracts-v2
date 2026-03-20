import { execute } from "@rocketh";
import type { Abi_DefaultReverseResolver } from "generated/abis/DefaultReverseResolver.ts";
import type { Abi_MockHCAFactoryBasic } from "generated/abis/MockHCAFactoryBasic.ts";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.ts";
import type { Abi_SimpleRegistryMetadata } from "generated/abis/SimpleRegistryMetadata.ts";
import { Artifact_PermissionedRegistry } from 'generated/artifacts/PermissionedRegistry.js';
import { labelhash } from "viem";
import { DEPLOYMENT_ROLES, MAX_EXPIRY } from "../../script/deploy-constants.ts";

// TODO: enable v2-native reverse namespace
const ENABLED = false;

export default execute(
  async ({ deploy, execute: write, get, read, getV1, namedAccounts: { deployer } }) => {
    if (!ENABLED) {
      console.warn('    - Skipping ReverseRegistry deployment, not yet enabled.')
      return
    }

    const defaultReverseResolverV1 = await getV1<
      Abi_DefaultReverseResolver
    >("DefaultReverseResolver");

    const rootRegistry =
      get<Abi_PermissionedRegistry>("RootRegistry");

    const hcaFactory =
      get<Abi_MockHCAFactoryBasic>("HCAFactory");

    const registryMetadata = get<
      Abi_SimpleRegistryMetadata
    >("SimpleRegistryMetadata");

    // ReverseRegistry root and .reverse/.addr tokens use full role bitmap
    const reverseRoles = DEPLOYMENT_ROLES.REVERSE_AND_ADDR;

    const reverseRegistry = await deploy("ReverseRegistry", {
      account: deployer,
      artifact: Artifact_PermissionedRegistry,
      args: [
        hcaFactory.address,
        registryMetadata.address,
        deployer,
        reverseRoles,
      ],
    });

    const currentStatus = await read(rootRegistry, {
      functionName: 'getStatus',
      args: [BigInt(labelhash('reverse'))],
    })

    if (currentStatus === 0) {
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
    } else {
      console.warn("  - ReverseRegistry already registered in parent")
    }
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
