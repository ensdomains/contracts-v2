import { execute } from "@rocketh";
import type { Abi_IContractNamer } from "generated/abis/IContractNamer.js";
import type { Abi_IGatewayProvider } from "generated/abis/IGatewayProvider.js";
import type { Abi_ENS } from "generated/abis/ENS.js";
import { Artifact_ENSV1Resolver } from "generated/artifacts/ENSV1Resolver.js";

export default execute(
  async ({ get, getV1, deploy, namedAccounts: { deployer } }) => {
    const batchGatewayProvider = await getV1<Abi_IGatewayProvider>(
      "BatchGatewayProvider",
    );
    const contractNamer = get<Abi_IContractNamer>("ContractNamer");
    const ensRegistry = await getV1<Abi_ENS>("ENSRegistry");

    // Every pre-migration reservation names this resolver, and nobody can repoint a
    // reservation, so a recorded one is kept even when the build has changed: a
    // replacement would only serve the names reserved after it.
    await deploy(
      "ENSV1Resolver",
      {
        account: deployer,
        artifact: Artifact_ENSV1Resolver,
        args: [
          batchGatewayProvider.address,
          contractNamer.address,
          ensRegistry.address,
        ],
      },
      { skipIfAlreadyDeployed: true },
    );
  },
  {
    tags: ["ENSV1Resolver", "migration:phase1:deploy-v2", "v2"],
    dependencies: ["BatchGatewayProvider", "ContractNamer", "ENSRegistry"],
  },
);
