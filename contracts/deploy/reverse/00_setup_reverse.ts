import { execute } from "@rocketh";
import type { Abi_ENSV1Resolver } from "generated/abis/ENSV1Resolver.ts";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.ts";
import { labelhash, zeroAddress } from "viem";
import { MAX_EXPIRY } from "../../script/deploy-constants.ts";

export default execute(
  async ({ execute: write, get, read, namedAccounts: { deployer } }) => {

    const rootRegistry =
      get<Abi_PermissionedRegistry>("RootRegistry");
    
    const ensV1Resolver = get<Abi_ENSV1Resolver>("ENSV1Resolver");

    const currentStatus = await read(rootRegistry, {
      functionName: 'getStatus',
      args: [BigInt(labelhash('reverse'))],
    })

    if (currentStatus !== 0) {
      console.warn("    - Skipping .reverse setup, already registered in root")
      return
    }

    await write(rootRegistry, {
      account: deployer,
      functionName: "register",
      args: [
        "reverse",
        zeroAddress,
        zeroAddress,
        ensV1Resolver.address,
        0n,
        MAX_EXPIRY,
      ],
    })

    return true;
  },
  {
    id: "reverse:setup v1.0.0",
    tags: ["reverse:setup", "v2"],
    dependencies: ["RootRegistry", "ENSV1Resolver"],
  },
);
