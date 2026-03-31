import { afterEach, describe, expect, it, setDefaultTimeout } from "bun:test";
setDefaultTimeout(30_000);

import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setTimeout } from "node:timers/promises";
import {
  createPublicClient,
  createWalletClient,
  http,
  publicActions,
  zeroAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import { STATUS, MAX_EXPIRY } from "../../script/deploy-constants.js";
import {
  main,
  verifyNameOnV1,
  batchVerifyRegistrations,
  InvalidLabelNameError,
} from "../../script/preMigration.js";
import {
  setupBaseRegistrarController,
  registerV1Name,
  renewV1Name,
  createCSVFile,
  buildMainArgs,
  verifyV2State,
} from "../utils/mockPreMigration.js";
import {
  deleteTestCheckpoint,
  readTestCheckpoint,
} from "../utils/preMigrationTestUtils.js";

const ONE_YEAR_SECONDS = 365 * 24 * 60 * 60;

describe("PreMigration", () => {
  const { env, setupEnv } = process.env.TEST_GLOBALS!;

  const csvFilePath = join(process.cwd(), "test-premigration.csv");
  const cleanupFiles = [
    csvFilePath,
    "preMigration-checkpoint.json",
    "preMigration-errors.log",
    "preMigration.log",
  ];

  setupEnv({
    resetOnEach: true,
    async initialize() {
      await setupBaseRegistrarController(env);
    },
  });

  afterEach(() => {
    delete process.env.PREMIGRATION_PRIVATE_KEY;
    for (const file of cleanupFiles) {
      if (existsSync(file)) {
        try {
          unlinkSync(file);
        } catch {}
      }
    }
  });

  // ─── Core reservation flow ─────────────────────────────────────────

  it("reserves names from v1 on v2", async () => {
    const labels = ["testname1", "testname2", "testname3"];
    const { user } = env.namedAccounts;

    const expiries: bigint[] = [];
    for (const label of labels) {
      const expiry = await registerV1Name(
        env,
        label,
        user.address,
        ONE_YEAR_SECONDS,
      );
      expiries.push(expiry);
    }

    createCSVFile(csvFilePath, labels);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    for (let i = 0; i < labels.length; i++) {
      const state = await verifyV2State(env, labels[i]);
      expect(state.status).toBe(STATUS.RESERVED);
      expect(state.latestOwner).toBe(zeroAddress);
      expect(state.expiry).toBe(expiries[i]);
    }
  });

  it("skips expired names", async () => {
    const label = "expiredname";
    const { user } = env.namedAccounts;

    await registerV1Name(env, label, user.address, 1);
    await setTimeout(2000);

    createCSVFile(csvFilePath, [label]);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const state = await verifyV2State(env, label);
    expect(state.status).toBe(STATUS.AVAILABLE);
  });

  it("handles already-reserved names (same expiry)", async () => {
    const labels = ["alreadyres1", "alreadyres2"];
    const { user } = env.namedAccounts;

    for (const label of labels) {
      await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
    }

    createCSVFile(csvFilePath, labels);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const statesBefore = await Promise.all(
      labels.map((l) => verifyV2State(env, l)),
    );

    deleteTestCheckpoint();
    await main(args);

    for (let i = 0; i < labels.length; i++) {
      const stateAfter = await verifyV2State(env, labels[i]);
      expect(stateAfter.status).toBe(STATUS.RESERVED);
      expect(stateAfter.expiry).toBe(statesBefore[i].expiry);
    }
  });

  it("renews already-reserved names with newer expiry", async () => {
    const label = "renewtest";
    const { user } = env.namedAccounts;

    await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);

    createCSVFile(csvFilePath, [label]);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const stateBefore = await verifyV2State(env, label);
    expect(stateBefore.status).toBe(STATUS.RESERVED);

    await renewV1Name(env, label, ONE_YEAR_SECONDS);

    deleteTestCheckpoint();
    const args2 = buildMainArgs(env, csvFilePath);
    await main(args2);

    const stateAfter = await verifyV2State(env, label);
    expect(stateAfter.status).toBe(STATUS.RESERVED);
    expect(stateAfter.expiry).toBeGreaterThan(stateBefore.expiry);
  });

  it("dry run does not create on-chain state", async () => {
    const label = "dryruntest";
    const { user } = env.namedAccounts;

    await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);

    createCSVFile(csvFilePath, [label]);
    const args = buildMainArgs(env, csvFilePath, { dryRun: true });
    await main(args);

    const state = await verifyV2State(env, label);
    expect(state.status).toBe(STATUS.AVAILABLE);
  });

  it("limit parameter restricts processing", async () => {
    const labels = ["limitname1", "limitname2", "limitname3"];
    const { user } = env.namedAccounts;

    for (const label of labels) {
      await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
    }

    createCSVFile(csvFilePath, labels);
    const args = buildMainArgs(env, csvFilePath, { limit: 2 });
    await main(args);

    const state1 = await verifyV2State(env, labels[0]);
    const state2 = await verifyV2State(env, labels[1]);
    const state3 = await verifyV2State(env, labels[2]);

    expect(state1.status).toBe(STATUS.RESERVED);
    expect(state2.status).toBe(STATUS.RESERVED);
    expect(state3.status).toBe(STATUS.AVAILABLE);
  });

  it("skips names expiring soon with minExpiryDays", async () => {
    const label = "soonexpire";
    const { user } = env.namedAccounts;

    const fiveDays = 5 * 24 * 60 * 60;
    await registerV1Name(env, label, user.address, fiveDays);

    createCSVFile(csvFilePath, [label]);
    const args = buildMainArgs(env, csvFilePath, {
      minExpiryDays: 7,
    });
    await main(args);

    const state = await verifyV2State(env, label);
    expect(state.status).toBe(STATUS.AVAILABLE);
  });

  it("handles checkpoint resumption", async () => {
    const labels = ["checkpoint1", "checkpoint2", "checkpoint3"];
    const { user } = env.namedAccounts;

    for (const label of labels) {
      await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
    }

    createCSVFile(csvFilePath, labels);

    const args1 = buildMainArgs(env, csvFilePath, { limit: 1 });
    await main(args1);

    const state1After = await verifyV2State(env, labels[0]);
    expect(state1After.status).toBe(STATUS.RESERVED);

    const args2 = buildMainArgs(env, csvFilePath, {
      continue: true,
    });
    await main(args2);

    for (const label of labels) {
      const state = await verifyV2State(env, label);
      expect(state.status).toBe(STATUS.RESERVED);
    }
  });

  it("handles already-REGISTERED names gracefully", async () => {
    const registeredLabel = "alreadyregistered";
    const normalLabel = "normalreserve";
    const { user, deployer } = env.namedAccounts;

    await registerV1Name(env, registeredLabel, user.address, ONE_YEAR_SECONDS);
    await registerV1Name(env, normalLabel, user.address, ONE_YEAR_SECONDS);

    await env.v2.ETHRegistry.write.register([
      registeredLabel,
      deployer.address,
      zeroAddress,
      zeroAddress,
      0n,
      MAX_EXPIRY,
    ]);

    const registeredState = await verifyV2State(env, registeredLabel);
    expect(registeredState.status).toBe(STATUS.REGISTERED);

    createCSVFile(csvFilePath, [registeredLabel, normalLabel]);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const regStateAfter = await verifyV2State(env, registeredLabel);
    expect(regStateAfter.status).toBe(STATUS.REGISTERED);

    const normalState = await verifyV2State(env, normalLabel);
    expect(normalState.status).toBe(STATUS.RESERVED);
  });

  // ─── Private key env var support ───────────────────────────────────

  it("accepts private key from PREMIGRATION_PRIVATE_KEY env var", async () => {
    const label = "envkeytest";
    const { user } = env.namedAccounts;

    await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);

    createCSVFile(csvFilePath, [label]);
    const args = buildMainArgs(env, csvFilePath, { useEnvVarForPrivateKey: true });
    await main(args);

    const state = await verifyV2State(env, label);
    expect(state.status).toBe(STATUS.RESERVED);
  });

  it("CLI --private-key overrides env var", async () => {
    const label = "clioverride";
    const { user } = env.namedAccounts;

    await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);

    process.env.PREMIGRATION_PRIVATE_KEY = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";

    createCSVFile(csvFilePath, [label]);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const state = await verifyV2State(env, label);
    expect(state.status).toBe(STATUS.RESERVED);
  });

  it("exits with error when no private key is provided", async () => {
    const label = "nokey";
    const { user } = env.namedAccounts;

    await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);

    createCSVFile(csvFilePath, [label]);
    const args = buildMainArgs(env, csvFilePath, { omitPrivateKey: true });

    const originalExit = process.exit;
    let exitCode: number | undefined;
    process.exit = ((code?: number) => {
      exitCode = code;
      throw new Error(`process.exit(${code})`);
    }) as never;

    try {
      await main(args);
    } catch (e: any) {
      expect(e.message).toBe("process.exit(1)");
    } finally {
      process.exit = originalExit;
    }

    expect(exitCode).toBe(1);
  });

  // ─── Multicall batching ────────────────────────────────────────────

  it("correctly verifies a batch of names via multicall", async () => {
    const labels = ["multi1", "multi2", "multi3", "multi4", "multi5"];
    const { user } = env.namedAccounts;

    const expiries: bigint[] = [];
    for (const label of labels) {
      const expiry = await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
      expiries.push(expiry);
    }

    createCSVFile(csvFilePath, labels);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    for (let i = 0; i < labels.length; i++) {
      const state = await verifyV2State(env, labels[i]);
      expect(state.status).toBe(STATUS.RESERVED);
      expect(state.expiry).toBe(expiries[i]);
    }
  });

  it("handles mixed registered/expired/valid names in single multicall batch", async () => {
    const validLabel = "mixedvalid";
    const expiredLabel = "mixedexpired";
    const neverRegisteredLabel = "mixednever";
    const { user } = env.namedAccounts;

    await registerV1Name(env, validLabel, user.address, ONE_YEAR_SECONDS);

    await registerV1Name(env, expiredLabel, user.address, 1);
    await setTimeout(2000);

    createCSVFile(csvFilePath, [validLabel, expiredLabel, neverRegisteredLabel]);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const validState = await verifyV2State(env, validLabel);
    expect(validState.status).toBe(STATUS.RESERVED);

    const expiredState = await verifyV2State(env, expiredLabel);
    expect(expiredState.status).toBe(STATUS.AVAILABLE);

    const neverState = await verifyV2State(env, neverRegisteredLabel);
    expect(neverState.status).toBe(STATUS.AVAILABLE);
  });

  it("batchVerifyRegistrations returns correct v1/v2 state for each name", async () => {
    const validLabel = "bvvalid";
    const expiredLabel = "bvexpired";
    const registeredLabel = "bvregistered";
    const neverLabel = "bvnever";
    const { user, deployer } = env.namedAccounts;

    const validExpiry = await registerV1Name(env, validLabel, user.address, ONE_YEAR_SECONDS);
    await registerV1Name(env, expiredLabel, user.address, 1);
    await registerV1Name(env, registeredLabel, user.address, ONE_YEAR_SECONDS);
    await setTimeout(2000);

    await env.v2.ETHRegistry.write.register([
      registeredLabel,
      deployer.address,
      zeroAddress,
      zeroAddress,
      0n,
      MAX_EXPIRY,
    ]);

    const rpcUrl = `http://${env.hostPort}`;
    const client = createWalletClient({
      account: privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"),
      chain: mainnet,
      transport: http(rpcUrl, { retryCount: 0, timeout: 30000 }),
    }).extend(publicActions);

    const mainnetClient = createPublicClient({
      chain: mainnet,
      transport: http(rpcUrl, { retryCount: 0, timeout: 30000 }),
    });

    const registryAbi = [...env.v2.ETHRegistry.abi];
    const registrations = [
      { labelName: validLabel, lineNumber: 1 },
      { labelName: expiredLabel, lineNumber: 2 },
      { labelName: registeredLabel, lineNumber: 3 },
      { labelName: neverLabel, lineNumber: 4 },
    ];

    const results = await batchVerifyRegistrations(
      registrations,
      client,
      mainnetClient,
      env.v2.ETHRegistry.address,
      registryAbi,
      env.v1.BaseRegistrar.address,
    );

    expect(results.length).toBe(4);

    expect(results[0].v2Status).toBe(STATUS.AVAILABLE);
    expect(results[0].v1IsRegistered).toBe(true);
    expect(results[0].v1Expiry).toBe(validExpiry);

    expect(results[1].v2Status).toBe(STATUS.AVAILABLE);
    expect(results[1].v1IsRegistered).toBe(false);

    expect(results[2].v2Status).toBe(STATUS.REGISTERED);
    expect(results[2].v1IsRegistered).toBe(true);

    expect(results[3].v2Status).toBe(STATUS.AVAILABLE);
    expect(results[3].v1IsRegistered).toBe(false);
    expect(results[3].v1Expiry).toBe(0n);
  });

  // ─── Batch sizing ──────────────────────────────────────────────────

  it("processes names across multiple batches with batchSize=1", async () => {
    const labels = ["batch1a", "batch1b", "batch1c"];
    const { user } = env.namedAccounts;

    for (const label of labels) {
      await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
    }

    createCSVFile(csvFilePath, labels);
    const args = buildMainArgs(env, csvFilePath, { batchSize: 1 });
    await main(args);

    for (const label of labels) {
      const state = await verifyV2State(env, label);
      expect(state.status).toBe(STATUS.RESERVED);
    }
  });

  it("processes names across multiple batches with batchSize=2", async () => {
    const labels = ["batch2a", "batch2b", "batch2c", "batch2d", "batch2e"];
    const { user } = env.namedAccounts;

    const expiries: bigint[] = [];
    for (const label of labels) {
      const expiry = await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
      expiries.push(expiry);
    }

    createCSVFile(csvFilePath, labels);
    const args = buildMainArgs(env, csvFilePath, { batchSize: 2 });
    await main(args);

    for (let i = 0; i < labels.length; i++) {
      const state = await verifyV2State(env, labels[i]);
      expect(state.status).toBe(STATUS.RESERVED);
      expect(state.expiry).toBe(expiries[i]);
    }

    const checkpoint = readTestCheckpoint();
    expect(checkpoint).not.toBeNull();
    expect(checkpoint!.successCount).toBe(5);
    expect(checkpoint!.failureCount).toBe(0);
  });

  // ─── Gas estimation (exercises estimateAndSplitBatch path) ─────────

  it("handles a larger batch of 10 names through gas estimation", async () => {
    const labels = Array.from({ length: 10 }, (_, i) => `gasest${i}`);
    const { user } = env.namedAccounts;

    const expiries: bigint[] = [];
    for (const label of labels) {
      const expiry = await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
      expiries.push(expiry);
    }

    createCSVFile(csvFilePath, labels);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    for (let i = 0; i < labels.length; i++) {
      const state = await verifyV2State(env, labels[i]);
      expect(state.status).toBe(STATUS.RESERVED);
      expect(state.expiry).toBe(expiries[i]);
    }

    const checkpoint = readTestCheckpoint();
    expect(checkpoint!.successCount).toBe(10);
    expect(checkpoint!.failureCount).toBe(0);
  });

  it("handles batch of names with long labels (higher calldata cost)", async () => {
    const labels = [
      "a".repeat(63),
      "b".repeat(63),
      "c".repeat(63),
    ];
    const { user } = env.namedAccounts;

    const expiries: bigint[] = [];
    for (const label of labels) {
      const expiry = await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
      expiries.push(expiry);
    }

    createCSVFile(csvFilePath, labels);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    for (let i = 0; i < labels.length; i++) {
      const state = await verifyV2State(env, labels[i]);
      expect(state.status).toBe(STATUS.RESERVED);
      expect(state.expiry).toBe(expiries[i]);
    }
  });

  // ─── Checkpoint tracking ───────────────────────────────────────────

  it("checkpoint correctly tracks success, skip, and failure counts", async () => {
    const validLabel = "cptvalid";
    const expiredLabel = "cptexpired";
    const neverLabel = "cptnever";
    const { user } = env.namedAccounts;

    await registerV1Name(env, validLabel, user.address, ONE_YEAR_SECONDS);
    await registerV1Name(env, expiredLabel, user.address, 1);
    await setTimeout(2000);

    createCSVFile(csvFilePath, [validLabel, expiredLabel, neverLabel]);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const checkpoint = readTestCheckpoint();
    expect(checkpoint).not.toBeNull();
    expect(checkpoint!.successCount).toBe(1);
    expect(checkpoint!.skippedCount).toBe(2);
    expect(checkpoint!.failureCount).toBe(0);
    expect(checkpoint!.totalProcessed).toBe(3);
  });

  it("checkpoint tracks failures for already-registered names", async () => {
    const registeredLabel = "cptregfail";
    const validLabel = "cptregvalid";
    const { user, deployer } = env.namedAccounts;

    await registerV1Name(env, registeredLabel, user.address, ONE_YEAR_SECONDS);
    await registerV1Name(env, validLabel, user.address, ONE_YEAR_SECONDS);

    await env.v2.ETHRegistry.write.register([
      registeredLabel,
      deployer.address,
      zeroAddress,
      zeroAddress,
      0n,
      MAX_EXPIRY,
    ]);

    createCSVFile(csvFilePath, [registeredLabel, validLabel]);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const checkpoint = readTestCheckpoint();
    expect(checkpoint).not.toBeNull();
    expect(checkpoint!.successCount).toBe(1);
    expect(checkpoint!.failureCount).toBe(1);
  });

  it("checkpoint tracks renewed count separately", async () => {
    const label = "cptrenewal";
    const { user } = env.namedAccounts;

    await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);

    createCSVFile(csvFilePath, [label]);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const checkpointBefore = readTestCheckpoint();
    expect(checkpointBefore!.successCount).toBe(1);
    expect(checkpointBefore!.renewedCount).toBe(0);

    await renewV1Name(env, label, ONE_YEAR_SECONDS);

    deleteTestCheckpoint();
    await main(args);

    const checkpointAfter = readTestCheckpoint();
    expect(checkpointAfter!.renewedCount).toBe(1);
    expect(checkpointAfter!.successCount).toBe(0);
  });

  // ─── Invalid label handling ────────────────────────────────────────

  it("skips invalid/empty labels in CSV without failing the batch", async () => {
    const validLabel = "validlabel";
    const { user } = env.namedAccounts;

    await registerV1Name(env, validLabel, user.address, ONE_YEAR_SECONDS);

    const csvContent = [
      "node,name,labelHash,owner,parentName,parentLabelHash,labelName,registrationDate,expiryDate",
      `,,,,,,${validLabel},,`,
      ",,,,,,,,",
      `,,,,,,,,`,
    ].join("\n");
    writeFileSync(csvFilePath, csvContent);

    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const state = await verifyV2State(env, validLabel);
    expect(state.status).toBe(STATUS.RESERVED);

    const checkpoint = readTestCheckpoint();
    expect(checkpoint).not.toBeNull();
    expect(checkpoint!.successCount).toBe(1);
  });

  // ─── Edge cases ────────────────────────────────────────────────────

  it("handles empty CSV file gracefully", async () => {
    writeFileSync(csvFilePath, "node,name,labelHash,owner,parentName,parentLabelHash,labelName,registrationDate,expiryDate\n");

    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const checkpoint = readTestCheckpoint();
    expect(checkpoint).toBeNull();
  });

  it("handles single name CSV", async () => {
    const label = "singlename";
    const { user } = env.namedAccounts;

    const expiry = await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);

    createCSVFile(csvFilePath, [label]);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const state = await verifyV2State(env, label);
    expect(state.status).toBe(STATUS.RESERVED);
    expect(state.expiry).toBe(expiry);
  });

  it("processes names with limit + continue across multiple runs", async () => {
    const labels = ["lc1", "lc2", "lc3", "lc4", "lc5"];
    const { user } = env.namedAccounts;

    for (const label of labels) {
      await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
    }

    createCSVFile(csvFilePath, labels);

    const args1 = buildMainArgs(env, csvFilePath, { limit: 2 });
    await main(args1);

    let checkpoint = readTestCheckpoint();
    expect(checkpoint!.successCount).toBe(2);

    const args2 = buildMainArgs(env, csvFilePath, { continue: true, limit: 2 });
    await main(args2);

    checkpoint = readTestCheckpoint();
    expect(checkpoint!.successCount).toBe(4);

    const args3 = buildMainArgs(env, csvFilePath, { continue: true });
    await main(args3);

    checkpoint = readTestCheckpoint();
    expect(checkpoint!.successCount).toBe(5);

    for (const label of labels) {
      const state = await verifyV2State(env, label);
      expect(state.status).toBe(STATUS.RESERVED);
    }
  });

  it("dry run with batch size 1 does not create state", async () => {
    const labels = ["dryb1", "dryb2", "dryb3"];
    const { user } = env.namedAccounts;

    for (const label of labels) {
      await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
    }

    createCSVFile(csvFilePath, labels);
    const args = buildMainArgs(env, csvFilePath, { dryRun: true, batchSize: 1 });
    await main(args);

    for (const label of labels) {
      const state = await verifyV2State(env, label);
      expect(state.status).toBe(STATUS.AVAILABLE);
    }
  });

  it("mixed batch: some expired, some valid, some never registered — with small batches", async () => {
    const validLabels = ["mxs1", "mxs3", "mxs5"];
    const expiredLabels = ["mxs2", "mxs4"];
    const neverLabel = "mxs6";
    const allLabels = ["mxs1", "mxs2", "mxs3", "mxs4", "mxs5", "mxs6"];
    const { user } = env.namedAccounts;

    for (const label of validLabels) {
      await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
    }
    for (const label of expiredLabels) {
      await registerV1Name(env, label, user.address, 1);
    }
    await setTimeout(2000);

    createCSVFile(csvFilePath, allLabels);
    const args = buildMainArgs(env, csvFilePath, { batchSize: 2 });
    await main(args);

    for (const label of validLabels) {
      const state = await verifyV2State(env, label);
      expect(state.status).toBe(STATUS.RESERVED);
    }
    for (const label of [...expiredLabels, neverLabel]) {
      const state = await verifyV2State(env, label);
      expect(state.status).toBe(STATUS.AVAILABLE);
    }

    const checkpoint = readTestCheckpoint();
    expect(checkpoint!.successCount).toBe(3);
    expect(checkpoint!.skippedCount).toBe(3);
    expect(checkpoint!.failureCount).toBe(0);
  });

  it("multiple registered names in batch are all counted as failures", async () => {
    const registeredLabels = ["mreg1", "mreg2"];
    const validLabel = "mregvalid";
    const { user, deployer } = env.namedAccounts;

    for (const label of [...registeredLabels, validLabel]) {
      await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
    }

    for (const label of registeredLabels) {
      await env.v2.ETHRegistry.write.register([
        label,
        deployer.address,
        zeroAddress,
        zeroAddress,
        0n,
        MAX_EXPIRY,
      ]);
    }

    createCSVFile(csvFilePath, [...registeredLabels, validLabel]);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const checkpoint = readTestCheckpoint();
    expect(checkpoint!.successCount).toBe(1);
    expect(checkpoint!.failureCount).toBe(2);
  });

  it("re-running same batch after successful reservation uses renewal path", async () => {
    const labels = ["rerun1", "rerun2"];
    const { user } = env.namedAccounts;

    for (const label of labels) {
      await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
    }

    createCSVFile(csvFilePath, labels);
    const args = buildMainArgs(env, csvFilePath);
    await main(args);

    const checkpoint1 = readTestCheckpoint();
    expect(checkpoint1!.successCount).toBe(2);
    expect(checkpoint1!.renewedCount).toBe(0);

    deleteTestCheckpoint();
    await main(args);

    const checkpoint2 = readTestCheckpoint();
    expect(checkpoint2!.successCount).toBe(0);
    expect(checkpoint2!.renewedCount).toBe(2);

    for (const label of labels) {
      const state = await verifyV2State(env, label);
      expect(state.status).toBe(STATUS.RESERVED);
    }
  });
});

describe("PreMigration - Live Mainnet v1 Verification", () => {
  const mainnetClient = createPublicClient({
    chain: mainnet,
    transport: http("https://eth.drpc.org", { retryCount: 2, timeout: 15_000 }),
  });

  it("verifies well-known names are registered on v1 mainnet", async () => {
    const wellKnownNames = ["nick", "vitalik"];

    for (const name of wellKnownNames) {
      const result = await verifyNameOnV1(name, mainnetClient);
      expect(result.isRegistered).toBe(true);
      expect(result.expiry).toBeGreaterThan(
        BigInt(Math.floor(Date.now() / 1000)),
      );
    }
  });

  it("verifies a non-existent name returns not-registered on v1 mainnet", async () => {
    const nonExistentName =
      "thisisaverylongnamethatwillneverberegistered12345678";
    const result = await verifyNameOnV1(nonExistentName, mainnetClient);
    expect(result.isRegistered).toBe(false);
  });

  it("throws InvalidLabelNameError for empty label", async () => {
    try {
      await verifyNameOnV1("", mainnetClient);
      expect.unreachable("should have thrown");
    } catch (e) {
      expect(e).toBeInstanceOf(InvalidLabelNameError);
    }
  });

  it("throws InvalidLabelNameError for whitespace-only label", async () => {
    try {
      await verifyNameOnV1("   ", mainnetClient);
      expect.unreachable("should have thrown");
    } catch (e) {
      expect(e).toBeInstanceOf(InvalidLabelNameError);
    }
  });
});
