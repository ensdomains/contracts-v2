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

function resolveUsdc({
  getOrNull,
  tags,
}: {
  getOrNull: (name: string) => DeploymentLike | null | undefined;
  tags: Record<string, unknown>;
}) {
  return (
    optionalEnvAddress("HCA_USDC") ??
    getOrNull("MockUSDC")?.address ??
    (tags.hasDao ? MAINNET_USDC : undefined) ??
    (tags.sepolia || tags.dev ? SEPOLIA_USDC : undefined)
  );
}

function resolveDai({
  getOrNull,
  tags,
  usdc,
}: {
  getOrNull: (name: string) => DeploymentLike | null | undefined;
  tags: Record<string, unknown>;
  usdc: Address;
}) {
  return (
    optionalEnvAddress("HCA_DAI") ??
    getOrNull("MockDAI")?.address ??
    (tags.hasDao ? MAINNET_DAI : undefined) ??
    usdc
  );
}

export default execute(
  async ({ deploy, get, getOrNull, namedAccounts: { deployer }, tags }) => {
    if (!shouldDeployStandaloneHCA(tags)) return;

    const reverseRegistrarAdapter =
      get<(typeof artifacts.ReverseRegistrarAdapter)["abi"]>(
        "ReverseRegistrarAdapter",
      );
    const permittedResolverImpl =
      get<(typeof artifacts.PermissionedResolver)["abi"]>(
        "PermissionedResolverImpl",
      );
    const ethRegistrar =
      get<(typeof artifacts.ETHRegistrar)["abi"]>("ETHRegistrar");
    const verifiableFactory =
      get<(typeof artifacts.VerifiableFactory)["abi"]>("VerifiableFactory");
    const usdc = resolveUsdc({ getOrNull, tags });
    if (!usdc) {
      throw new Error("HCA_USDC must be set when MockUSDC is not deployed");
    }
    const dai = resolveDai({ getOrNull, tags, usdc });

    await deploy("OwnerBoundRegistrationSessionValidator", {
      account: deployer,
      artifact: artifacts.OwnerBoundRegistrationSessionValidator,
      args: [
        reverseRegistrarAdapter.address,
        permittedResolverImpl.address,
        ethRegistrar.address,
        verifiableFactory.address,
        usdc,
        dai,
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
      "ReverseRegistrarAdapter",
      "PermissionedResolverImpl",
      "ETHRegistrar",
      "VerifiableFactory",
    ],
  },
);
