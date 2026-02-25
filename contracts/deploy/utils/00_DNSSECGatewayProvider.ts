import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer } }) => {
    await deploy("DNSSECGatewayProvider", {
      account: deployer,
      artifact: artifacts.GatewayProvider,
      args: [deployer, ["https://dnssec-oracle.ens.domains/"]],
    });
  },
  {
    tags: ["DNSSECGatewayProvider", "l1"],
  },
);
