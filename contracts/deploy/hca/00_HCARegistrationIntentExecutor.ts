import { artifacts, execute } from "@rocketh";

import {
  shouldDeployMockIntentExecutor,
  shouldDeployStandaloneHCA,
} from "./_helpers.js";

export default execute(
  async ({ deploy, namedAccounts: { deployer }, tags }) => {
    if (!shouldDeployStandaloneHCA(tags)) return;
    if (process.env.HCA_INTENT_EXECUTOR) return;
    if (!shouldDeployMockIntentExecutor(tags)) return;

    await deploy("HCARegistrationIntentExecutor", {
      account: deployer,
      artifact: artifacts.MockRegistrationIntentExecutor,
      args: [],
    });
  },
  {
    tags: [
      "HCARegistrationIntentExecutor",
      "StandaloneHCA",
      "hca",
      "migration:phase1:deploy-v2",
      "v2",
    ],
  },
);
