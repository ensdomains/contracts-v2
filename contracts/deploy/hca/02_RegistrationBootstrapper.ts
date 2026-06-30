import { artifacts, execute } from "@rocketh";

import { shouldDeployStandaloneHCA } from "./_helpers.js";

export default execute(
  async ({ deploy, namedAccounts: { deployer }, tags }) => {
    if (!shouldDeployStandaloneHCA(tags)) return;

    await deploy("RegistrationBootstrapper", {
      account: deployer,
      artifact: artifacts.RegistrationBootstrapper,
      args: [],
    });
  },
  {
    tags: ["RegistrationBootstrapper", "StandaloneHCA", "hca", "v2"],
  },
);
