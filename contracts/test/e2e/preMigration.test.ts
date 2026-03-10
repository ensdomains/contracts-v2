import { afterEach, describe, expect, it, setDefaultTimeout } from "bun:test";
setDefaultTimeout(30_000);

import { existsSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { setTimeout } from "node:timers/promises";
import { zeroAddress } from "viem";
import { STATUS, MAX_EXPIRY, ROLES } from "../../script/deploy-constants.js";
import { main } from "../../script/preMigration.js";
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
      await setupBaseRegistrarController(env.deployment, env.namedAccounts);
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
    const user = env.namedAccounts.user;

    const expiries: bigint[] = [];
    for (const label of labels) {
      const expiry = await registerV1Name(
        env.deployment,
        label,
        user.address,
        ONE_YEAR_SECONDS,
      );
      expiries.push(expiry);
    }

    createCSVFile(csvFilePath, labels);
    const args = buildMainArgs(env.deployment, csvFilePath);
    await main(args);

    for (let i = 0; i < labels.length; i++) {
      const state = await verifyV2State(env.deployment, labels[i]);
      expect(state.status).toBe(STATUS.RESERVED);
      expect(state.latestOwner).toBe(zeroAddress);
      expect(state.expiry).toBe(expiries[i]);
    }
  });

  it("skips expired names", async () => {
    const label = "expiredname";
    const user = env.namedAccounts.user;

    await registerV1Name(env.deployment, label, user.address, 1);
    await setTimeout(2000);

    createCSVFile(csvFilePath, [label]);
    const args = buildMainArgs(env.deployment, csvFilePath);
    await main(args);

    const state = await verifyV2State(env.deployment, label);
    expect(state.status).toBe(STATUS.AVAILABLE);
  });

  it("handles already-reserved names (same expiry)", async () => {
    const labels = ["alreadyres1", "alreadyres2"];
    const user = env.namedAccounts.user;

    for (const label of labels) {
      await registerV1Name(
        env.deployment,
        label,
        user.address,
        ONE_YEAR_SECONDS,
      );
    }

    createCSVFile(csvFilePath, labels);
    const args = buildMainArgs(env.deployment, csvFilePath);
    await main(args);

    const statesBefore = await Promise.all(
      labels.map((l) => verifyV2State(env.deployment, l)),
    );

    deleteTestCheckpoint();
    await main(args);

    for (let i = 0; i < labels.length; i++) {
      const stateAfter = await verifyV2State(env.deployment, labels[i]);
      expect(stateAfter.status).toBe(STATUS.RESERVED);
      expect(stateAfter.expiry).toBe(statesBefore[i].expiry);
    }
  });

  it("renews already-reserved names with newer expiry", async () => {
    const label = "renewtest";
    const user = env.namedAccounts.user;

    await registerV1Name(env.deployment, label, user.address, ONE_YEAR_SECONDS);

    createCSVFile(csvFilePath, [label]);
    const args = buildMainArgs(env.deployment, csvFilePath);
    await main(args);

    const stateBefore = await verifyV2State(env.deployment, label);
    expect(stateBefore.status).toBe(STATUS.RESERVED);

    await renewV1Name(env.deployment, label, ONE_YEAR_SECONDS);

    deleteTestCheckpoint();
    const args2 = buildMainArgs(env.deployment, csvFilePath);
    await main(args2);

    const stateAfter = await verifyV2State(env.deployment, label);
    expect(stateAfter.status).toBe(STATUS.RESERVED);
    expect(stateAfter.expiry).toBeGreaterThan(stateBefore.expiry);
  });

  it("dry run does not create on-chain state", async () => {
    const label = "dryruntest";
    const user = env.namedAccounts.user;

    await registerV1Name(env.deployment, label, user.address, ONE_YEAR_SECONDS);

    createCSVFile(csvFilePath, [label]);
    const args = buildMainArgs(env.deployment, csvFilePath, { dryRun: true });
    await main(args);

    const state = await verifyV2State(env.deployment, label);
    expect(state.status).toBe(STATUS.AVAILABLE);
  });

  it("limit parameter restricts processing", async () => {
    const labels = ["limitname1", "limitname2", "limitname3"];
    const user = env.namedAccounts.user;

    for (const label of labels) {
      await registerV1Name(
        env.deployment,
        label,
        user.address,
        ONE_YEAR_SECONDS,
      );
    }

    createCSVFile(csvFilePath, labels);
    const args = buildMainArgs(env.deployment, csvFilePath, { limit: 2 });
    await main(args);

    const state1 = await verifyV2State(env.deployment, labels[0]);
    const state2 = await verifyV2State(env.deployment, labels[1]);
    const state3 = await verifyV2State(env.deployment, labels[2]);

    expect(state1.status).toBe(STATUS.RESERVED);
    expect(state2.status).toBe(STATUS.RESERVED);
    expect(state3.status).toBe(STATUS.AVAILABLE);
  });

  it("skips names expiring soon with minExpiryDays", async () => {
    const label = "soonexpire";
    const user = env.namedAccounts.user;

    const fiveDays = 5 * 24 * 60 * 60;
    await registerV1Name(env.deployment, label, user.address, fiveDays);

    createCSVFile(csvFilePath, [label]);
    const args = buildMainArgs(env.deployment, csvFilePath, {
      minExpiryDays: 7,
    });
    await main(args);

    const state = await verifyV2State(env.deployment, label);
    expect(state.status).toBe(STATUS.AVAILABLE);
  });

  it("handles checkpoint resumption", async () => {
    const labels = ["checkpoint1", "checkpoint2", "checkpoint3"];
    const user = env.namedAccounts.user;

    for (const label of labels) {
      await registerV1Name(
        env.deployment,
        label,
        user.address,
        ONE_YEAR_SECONDS,
      );
    }

    createCSVFile(csvFilePath, labels);

    const args1 = buildMainArgs(env.deployment, csvFilePath, { limit: 1 });
    await main(args1);

    const state1After = await verifyV2State(env.deployment, labels[0]);
    expect(state1After.status).toBe(STATUS.RESERVED);

    const args2 = buildMainArgs(env.deployment, csvFilePath, {
      continue: true,
    });
    await main(args2);

    for (const label of labels) {
      const state = await verifyV2State(env.deployment, label);
      expect(state.status).toBe(STATUS.RESERVED);
    }
  });

  it("handles already-REGISTERED names gracefully", async () => {
    const registeredLabel = "alreadyregistered";
    const normalLabel = "normalreserve";
    const user = env.namedAccounts.user;
    const deployer = env.namedAccounts.deployer;

    await registerV1Name(
      env.deployment,
      registeredLabel,
      user.address,
      ONE_YEAR_SECONDS,
    );
    await registerV1Name(
      env.deployment,
      normalLabel,
      user.address,
      ONE_YEAR_SECONDS,
    );

    await env.deployment.contracts.ETHRegistry.write.register([
      registeredLabel,
      deployer.address,
      zeroAddress,
      zeroAddress,
      0n,
      MAX_EXPIRY,
    ]);

    const registeredState = await verifyV2State(
      env.deployment,
      registeredLabel,
    );
    expect(registeredState.status).toBe(STATUS.REGISTERED);

    createCSVFile(csvFilePath, [registeredLabel, normalLabel]);
    const args = buildMainArgs(env.deployment, csvFilePath);
    await main(args);

    const regStateAfter = await verifyV2State(env.deployment, registeredLabel);
    expect(regStateAfter.status).toBe(STATUS.REGISTERED);

    const normalState = await verifyV2State(env.deployment, normalLabel);
    expect(normalState.status).toBe(STATUS.RESERVED);
  });
});
