import { execute } from "@rocketh";
import type { Abi_ENS } from "generated/abis/ENS.js";
import type { Abi_IGatewayProvider } from "generated/abis/IGatewayProvider.js";
import { Artifact_UniversalResolverV1 } from "generated/artifacts/UniversalResolverV1.js";

// Standalone normalizing universal resolver over the v1 registry. It sits
// outside the proxy chain, so nothing resolves through it unless pointed at it.
export default execute(
  async ({ deploy, getV1, namedAccounts: { deployer, owner } }) => {
    const ensRegistry = await getV1<Abi_ENS>("ENSRegistry");
    const batchGatewayProvider = await getV1<Abi_IGatewayProvider>(
      "BatchGatewayProvider",
    );

    await deploy("UniversalResolverV1", {
      account: deployer,
      artifact: Artifact_UniversalResolverV1,
      args: [owner, ensRegistry.address, batchGatewayProvider.address],
    });
    return true;
  },
  {
    id: "universal-resolver:deploy-universal-resolver-v1:v1",
    tags: [
      "UniversalResolverMigration",
      "migration:phase1:deploy-v2",
      "UniversalResolverV1",
      "v2",
    ],
    dependencies: ["ENSRegistry", "BatchGatewayProvider"],
  },
);
