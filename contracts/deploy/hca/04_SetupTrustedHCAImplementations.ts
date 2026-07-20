import { artifacts, execute } from "@rocketh";

import { shouldDeployStandaloneHCA } from "./_helpers.js";

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
    const defaultReverseRegistrarAdapter =
      getOrNull<(typeof artifacts.DefaultReverseRegistrarAdapter)["abi"]>(
        "DefaultReverseRegistrarHCAAdapter",
      ) ??
      get<(typeof artifacts.DefaultReverseRegistrarAdapter)["abi"]>(
        "DefaultReverseRegistrarAdapter",
      );

    const trusted = await read(defaultReverseRegistrarAdapter, {
      functionName: "trustedHCAImplementations",
      args: [implementation.address],
    });
    if (trusted) return;

    await write(defaultReverseRegistrarAdapter, {
      account,
      functionName: "setTrustedHCAImplementation",
      args: [implementation.address, true],
    });
  },
  {
    tags: ["setup:StandaloneHCA", "StandaloneHCA", "hca", "v2"],
    dependencies: [
      "StandaloneHCAImplementation",
      "DefaultReverseRegistrarHCAAdapter",
    ],
  },
);
