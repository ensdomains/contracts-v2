import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { encodeAbiParameters } from "viem";
import { sepolia } from "viem/chains";

import { Artifact_MockERC20Capped } from "generated/artifacts/MockERC20Capped.js";

import { MOCK_USDC_DEPLOY_ARGS } from "../../script/deploy-constants.js";
import { reusePinnedMockTokens } from "../../script/migrate.js";

const ENVIRONMENT = "sepolia";
const ARCHIVE = `${ENVIRONMENT}-20260101-r1`;
const ADDRESS = "0x0000000000000000000000000000000000000001";
const BUILD_INFO_ID = "mock-usdc-build-info";

const constructor = Artifact_MockERC20Capped.abi.find(
  (item) => item.type === "constructor",
);
const ARGS_DATA = constructor
  ? encodeAbiParameters(constructor.inputs, MOCK_USDC_DEPLOY_ARGS)
  : "0x";

function record(overrides: Record<string, unknown> = {}) {
  return JSON.stringify({
    abi: Artifact_MockERC20Capped.abi,
    address: ADDRESS,
    bytecode: Artifact_MockERC20Capped.bytecode,
    argsData: ARGS_DATA,
    buildInfoId: BUILD_INFO_ID,
    ...overrides,
  });
}

/// Replaces the metadata payload of a build, keeping its trailer length intact.
function withDifferentMetadata(bytecode: string): string {
  const cborLength = parseInt(bytecode.slice(-4), 16);
  const metadataStart = bytecode.length - cborLength * 2;
  const flipped = bytecode[metadataStart] === "0" ? "1" : "0";
  return `${bytecode.slice(0, metadataStart)}${flipped}${bytecode.slice(metadataStart + 1)}`;
}

describe("reusePinnedMockTokens", () => {
  let root: string;
  let archived: string;
  let target: string;

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "pinned-mock-tokens-"));
    archived = join(root, ARCHIVE);
    target = join(root, ENVIRONMENT);
    mkdirSync(archived, { recursive: true });
    mkdirSync(join(archived, "build-info"), { recursive: true });
    writeFileSync(
      join(archived, "build-info", `${BUILD_INFO_ID}.json`),
      JSON.stringify({ id: BUILD_INFO_ID }),
    );
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it("carries a matching mock into the replacing namespace", () => {
    const contents = record();
    writeFileSync(join(archived, "MockUSDC.json"), contents);
    writeFileSync(
      join(archived, ".chain"),
      JSON.stringify({ chainId: String(sepolia.id) }),
    );

    const reused = reusePinnedMockTokens(
      root,
      ENVIRONMENT,
      ARCHIVE,
      sepolia.id,
    );

    expect(reused).toEqual(["MockUSDC"]);
    expect(readFileSync(join(target, "MockUSDC.json"), "utf-8")).toBe(contents);
    expect(readFileSync(join(target, ".chain"), "utf-8")).toBe(
      JSON.stringify({ chainId: String(sepolia.id) }),
    );
    expect(
      existsSync(join(target, "build-info", `${BUILD_INFO_ID}.json`)),
    ).toBe(true);
  });

  it("keeps a build whose metadata only differs", () => {
    writeFileSync(
      join(archived, "MockUSDC.json"),
      record({
        bytecode: withDifferentMetadata(Artifact_MockERC20Capped.bytecode),
      }),
    );

    const reused = reusePinnedMockTokens(
      root,
      ENVIRONMENT,
      ARCHIVE,
      sepolia.id,
    );

    expect(reused).toEqual(["MockUSDC"]);
  });

  it("writes chain metadata when the archived namespace has none", () => {
    writeFileSync(join(archived, "MockUSDC.json"), record());

    reusePinnedMockTokens(root, ENVIRONMENT, ARCHIVE, sepolia.id);

    expect(JSON.parse(readFileSync(join(target, ".chain"), "utf-8"))).toEqual({
      chainId: String(sepolia.id),
    });
  });

  it("leaves a changed build to be redeployed", () => {
    writeFileSync(
      join(archived, "MockUSDC.json"),
      record({ bytecode: "0xdeadbeef" }),
    );

    const reused = reusePinnedMockTokens(
      root,
      ENVIRONMENT,
      ARCHIVE,
      sepolia.id,
    );

    expect(reused).toEqual([]);
    expect(existsSync(join(target, "MockUSDC.json"))).toBe(false);
  });

  it("leaves a mock with different constructor arguments to be redeployed", () => {
    writeFileSync(
      join(archived, "MockUSDC.json"),
      record({ argsData: "0x1234" }),
    );

    const reused = reusePinnedMockTokens(
      root,
      ENVIRONMENT,
      ARCHIVE,
      sepolia.id,
    );

    expect(reused).toEqual([]);
    expect(existsSync(join(target, "MockUSDC.json"))).toBe(false);
  });

  it("ignores a record without an address", () => {
    writeFileSync(
      join(archived, "MockUSDC.json"),
      record({ address: undefined }),
    );

    const reused = reusePinnedMockTokens(
      root,
      ENVIRONMENT,
      ARCHIVE,
      sepolia.id,
    );

    expect(reused).toEqual([]);
    expect(existsSync(join(target, "MockUSDC.json"))).toBe(false);
  });

  it("ignores a missing record", () => {
    const reused = reusePinnedMockTokens(
      root,
      ENVIRONMENT,
      ARCHIVE,
      sepolia.id,
    );

    expect(reused).toEqual([]);
    expect(existsSync(target)).toBe(false);
  });
});
