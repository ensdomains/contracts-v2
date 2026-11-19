import { execute } from "@rocketh";
import type { Abi_IPermissionedRegistry } from "generated/abis/IPermissionedRegistry.js";
import { Artifact_BatchRegistrar } from "generated/artifacts/BatchRegistrar.js";
import { DEPLOYMENT_ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    read,
    namedAccounts: { deployer },
  }) => {
    const ethRegistry = get<Abi_IPermissionedRegistry>("ETHRegistry");

    const batchRegistrar = await deploy("BatchRegistrar", {
      account: deployer,
      artifact: Artifact_BatchRegistrar,
      args: [ethRegistry.address, deployer],
    });

    const granted = await read(ethRegistry, {
      functionName: "hasRootRoles",
      args: [DEPLOYMENT_ROLES.ETH_REGISTRAR_ROOT, batchRegistrar.address],
    });
    if (!granted) {
      await write(ethRegistry, {
        account: deployer,
        functionName: "grantRootRoles",
        args: [DEPLOYMENT_ROLES.ETH_REGISTRAR_ROOT, batchRegistrar.address],
      });
    }
  },
  {
    tags: ["BatchRegistrar", "migration:phase1:deploy-v2", "v2"],
    dependencies: ["ETHRegistry"],
  },
);
