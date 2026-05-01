import { artifacts, execute } from "@rocketh";

import { resolveFactoryOwner } from "./_helpers.js";

export default execute(
  async ({ deploy, namedAccounts: { deployer, owner } }) => {
    await deploy("IntentAddressBook", {
      account: deployer,
      artifact: artifacts.AddressBook,
      args: [resolveFactoryOwner(deployer, owner)],
    });
  },
  {
    tags: ["IntentAddressBook", "v2"],
  },
);
