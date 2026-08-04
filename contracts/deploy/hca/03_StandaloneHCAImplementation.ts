import { artifacts, execute } from "@rocketh";
import type { Abi, Address } from "viem";
import { zeroAddress } from "viem";

import {
  DEFAULT_ENTRY_POINT,
  optionalEnvAddress,
  resolveHCAIntentExecutor,
  shouldDeployStandaloneHCA,
} from "./_helpers.js";

export default execute(
  async ({
    deploy,
    get,
    getOrNull,
    namedAccounts: { deployer, owner },
    tags,
  }) => {
    if (!shouldDeployStandaloneHCA(tags)) return;

    const validator = get<
      (typeof artifacts.HCAOwnerAndSessionValidator)["abi"]
    >("HCAOwnerAndSessionValidator");
    const localExecutor = getOrNull<
      (typeof artifacts.MockRegistrationIntentExecutor)["abi"]
    >("MockRegistrationIntentExecutor");
    const existingExecutor = getOrNull<Abi>("IntentExecutor");
    const intentExecutor = resolveHCAIntentExecutor({
      tags,
      localExecutor: localExecutor?.address,
      existingExecutor: existingExecutor?.address,
    });

    if (!intentExecutor) {
      throw new Error(
        "HCA_INTENT_EXECUTOR must be set when no IntentExecutor deployment is available",
      );
    }

    // Each implementation uses independent target and predecessor sets so approvals remain
    // directional across an upgrade.
    const upgradeSet = await deploy("HCAUpgradeSet", {
      account: deployer,
      artifact: artifacts.PermissionedAddressSet,
      args: [owner],
    });

    await deploy("StandaloneHCAImplementation", {
      account: deployer,
      artifact: artifacts.StandaloneSingleOwnerHCA,
      args: [
        optionalEnvAddress("HCA_ENTRY_POINT") ??
          (DEFAULT_ENTRY_POINT as Address),
        validator.address,
        intentExecutor,
        "0x",
        upgradeSet.address,
        zeroAddress,
      ],
    });
  },
  {
    tags: [
      "StandaloneHCAImplementation",
      "StandaloneHCA",
      "hca",
      "migration:phase1:deploy-v2",
      "v2",
    ],
    dependencies: [
      "HCAOwnerAndSessionValidator",
      "MockRegistrationIntentExecutor",
    ],
  },
);
