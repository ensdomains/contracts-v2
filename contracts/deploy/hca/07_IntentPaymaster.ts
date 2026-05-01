import { artifacts, execute } from "@rocketh";
import type { Address } from "viem";

import {
  allowIncompleteIntentStack,
  computeIntentExecutorAddress,
  resolveFactoryOwner,
  resolveIntentExecutorArgs,
} from "./_helpers.js";

export default execute(
  async ({
    deploy,
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

    await deploy("IntentPaymaster", {
      account: deployer,
      artifact: artifacts.Paymaster,
      args: [intentExecutorAddress, factoryOwner],
    });
  },
  {
    tags: ["IntentPaymaster", "v2"],
    dependencies: ["IntentAddressBookPrepared", "IntentRouter"],
  },
);
