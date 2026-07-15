import { artifacts, execute } from "@rocketh";

import { shouldDeployStandaloneHCA } from "./_helpers.js";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer }, tags }) => {
    if (!shouldDeployStandaloneHCA(tags)) return;

    const verifiableFactory = get("VerifiableFactory");
    await deploy("StandaloneHCADeployer", {
      account: deployer,
      artifact: artifacts.StandaloneHCADeployer,
      args: [verifiableFactory.address],
    });
  },
  {
    tags: ["StandaloneHCADeployer", "StandaloneHCA", "hca", "v2"],
    dependencies: ["VerifiableFactory"],
  },
);
