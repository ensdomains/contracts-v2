import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { privateKeyToAccount } from "viem/accounts";

import { runPreMigrationCommand } from "../../script/migration.js";

// The BatchRegistrar owner that fork/clean-testnet runs impersonate. The env
// deployer key below does NOT control it.
const OWNER_KEY =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const ownerAccount = privateKeyToAccount(OWNER_KEY);

const DEPLOYER_KEY =
  "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba";
const deployerAccount = privateKeyToAccount(DEPLOYER_KEY);

let capturedArgs: string[] | null = null;

async function captureArgs(args: string[]) {
  capturedArgs = args;
}

function flagValue(args: string[], flag: string): string | undefined {
  const i = args.indexOf(flag);
  return i === -1 ? undefined : args[i + 1];
}

const baseOpts = {
  rpcUrl: "http://127.0.0.1:8545",
  network: "mainnet" as const,
  registry: "0x0000000000000000000000000000000000000001" as const,
  batchRegistrar: "0x0000000000000000000000000000000000000002" as const,
  v1Resolver: "0x0000000000000000000000000000000000000003" as const,
  v1BaseRegistrar: "0x0000000000000000000000000000000000000004" as const,
  csvFile: "names.csv",
};

describe("runPreMigrationCommand signer resolution", () => {
  const savedEnv = {
    PREMIGRATION_PRIVATE_KEY: process.env.PREMIGRATION_PRIVATE_KEY,
    BATCH_REGISTRAR_OWNER_KEY: process.env.BATCH_REGISTRAR_OWNER_KEY,
    DEPLOYER_KEY: process.env.DEPLOYER_KEY,
  };

  beforeEach(() => {
    capturedArgs = null;
    delete process.env.PREMIGRATION_PRIVATE_KEY;
    delete process.env.BATCH_REGISTRAR_OWNER_KEY;
    process.env.DEPLOYER_KEY = DEPLOYER_KEY;
  });

  afterEach(() => {
    for (const [key, value] of Object.entries(savedEnv)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  });

  it("drops the non-matching env fallback when an impersonated account is supplied", async () => {
    await runPreMigrationCommand(
      { ...baseOpts, account: ownerAccount.address },
      false,
      captureArgs,
    );
    expect(capturedArgs).not.toBeNull();
    expect(flagValue(capturedArgs!, "--account")).toBe(ownerAccount.address);
    expect(capturedArgs).not.toContain("--private-key");
  });

  it("keeps the env fallback when it controls the supplied account", async () => {
    await runPreMigrationCommand(
      { ...baseOpts, account: deployerAccount.address },
      false,
      captureArgs,
    );
    expect(flagValue(capturedArgs!, "--private-key")).toBe(DEPLOYER_KEY);
    expect(flagValue(capturedArgs!, "--account")).toBe(deployerAccount.address);
  });

  it("uses the env fallback when no account is supplied", async () => {
    await runPreMigrationCommand({ ...baseOpts }, false, captureArgs);
    expect(flagValue(capturedArgs!, "--private-key")).toBe(DEPLOYER_KEY);
    expect(capturedArgs).not.toContain("--account");
  });

  it("an explicit private key always wins over the impersonated account", async () => {
    await runPreMigrationCommand(
      { ...baseOpts, privateKey: OWNER_KEY, account: ownerAccount.address },
      false,
      captureArgs,
    );
    expect(flagValue(capturedArgs!, "--private-key")).toBe(OWNER_KEY);
    expect(flagValue(capturedArgs!, "--account")).toBe(ownerAccount.address);
  });
});
