import { afterEach, describe, expect, it, setDefaultTimeout } from "bun:test";
setDefaultTimeout(30_000);

import { existsSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { setTimeout } from "node:timers/promises";
import { createPublicClient, http, zeroAddress } from "viem";
import { mainnet } from "viem/chains";
import { STATUS, MAX_EXPIRY, ROLES } from "../../script/deploy-constants.js";
import { main, verifyNameOnV1 } from "../../script/preMigration.js";
import {
  setupBaseRegistrarController,
  registerV1Name,
  renewV1Name,
  createCSVFile,
  buildMainArgs,
  verifyV2State,
} from "../utils/mockPreMigration.js";
import { deleteTestCheckpoint } from "../utils/preMigrationTestUtils.js";

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
    for (const file of cleanupFiles) {
      if (existsSync(file)) {
        try {
          unlinkSync(file);
        } catch {}
      }
    }
  });

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
});
