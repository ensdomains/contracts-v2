import { artifacts, execute } from "@rocketh";
import type { Address } from "viem";

import {
  MAINNET_DAI,
  MAINNET_USDC,
  SEPOLIA_USDC,
} from "../../script/deploy-constants.js";
import {
  optionalEnvAddress,
  shouldDeployStandaloneHCA,
} from "./_helpers.js";

type DeploymentLike = { address: Address };

function resolvePaymentToken({
  getOrNull,
  tags,
}: {
  getOrNull: (name: string) => DeploymentLike | null | undefined;
  tags: Record<string, unknown>;
}) {
  return (
    optionalEnvAddress("HCA_PAYMENT_TOKEN") ??
    optionalEnvAddress("HCA_USDC") ??
    getOrNull("MockUSDC")?.address ??
    (tags.hasDao ? MAINNET_USDC : undefined) ??
    (tags.sepolia || tags.dev ? SEPOLIA_USDC : undefined)
  );
}

function resolveSecondaryPaymentToken({
  getOrNull,
  tags,
  paymentToken,
}: {
  getOrNull: (name: string) => DeploymentLike | null | undefined;
  tags: Record<string, unknown>;
  paymentToken: Address;
}) {
  return (
    optionalEnvAddress("HCA_SECONDARY_PAYMENT_TOKEN") ??
    optionalEnvAddress("HCA_DAI") ??
    getOrNull("MockDAI")?.address ??
    (tags.hasDao ? MAINNET_DAI : undefined) ??
    paymentToken
  );
}

export default execute(
  async ({ deploy, get, getOrNull, namedAccounts: { deployer }, tags }) => {
    if (!shouldDeployStandaloneHCA(tags)) return;

    const defaultReverseRegistrarAdapter =
      get<(typeof artifacts.DefaultReverseRegistrarAdapter)["abi"]>(
        "DefaultReverseRegistrarAdapter",
      );
    const permittedResolverImpl =
      get<(typeof artifacts.PermissionedResolver)["abi"]>(
        "PermissionedResolverImpl",
      );
    const ethRegistrar =
      get<(typeof artifacts.ETHRegistrar)["abi"]>("ETHRegistrar");
    const verifiableFactory =
      get<(typeof artifacts.VerifiableFactory)["abi"]>("VerifiableFactory");
    const paymentToken = resolvePaymentToken({ getOrNull, tags });
    if (!paymentToken) {
      throw new Error(
        "HCA_PAYMENT_TOKEN or HCA_USDC must be set when no payment token deployment is available",
      );
    }
    const secondaryPaymentToken = resolveSecondaryPaymentToken({
      getOrNull,
      tags,
      paymentToken,
    });

    await deploy("OwnerBoundRegistrationSessionValidator", {
      account: deployer,
      artifact: artifacts.OwnerBoundRegistrationSessionValidator,
      args: [
        defaultReverseRegistrarAdapter.address,
        permittedResolverImpl.address,
        ethRegistrar.address,
        verifiableFactory.address,
        paymentToken,
        secondaryPaymentToken,
      ],
    });
  },
  {
    tags: [
      "OwnerBoundRegistrationSessionValidator",
      "StandaloneHCA",
      "hca",
      "v2",
    ],
    dependencies: [
      "DefaultReverseRegistrarAdapter",
      "PermissionedResolverImpl",
      "ETHRegistrar",
      "VerifiableFactory",
    ],
  },
);
