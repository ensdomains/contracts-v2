import { artifacts, execute } from "@rocketh";
import type { Address } from "viem";

import {
  allowIncompleteIntentStack,
  computeIntentExecutorAddress,
  INTENT_EXECUTOR_ID,
  PAYMASTER_ID,
  resolveFactoryOwner,
  resolveIntentExecutorArgs,
  SAMECHAIN_ARBITER_ID,
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
    const allowFallback = allowIncompleteIntentStack(network.tags);
    const addressBook = get<(typeof artifacts.AddressBook)["abi"]>(
      "IntentAddressBook",
    );
    const paymaster = get<(typeof artifacts.Paymaster)["abi"]>(
      "IntentPaymaster",
    );
    const router = get<(typeof artifacts.Router)["abi"]>("IntentRouter");
    const sameChainArbiter = get<(typeof artifacts.SameChainArbiter)["abi"]>(
      "SameChainArbiter",
    );
    const intentExecutorAddress = computeIntentExecutorAddress({
      create2Factory: config.network.deterministicDeployment.create2
        .factory as Address,
      args: resolveIntentExecutorArgs({
        router: router.address,
        addressBook: addressBook.address,
        factoryOwner,
        allowFallback,
      }),
    });

    await write(addressBook, {
      account: factoryOwner,
      functionName: "setAddress",
      args: [SAMECHAIN_ARBITER_ID, sameChainArbiter.address],
    });
    await write(addressBook, {
      account: factoryOwner,
      functionName: "setAddress",
      args: [PAYMASTER_ID, paymaster.address],
    });
    await write(addressBook, {
      account: factoryOwner,
      functionName: "setAddress",
      args: [INTENT_EXECUTOR_ID, intentExecutorAddress],
    });
  },
  {
    tags: ["IntentAddressBookSetup", "v2"],
    dependencies: [
      "IntentAddressBookPrepared",
      "IntentRouter",
      "SameChainArbiter",
      "IntentPaymaster",
    ],
  },
);
