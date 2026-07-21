import { artifacts, execute } from "@rocketh";

import { shouldDeployStandaloneHCA } from "./_helpers.js";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer }, tags }) => {
    if (!shouldDeployStandaloneHCA(tags)) return;

    const verifiableFactory = get("VerifiableFactory");
    await deploy("StandaloneHCAFactory", {
      account: deployer,
      artifact: artifacts.StandaloneHCAFactory,
      args: [verifiableFactory.address],
    });
  },
  {
    tags: [
      "StandaloneHCAFactory",
      "StandaloneHCA",
      "hca",
      "migration:phase1:deploy-v2",
      "v2",
    ],
    dependencies: ["VerifiableFactory"],
  },
);
