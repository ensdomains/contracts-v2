import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer, owner } }) => {
    await deploy("PermissionedResolverImpl", {
      account: deployer,
      artifact: artifacts["PermissionedResolver"],
      args: [owner],
    });
  },
  {
    tags: ["PermissionedResolverImpl", "migration:phase1:deploy-v2", "v2"],
  },
);
