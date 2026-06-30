import { isAddress, type Address } from "viem";

export const DEFAULT_ENTRY_POINT =
  "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as const;

export function shouldDeployStandaloneHCA(tags: Record<string, unknown>) {
  return Boolean(
    tags.hca ||
      tags.local ||
      tags.dev ||
      tags.test ||
      tags["clean-testnet"],
  );
}

export function shouldDeployMockIntentExecutor(tags: Record<string, unknown>) {
  return Boolean(tags.local || tags.test);
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
