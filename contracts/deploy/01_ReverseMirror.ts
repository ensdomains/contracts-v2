import { execute } from "@rocketh";
import type { Abi_IPermissionedRegistry } from "generated/abis/IPermissionedRegistry.js";
import type { Abi_ENSV1Resolver } from "generated/abis/ENSV1Resolver.js";
import { zeroAddress } from "viem";
import { DEPLOYMENT_ROLES, MAX_EXPIRY } from "../script/deploy-constants.js";

export default execute(
  async ({ execute: write, get, namedAccounts: { deployer, owner } }) => {
    const rootRegistry = get<Abi_IPermissionedRegistry>("RootRegistry");
    const ensV1Resolver = get<Abi_ENSV1Resolver>("ENSV1Resolver");

    await write(rootRegistry, {
      account: deployer,
      functionName: "register",
      args: [
        "reverse",
        owner,
        zeroAddress,
        ensV1Resolver.address,
        DEPLOYMENT_ROLES.REVERSE_REGISTRY_ROOT,
        MAX_EXPIRY,
      ],
    });
  },
  {
    tags: ["ReverseMirror", "v2"],
    dependencies: ["RootRegistry", "ENSV1Resolver"],
  },
);
