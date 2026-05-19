import { artifacts, execute } from "@rocketh";

import {
  allowIncompleteIntentStack,
  resolveAtomicFillSigner,
  resolveFactoryOwner,
} from "./_helpers.js";

export default execute(
  async ({ deploy, network, namedAccounts: { deployer, owner } }) => {
    const factoryOwner = resolveFactoryOwner(deployer, owner);

    await deploy("IntentRouter", {
      account: deployer,
      artifact: artifacts.Router,
      args: [
        resolveAtomicFillSigner(
          factoryOwner,
          allowIncompleteIntentStack(network.tags),
        ),
        factoryOwner,
        factoryOwner,
      ],
    });
  },
  {
    tags: ["IntentRouter", "v2"],
  },
);
