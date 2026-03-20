import { execute } from "@rocketh";
import type { Abi_MockHCAFactoryBasic } from "generated/abis/MockHCAFactoryBasic.ts";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.ts";
import type { Abi_SimpleRegistryMetadata } from "generated/abis/SimpleRegistryMetadata.ts";
import { Artifact_PermissionedRegistry } from 'generated/artifacts/PermissionedRegistry.js';
import { labelhash, zeroAddress } from "viem";
import {
  DEPLOYMENT_ROLES,
  MAX_EXPIRY,
} from "../script/deploy-constants.js";

// TODO: ownership
export default execute(
  async ({ deploy, execute: write, read, get, namedAccounts: { deployer } }) => {
    const rootRegistry =
      get<Abi_PermissionedRegistry>("RootRegistry");

    const hcaFactory =
      get<Abi_MockHCAFactoryBasic>("HCAFactory");

    const registryMetadata = get<
      Abi_SimpleRegistryMetadata
    >("SimpleRegistryMetadata");

    console.log("Deploying ETHRegistry");
    const ethRegistry = await deploy("ETHRegistry", {
      account: deployer,
      artifact: Artifact_PermissionedRegistry,
      args: [
        hcaFactory.address,
        registryMetadata.address,
        deployer,
        DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT,
      ],
    });

    const currentStatus = await read(rootRegistry, {
      functionName: 'getStatus',
      args: [BigInt(labelhash('eth'))],
    })

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

    if (!ethRegistry.newlyDeployed) return

    console.log("  - Setting canonical parent");
    await write(ethRegistry, {
      account: deployer,
      functionName: "setParent",
      args: [rootRegistry.address, "eth"],
    });
  },
  {
    tags: ["ETHRegistry", "v2"],
    dependencies: ["RootRegistry", "HCAFactory", "RegistryMetadata"],
  },
);
