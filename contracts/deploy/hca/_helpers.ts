import { isAddress, type Address } from "viem";

import {
  MAINNET_DAI,
  MAINNET_USDC,
  RHINESTONE_INTENT_EXECUTOR,
  SEPOLIA_USDC,
} from "../../script/deploy-constants.js";

export const DEFAULT_ENTRY_POINT =
  "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as const;

type DeploymentLike = { address: Address };
type DeploymentLookup = (name: string) => DeploymentLike | null | undefined;

type HCAAddressResolutionOptions = {
  tags: Record<string, unknown>;
  env?: NodeJS.ProcessEnv;
};

function usesMockHCAInfrastructure(tags: Record<string, unknown>) {
  return Boolean(tags.local || tags.test || tags["clean-testnet"]);
}

function usesSepoliaHCAProductionDefaults(tags: Record<string, unknown>) {
  return Boolean(tags.sepolia && !usesMockHCAInfrastructure(tags));
}

export function shouldDeployStandaloneHCA(tags: Record<string, unknown>) {
  return Boolean(
    tags.hca || tags.local || tags.dev || tags.test || tags["clean-testnet"],
  );
}

export function shouldDeployMockIntentExecutor(tags: Record<string, unknown>) {
  return usesMockHCAInfrastructure(tags);
}

export function resolveHCAIntentExecutor({
  tags,
  localExecutor,
  existingExecutor,
  env = process.env,
}: HCAAddressResolutionOptions & {
  localExecutor?: Address;
  existingExecutor?: Address;
}): Address | undefined {
  return (
    optionalEnvAddress("HCA_INTENT_EXECUTOR", env.HCA_INTENT_EXECUTOR) ??
    (usesSepoliaHCAProductionDefaults(tags)
      ? RHINESTONE_INTENT_EXECUTOR
      : undefined) ??
    localExecutor ??
    existingExecutor
  );
}

export function resolveHCAPaymentToken({
  getOrNull,
  tags,
  env = process.env,
}: HCAAddressResolutionOptions & {
  getOrNull: DeploymentLookup;
}): Address | undefined {
  return (
    optionalEnvAddress("HCA_PAYMENT_TOKEN", env.HCA_PAYMENT_TOKEN) ??
    optionalEnvAddress("HCA_USDC", env.HCA_USDC) ??
    (usesSepoliaHCAProductionDefaults(tags) ? SEPOLIA_USDC : undefined) ??
    (tags.hasDao ? MAINNET_USDC : undefined) ??
    getOrNull("MockUSDC")?.address ??
    (tags.sepolia || tags.dev ? SEPOLIA_USDC : undefined)
  );
}

export function resolveHCASecondaryPaymentToken({
  getOrNull,
  tags,
  paymentToken,
  env = process.env,
}: HCAAddressResolutionOptions & {
  getOrNull: DeploymentLookup;
  paymentToken: Address;
}): Address {
  return (
    optionalEnvAddress(
      "HCA_SECONDARY_PAYMENT_TOKEN",
      env.HCA_SECONDARY_PAYMENT_TOKEN,
    ) ??
    optionalEnvAddress("HCA_DAI", env.HCA_DAI) ??
    (usesSepoliaHCAProductionDefaults(tags) ? paymentToken : undefined) ??
    (tags.hasDao ? MAINNET_DAI : undefined) ??
    getOrNull("MockDAI")?.address ??
    paymentToken
  );
}

export function optionalEnvAddress(
  name: string,
  value = process.env[name],
): Address | undefined {
  if (!value) return undefined;
  if (!isAddress(value)) {
    throw new Error(`${name} is not a valid address`);
  }
  return value as Address;
}
