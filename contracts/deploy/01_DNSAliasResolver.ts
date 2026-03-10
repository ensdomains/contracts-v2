import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, getV1, namedAccounts: { deployer } }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const batchGatewayProvider = getV1<
      (typeof artifacts.GatewayProvider)["abi"]
    >("BatchGatewayProvider");

    const dnsAliasResolver = await deploy("DNSAliasResolver", {
      account: deployer,
      artifact: artifacts.DNSAliasResolver,
      args: [rootRegistry.address, batchGatewayProvider.address],
    });
  },
  {
    tags: ["DNSAliasResolver", "l1"],
    dependencies: ["RootRegistry", "BatchGatewayProvider"],
  },
);
