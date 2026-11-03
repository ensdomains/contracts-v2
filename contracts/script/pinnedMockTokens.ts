import { encodeAbiParameters } from "viem";
import { Artifact_MockERC20Capped } from "generated/artifacts/MockERC20Capped.js";

import { MOCK_USDC_DEPLOY_ARGS } from "./deploy-constants.js";

// Faucet mocks whose addresses are pinned externally (Rhinestone whitelists
// Sepolia's mock USDC).
export const PINNED_MOCK_USDC = {
  name: "MockUSDC",
  artifact: Artifact_MockERC20Capped,
  args: MOCK_USDC_DEPLOY_ARGS,
} as const;

export const PINNED_MOCK_TOKENS = [PINNED_MOCK_USDC] as const;

export type PinnedMockToken = (typeof PINNED_MOCK_TOKENS)[number];

/// Strips the CBOR metadata trailer, including its length suffix, from bytecode.
export function stripMetadataTrailer(bytecode: string): string {
  const cborLength = parseInt(bytecode.slice(-4), 16);
  const trailerLength = (cborLength + 2) * 2;
  if (!Number.isFinite(cborLength) || bytecode.length < trailerLength) {
    return bytecode;
  }
  return bytecode.slice(0, -trailerLength);
}

/// Whether a record matches the token's current build and constructor args,
/// ignoring the metadata trailer.
export function isPinnedMockBuild(
  record: { bytecode?: string; argsData?: string },
  { artifact, args }: PinnedMockToken,
): boolean {
  const constructor = artifact.abi.find((item) => item.type === "constructor");
  const argsData = constructor
    ? encodeAbiParameters(constructor.inputs, args)
    : "0x";
  return (
    stripMetadataTrailer(record.bytecode?.toLowerCase() ?? "") ===
      stripMetadataTrailer(artifact.bytecode.toLowerCase()) &&
    record.argsData?.toLowerCase() === argsData.toLowerCase()
  );
}
