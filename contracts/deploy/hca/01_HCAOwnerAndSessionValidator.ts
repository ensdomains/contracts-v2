import { artifacts, execute } from "@rocketh";
import type { Abi } from "viem";

import { RHINESTONE_GAS_REFUND_PAYMASTER } from "../../script/deploy-constants.js";
import {
  optionalEnvAddress,
  resolveHCAIntentExecutor,
  resolveHCAPaymentToken,
  resolveHCASecondaryPaymentToken,
  shouldDeployStandaloneHCA,
} from "./_helpers.js";

export default execute(
  async ({ deploy, get, getOrNull, namedAccounts: { deployer }, tags }) => {
    if (!shouldDeployStandaloneHCA(tags)) return;

    const defaultReverseRegistrarAdapter = get<
      (typeof artifacts.DefaultReverseRegistrarAdapter)["abi"]
    >("DefaultReverseRegistrarAdapter");
    const permittedResolverImpl = get<
      (typeof artifacts.PermissionedResolver)["abi"]
    >("PermissionedResolverImpl");
    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");
    const verifiableFactory =
      get<(typeof artifacts.VerifiableFactory)["abi"]>("VerifiableFactory");
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
    const paymentToken = resolveHCAPaymentToken({ getOrNull, tags });
    if (!paymentToken) {
      throw new Error(
        "HCA_PAYMENT_TOKEN or HCA_USDC must be set when no payment token deployment is available",
      );
    }
    const secondaryPaymentToken = resolveHCASecondaryPaymentToken({
      getOrNull,
      tags,
      paymentToken,
    });
    const gasRefundPaymaster =
      optionalEnvAddress("HCA_GAS_REFUND_PAYMASTER") ??
      localExecutor?.address ??
      (tags.sepolia || tags.hasDao
        ? RHINESTONE_GAS_REFUND_PAYMASTER
        : intentExecutor);

    await deploy("HCAOwnerAndSessionValidator", {
      account: deployer,
      artifact: artifacts.HCAOwnerAndSessionValidator,
      args: [
        defaultReverseRegistrarAdapter.address,
        permittedResolverImpl.address,
        ethRegistry.address,
        verifiableFactory.address,
        paymentToken,
        secondaryPaymentToken,
        intentExecutor,
        gasRefundPaymaster,
      ],
    });
  },
  {
    tags: [
      "HCAOwnerAndSessionValidator",
      "StandaloneHCA",
      "hca",
      "migration:phase1:deploy-v2",
      "v2",
    ],
    dependencies: [
      "DefaultReverseRegistrarAdapter",
      "PermissionedResolverImpl",
      "ETHRegistry",
      "VerifiableFactory",
      "MockRegistrationIntentExecutor",
    ],
  },
);
