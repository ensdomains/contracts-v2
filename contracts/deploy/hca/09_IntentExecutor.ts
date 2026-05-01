import { artifacts, execute } from "@rocketh";

import {
  allowIncompleteIntentStack,
  INTENT_EXECUTOR_SALT,
  resolveFactoryOwner,
  resolveIntentExecutorArgs,
} from "./_helpers.js";

export default execute(
  async ({
    deploy,
    get,
    network,
    namedAccounts: { deployer, owner },
  }) => {
    const addressBook = get<(typeof artifacts.AddressBook)["abi"]>(
      "IntentAddressBook",
    );
    const router = get<(typeof artifacts.Router)["abi"]>("IntentRouter");

    await deploy(
      "IntentExecutor",
      {
        account: deployer,
        artifact: artifacts.IntentExecutor,
        args: resolveIntentExecutorArgs({
          router: router.address,
          addressBook: addressBook.address,
          factoryOwner: resolveFactoryOwner(deployer, owner),
          allowFallback: allowIncompleteIntentStack(network.tags),
        }),
      },
      { deterministic: { type: "create2", salt: INTENT_EXECUTOR_SALT } },
    );
  },
  {
    tags: ["IntentExecutor", "v2"],
    dependencies: ["IntentAddressBookSetup", "IntentRouter"],
  },
);
