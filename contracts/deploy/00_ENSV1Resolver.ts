import { execute } from "@rocketh";
import type { Abi_ENSRegistry } from "generated/abis/ENSRegistry.ts";
import type { Abi_GatewayProvider } from "generated/abis/GatewayProvider.ts";
import { Artifact_ENSV1Resolver } from 'generated/artifacts/ENSV1Resolver.js';

export default execute(
  async ({ get, getV1, deploy, namedAccounts: { deployer } }) => {
    const ensRegistryV1 =
      await getV1<Abi_ENSRegistry>("ENSRegistry");

    const batchGatewayProvider = await getV1<Abi_GatewayProvider>(
      "BatchGatewayProvider",
    );

    await deploy("ENSV1Resolver", {
      account: deployer,
      artifact: Artifact_ENSV1Resolver,
      args: [ensRegistryV1.address, batchGatewayProvider.address],
    });
  },
  {
    tags: ["ENSV1Resolver", "v2"],
    dependencies: ["ENSRegistry", "BatchGatewayProvider"],
  },
);
