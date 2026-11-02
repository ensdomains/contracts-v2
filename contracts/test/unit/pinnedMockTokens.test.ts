import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { encodeAbiParameters } from "viem";
import { mainnet, sepolia } from "viem/chains";

import { Artifact_MockERC20Capped } from "generated/artifacts/MockERC20Capped.js";
import { Artifact_MockERC20 } from "generated/artifacts/test/mocks/MockERC20.sol/MockERC20.js";

import {
  MOCK_USDC_DECIMALS,
  MOCK_USDC_DEPLOY_ARGS,
  MOCK_USDC_SYMBOL,
} from "../../script/deploy-constants.js";
import {
  archiveExistingDeploymentNamespace,
  carryPinnedMockTokens,
} from "../../script/migrate.js";
import {
  isPinnedMockBuild,
  PINNED_MOCK_USDC,
} from "../../script/pinnedMockTokens.js";

const ENVIRONMENT = "sepolia";
const ARCHIVE = `${ENVIRONMENT}-20260101-r1`;
const ADDRESS = "0x0000000000000000000000000000000000000001";
const NEWER_ADDRESS = "0x0000000000000000000000000000000000000002";
const BUILD_INFO_ID = "mock-usdc-build-info";
const SEPOLIA_CHAIN = JSON.stringify({ chainId: String(sepolia.id) });

const constructor = Artifact_MockERC20Capped.abi.find(
  (item) => item.type === "constructor",
);
const ARGS_DATA = constructor
  ? encodeAbiParameters(constructor.inputs, MOCK_USDC_DEPLOY_ARGS)
  : "0x";

const uncappedConstructor = Artifact_MockERC20.abi.find(
  (item) => item.type === "constructor",
);
const UNCAPPED_ARGS_DATA = uncappedConstructor
  ? encodeAbiParameters(uncappedConstructor.inputs, [
      MOCK_USDC_SYMBOL,
      MOCK_USDC_DECIMALS,
    ])
  : "0x";

/// A record of the uncapped mock that earlier deploys used for USDC.
function uncappedRecord() {
  return JSON.stringify({
    abi: Artifact_MockERC20.abi,
    address: ADDRESS,
    bytecode: Artifact_MockERC20.bytecode,
    argsData: UNCAPPED_ARGS_DATA,
    buildInfoId: BUILD_INFO_ID,
  });
}

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

/// Rewrites the metadata trailer of a build, leaving the executable code alone.
function withMetadataTrailer(bytecode: string, payloadBytes: number): string {
  const cborLength = parseInt(bytecode.slice(-4), 16);
  const code = bytecode.slice(0, -(cborLength * 2 + 4));
  const payload = "ab".repeat(payloadBytes);
  const suffix = payloadBytes.toString(16).padStart(4, "0");
  return `${code}${payload}${suffix}`;
}

describe("carryPinnedMockTokens", () => {
  let root: string;
  let target: string;

  /// Writes a namespace folder holding the given files.
  function namespace(name: string, files: Record<string, string>) {
    const dir = join(root, name);
    mkdirSync(dir, { recursive: true });
    for (const [file, contents] of Object.entries(files)) {
      mkdirSync(join(dir, file, ".."), { recursive: true });
      writeFileSync(join(dir, file), contents);
    }
  }

  function carry() {
    return carryPinnedMockTokens(root, ENVIRONMENT, sepolia.id);
  }

  function carriedAddress() {
    return JSON.parse(readFileSync(join(target, "MockUSDC.json"), "utf-8"))
      .address;
  }

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "pinned-mock-tokens-"));
    target = join(root, ENVIRONMENT);
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it("copies the record, chain metadata and build info from a dated archive", () => {
    const contents = record();
    namespace(ARCHIVE, {
      "MockUSDC.json": contents,
      ".chain": SEPOLIA_CHAIN,
      [`build-info/${BUILD_INFO_ID}.json`]: "{}",
    });

    expect(carry()).toEqual(["MockUSDC"]);
    expect(readFileSync(join(target, "MockUSDC.json"), "utf-8")).toBe(contents);
    expect(readFileSync(join(target, ".chain"), "utf-8")).toBe(SEPOLIA_CHAIN);
    expect(
      existsSync(join(target, "build-info", `${BUILD_INFO_ID}.json`)),
    ).toBe(true);
  });

  it("writes chain metadata when the archive has none", () => {
    namespace(ARCHIVE, { "MockUSDC.json": record() });

    carry();

    expect(JSON.parse(readFileSync(join(target, ".chain"), "utf-8"))).toEqual({
      chainId: String(sepolia.id),
    });
  });

  it("copies from the newest dated archive", () => {
    namespace(ARCHIVE, { "MockUSDC.json": record() });
    namespace(`${ENVIRONMENT}-20260201-r2`, {
      "MockUSDC.json": record(),
    });
    namespace(`${ENVIRONMENT}-20260201-r10`, {
      "MockUSDC.json": record({ address: NEWER_ADDRESS }),
    });

    carry();

    expect(carriedAddress()).toBe(NEWER_ADDRESS);
  });

  it("falls back to an older archive when the newest has no record", () => {
    namespace(ARCHIVE, { "MockUSDC.json": record() });
    namespace(`${ENVIRONMENT}-20260201-r1`, { "Other.json": "{}" });

    carry();

    expect(carriedAddress()).toBe(ADDRESS);
  });

  it("copies a record that no longer matches the build, for the deploy step to replace", () => {
    namespace(ARCHIVE, { "MockUSDC.json": uncappedRecord() });

    expect(carry()).toEqual(["MockUSDC"]);
  });

  it("leaves a namespace that already holds a record alone", () => {
    namespace(ARCHIVE, { "MockUSDC.json": record() });
    namespace(ENVIRONMENT, {
      "MockUSDC.json": record({ address: NEWER_ADDRESS }),
    });

    expect(carry()).toEqual([]);
    expect(carriedAddress()).toBe(NEWER_ADDRESS);
  });

  it("ignores folders that are not dated archives, such as fork runs", () => {
    namespace(`${ENVIRONMENT}-fork`, {
      "MockUSDC.json": record(),
      ".chain": SEPOLIA_CHAIN,
    });

    expect(carry()).toEqual([]);
    expect(existsSync(target)).toBe(false);
  });

  it("ignores archives recorded on another chain", () => {
    namespace(ARCHIVE, {
      "MockUSDC.json": record(),
      ".chain": JSON.stringify({ chainId: String(mainnet.id) }),
    });

    expect(carry()).toEqual([]);
  });

  it("ignores a record without an address", () => {
    namespace(ARCHIVE, { "MockUSDC.json": record({ address: undefined }) });

    expect(carry()).toEqual([]);
    expect(existsSync(target)).toBe(false);
  });

  it("does nothing without an archive", () => {
    expect(carry()).toEqual([]);
    expect(existsSync(target)).toBe(false);
  });
});

describe("archiveExistingDeploymentNamespace", () => {
  let root: string;
  let target: string;

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "archive-namespace-"));
    target = join(root, ENVIRONMENT);
    mkdirSync(join(target, "build-info"), { recursive: true });
    writeFileSync(join(target, "MockUSDC.json"), record());
    writeFileSync(join(target, ".chain"), SEPOLIA_CHAIN);
    writeFileSync(join(target, "build-info", `${BUILD_INFO_ID}.json`), "{}");
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it("keeps a namespace that holds only carried-over pinned mocks", () => {
    archiveExistingDeploymentNamespace(root, ENVIRONMENT);

    expect(readdirSync(root)).toEqual([ENVIRONMENT]);
  });

  it("archives a namespace that holds other records", () => {
    writeFileSync(join(target, "MockDAI.json"), "{}");

    archiveExistingDeploymentNamespace(root, ENVIRONMENT);

    const entries = readdirSync(root);
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatch(/^sepolia-\d{8}-r1$/);
  });
});

describe("isPinnedMockBuild", () => {
  it("matches the capped build", () => {
    expect(isPinnedMockBuild(JSON.parse(record()), PINNED_MOCK_USDC)).toBe(
      true,
    );
  });

  it("matches the capped build with a different metadata trailer", () => {
    const bytecode = withMetadataTrailer(
      Artifact_MockERC20Capped.bytecode,
      parseInt(Artifact_MockERC20Capped.bytecode.slice(-4), 16),
    );
    expect(
      isPinnedMockBuild(JSON.parse(record({ bytecode })), PINNED_MOCK_USDC),
    ).toBe(true);
  });

  it("matches the capped build with a different metadata trailer length", () => {
    const bytecode = withMetadataTrailer(
      Artifact_MockERC20Capped.bytecode,
      parseInt(Artifact_MockERC20Capped.bytecode.slice(-4), 16) + 2,
    );
    expect(
      isPinnedMockBuild(JSON.parse(record({ bytecode })), PINNED_MOCK_USDC),
    ).toBe(true);
  });

  it("rejects a changed build", () => {
    expect(
      isPinnedMockBuild(
        JSON.parse(record({ bytecode: "0xdeadbeef" })),
        PINNED_MOCK_USDC,
      ),
    ).toBe(false);
  });

  it("rejects the uncapped mock", () => {
    expect(
      isPinnedMockBuild(JSON.parse(uncappedRecord()), PINNED_MOCK_USDC),
    ).toBe(false);
  });

  it("rejects the capped build with different constructor arguments", () => {
    expect(
      isPinnedMockBuild(
        JSON.parse(record({ argsData: "0x1234" })),
        PINNED_MOCK_USDC,
      ),
    ).toBe(false);
  });
});
