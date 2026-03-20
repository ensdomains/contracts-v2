import { execute } from "@rocketh";
import { Artifact_GatewayProvider } from 'generated/artifacts/GatewayProvider.js';

export default execute(
  async ({ deploy, namedAccounts: { deployer } }) => {
    await deploy("DNSSECGatewayProvider", {
      account: deployer,
      artifact: Artifact_GatewayProvider,
      args: [deployer, ["https://dnssec-oracle.ens.domains/"]],
    });
  },
  {
    tags: ["DNSSECGatewayProvider", "v2"],
  },
);
