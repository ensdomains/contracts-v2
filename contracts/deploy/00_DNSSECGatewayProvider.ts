import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer, owner } }) => {
    await deploy("DNSSECGatewayProvider", {
      account: deployer,
      artifact: artifacts.GatewayProvider,
      args: [owner, ["https://dnssec-oracle.ens.domains/"]],
    });
  },
  {
    tags: ["DNSSECGatewayProvider", "v2"],
  },
);
