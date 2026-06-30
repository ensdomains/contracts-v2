import { artifacts, execute } from "@rocketh";
import type { Abi, Address } from "viem";

import { shouldDeployStandaloneHCA } from "./_helpers.js";

type AdapterDeployment = {
  address: Address;
  abi: Abi;
};

export default execute(
  async ({
    execute: write,
    get,
    getOrNull,
    namedAccounts: { owner, deployer },
    read,
    tags,
  }) => {
    if (!shouldDeployStandaloneHCA(tags)) return;

    const account = owner ?? deployer;
    const implementation =
      get<(typeof artifacts.StandaloneSingleOwnerHCA)["abi"]>(
        "StandaloneHCAImplementation",
      );
    const reverseRegistrarAdapter =
      get<(typeof artifacts.ReverseRegistrarAdapter)["abi"]>(
        "ReverseRegistrarAdapter",
      );
    const defaultReverseRegistrarAdapter = getOrNull<
      (typeof artifacts.DefaultReverseRegistrarAdapter)["abi"]
    >("DefaultReverseRegistrarAdapter");

    for (const adapter of [reverseRegistrarAdapter, defaultReverseRegistrarAdapter]) {
      if (!adapter) continue;

      const hcaAdapter = adapter as AdapterDeployment;
      const trusted = await read(hcaAdapter, {
        functionName: "trustedHCAImplementations",
        args: [implementation.address],
      });
      if (trusted) continue;

      await write(hcaAdapter, {
        account,
        functionName: "setTrustedHCAImplementation",
        args: [implementation.address, true],
      });
    }
  },
  {
    tags: ["setup:StandaloneHCA", "StandaloneHCA", "hca", "v2"],
    dependencies: [
      "StandaloneHCAImplementation",
      "ReverseRegistrarAdapter",
      "DefaultReverseRegistrarAdapter",
    ],
  },
);
