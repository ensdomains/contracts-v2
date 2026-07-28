import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer, owner } }) => {
    const trustedHCASet = await deploy("TrustedHCASet", {
      account: deployer,
      artifact: artifacts.PermissionedAddressSet,
      args: [owner],
    });
  },
  { tags: ["TrustedHCASet", "v2", "hca"] },
);
