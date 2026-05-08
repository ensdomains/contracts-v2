import { afterAll, beforeAll, beforeEach, afterEach } from "vitest";
import { injectCoverage, recordCoverage } from "../utils/hardhat-coverage.ts";
import hre from "hardhat";
import {
  endTest,
  injectHardhatGasMetrics,
  startTest,
  writeMetrics,
} from "../utils/gasMetrics.ts";

if (process.env.COVERAGE) {
  injectCoverage();
  let save: () => Promise<void> | undefined;
  beforeAll((suite) => {
    save = recordCoverage(suite.tasks[0].name);
  });
  afterAll(() => save?.());
}

if (process.env.GAS_METRICS === "1") {
  injectHardhatGasMetrics(hre);
  beforeEach((context) => {
    startTest(context.task.name, {
      suite: "hardhat",
      phase: "hardhat-test",
    });
  });
  afterEach(() => {
    endTest();
  });
  afterAll(async () => {
    await writeMetrics(process.env.METRICS_OUTPUT ?? "metrics/hardhat.json");
  });
}
