import { artifacts, execute } from "@rocketh";

import { shouldDeployStandaloneHCA } from "./_helpers.js";

export default execute(
  async ({
    execute: write,
    get,
    namedAccounts: { owner, deployer },
    read,
    tags,
  }) => {
    if (!shouldDeployStandaloneHCA(tags)) return;

    const account = owner ?? deployer;
    const implementation = get<
      (typeof artifacts.StandaloneSingleOwnerHCA)["abi"]
    >("StandaloneHCAImplementation");

    const trustedHCASet =
      get<(typeof artifacts.PermissionedAddressSet)["abi"]>("TrustedHCASet");

    const isTrusted = await read(trustedHCASet, {
      functionName: "includes",
      args: [implementation.address],
    });
    if (isTrusted) return;

    await write(trustedHCASet, {
      account,
      functionName: "approve",
      args: [implementation.address, true],
    });
  },
  {
    tags: [
      "setup:StandaloneHCA",
      "StandaloneHCA",
      "hca",
      "migration:phase1:deploy-v2",
      "v2",
    ],
    dependencies: ["TrustedHCASet", "StandaloneHCAImplementation"],
  },
);
