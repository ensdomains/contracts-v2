import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer, owner } }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    await deploy("PermissionedResolverImpl", {
      account: deployer,
      artifact: artifacts["PermissionedResolver"],
      args: [rootRegistry.address, owner],
    });
  },
  {
    tags: ["PermissionedResolverImpl", "migration:phase1:deploy-v2", "v2"],
    dependencies: ["RootRegistry"],
  },
);
