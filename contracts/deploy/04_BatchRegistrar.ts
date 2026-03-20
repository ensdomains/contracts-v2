import { execute } from "@rocketh";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.ts";
import { Artifact_BatchRegistrar } from 'generated/artifacts/BatchRegistrar.js';
import { ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const ethRegistry =
      get<Abi_PermissionedRegistry>("ETHRegistry");

    const batchRegistrar = await deploy("BatchRegistrar", {
      account: deployer,
      artifact: Artifact_BatchRegistrar,
      args: [ethRegistry.address, deployer],
    });

    await write(ethRegistry, {
      account: deployer,
      functionName: "grantRootRoles",
      args: [
        ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW,
        batchRegistrar.address,
      ],
    });
  },
  {
    tags: ["BatchRegistrar", "l1"],
    dependencies: ["ETHRegistry"],
  },
);
