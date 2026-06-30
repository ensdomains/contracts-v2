import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer } }) => {
    await deploy("VerifiableFactory", {
      account: deployer,
      artifact: artifacts.VerifiableFactory,
    });
  },
  {
    tags: ["VerifiableFactory", "migration:phase1:deploy-v2", "v2"],
  },
);
