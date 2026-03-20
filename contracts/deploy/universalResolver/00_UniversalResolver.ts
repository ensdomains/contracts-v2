import { execute } from "@rocketh";
import type { Abi_GatewayProvider } from "generated/abis/GatewayProvider.ts";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.ts";
import { Artifact_UniversalResolverV2 } from 'generated/artifacts/UniversalResolverV2.js';

export default execute(
  async ({ deploy, get, getV1, namedAccounts: { deployer } }) => {
    const rootRegistry =
      get<Abi_PermissionedRegistry>("RootRegistry");

    const batchGatewayProvider = await getV1<Abi_GatewayProvider>(
      "BatchGatewayProvider",
    );

    await deploy("UniversalResolverV2", {
      account: deployer,
      artifact: Artifact_UniversalResolverV2,
      args: [rootRegistry.address, batchGatewayProvider.address],
    });
  },
  {
    tags: ["UniversalResolverV2", "v2"],
    dependencies: ["RootRegistry", "BatchGatewayProvider"],
  },
);
