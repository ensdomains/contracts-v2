import { artifacts, execute } from "@rocketh";
import type { Abi, Address } from "viem";
import { zeroAddress } from "viem";

import {
  DEFAULT_ENTRY_POINT,
  optionalEnvAddress,
  shouldDeployStandaloneHCA,
} from "./_helpers.js";

export default execute(
  async ({ deploy, get, getOrNull, namedAccounts: { deployer, owner }, tags }) => {
    if (!shouldDeployStandaloneHCA(tags)) return;

    const validator = get<
      (typeof artifacts.OwnerBoundRegistrationSessionValidator)["abi"]
    >("OwnerBoundRegistrationSessionValidator");
    const localExecutor = getOrNull<
      (typeof artifacts.MockRegistrationIntentExecutor)["abi"]
    >("HCARegistrationIntentExecutor");
    const existingExecutor = getOrNull<Abi>("IntentExecutor");
    const intentExecutor =
      optionalEnvAddress("HCA_INTENT_EXECUTOR") ??
      existingExecutor?.address ??
      localExecutor?.address;

    if (!intentExecutor) {
      throw new Error(
        "HCA_INTENT_EXECUTOR must be set when no IntentExecutor deployment is available",
      );
    }

    // This target gate belongs to the initial HCA implementation. A later implementation also
    // receives its own predecessor gate so DAO approvals remain directional.
    const upgradeGate = await deploy("HCAUpgradeGate", {
      account: deployer,
      artifact: artifacts.ApprovedUpgradeGate,
      args: [owner],
    });

    await deploy("StandaloneHCAImplementation", {
      account: deployer,
      artifact: artifacts.StandaloneSingleOwnerHCA,
      args: [
        optionalEnvAddress("HCA_ENTRY_POINT") ?? (DEFAULT_ENTRY_POINT as Address),
        validator.address,
        intentExecutor,
        "0x",
        upgradeGate.address,
        zeroAddress,
      ],
    });
  },
  {
    tags: ["StandaloneHCAImplementation", "StandaloneHCA", "hca", "v2"],
    dependencies: [
      "OwnerBoundRegistrationSessionValidator",
      "HCARegistrationIntentExecutor",
    ],
  },
);
