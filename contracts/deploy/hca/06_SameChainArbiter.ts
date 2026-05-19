import { artifacts, execute } from "@rocketh";

import {
  allowIncompleteIntentStack,
  resolveCompact,
} from "./_helpers.js";

export default execute(
  async ({ deploy, get, network, namedAccounts: { deployer } }) => {
    const addressBook = get<(typeof artifacts.AddressBook)["abi"]>(
      "IntentAddressBook",
    );
    const router = get<(typeof artifacts.Router)["abi"]>("IntentRouter");

    await deploy("SameChainArbiter", {
      account: deployer,
      artifact: artifacts.SameChainArbiter,
      args: [
        router.address,
        resolveCompact(allowIncompleteIntentStack(network.tags)),
        addressBook.address,
      ],
    });
  },
  {
    tags: ["SameChainArbiter", "v2"],
    dependencies: ["IntentAddressBookPrepared", "IntentRouter"],
  },
);
