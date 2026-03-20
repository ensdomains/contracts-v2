import { execute } from "@rocketh";
import type { Abi_GatewayProvider } from "generated/abis/GatewayProvider.ts";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.ts";
import { Artifact_DNSAliasResolver } from 'generated/artifacts/DNSAliasResolver.js';

export default execute(
  async ({ deploy, get, getV1, namedAccounts: { deployer } }) => {
    const rootRegistry =
      get<Abi_PermissionedRegistry>("RootRegistry");

    const batchGatewayProvider = await getV1<Abi_GatewayProvider>(
      "BatchGatewayProvider",
    );

    const dnsAliasResolver = await deploy("DNSAliasResolver", {
      account: deployer,
      artifact: Artifact_DNSAliasResolver,
      args: [rootRegistry.address, batchGatewayProvider.address],
    });
  },
  {
    tags: ["DNSAliasResolver", "v2"],
    dependencies: ["RootRegistry", "BatchGatewayProvider"],
  },
);
