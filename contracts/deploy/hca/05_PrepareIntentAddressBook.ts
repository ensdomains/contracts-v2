import { artifacts, execute } from "@rocketh";
import type { Address } from "viem";

import {
  allowIncompleteIntentStack,
  computeIntentExecutorAddress,
  INTENT_EXECUTOR_ID,
  resolveFactoryOwner,
  resolveIntentExecutorArgs,
} from "./_helpers.js";

export default execute(
  async ({
    execute: write,
    get,
    network,
    config,
    namedAccounts: { deployer, owner },
  }) => {
    const factoryOwner = resolveFactoryOwner(deployer, owner);
    const addressBook = get<(typeof artifacts.AddressBook)["abi"]>(
      "IntentAddressBook",
    );
    const router = get<(typeof artifacts.Router)["abi"]>("IntentRouter");
    const intentExecutorAddress = computeIntentExecutorAddress({
      create2Factory: config.network.deterministicDeployment.create2
        .factory as Address,
      args: resolveIntentExecutorArgs({
        router: router.address,
        addressBook: addressBook.address,
        factoryOwner,
        allowFallback: allowIncompleteIntentStack(network.tags),
      }),
    });

    await write(addressBook, {
      account: factoryOwner,
      functionName: "setAddress",
      args: [INTENT_EXECUTOR_ID, intentExecutorAddress],
    });
  },
  {
    tags: ["IntentAddressBookPrepared", "v2"],
    dependencies: ["IntentAddressBook", "IntentRouter"],
  },
);
