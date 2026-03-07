// Global test setup
import { afterAll, beforeAll, beforeEach } from "bun:test";
import {
  type DevnetEnvironment,
  type StateSnapshot,
  setupDevnet,
} from "../../script/setup.js";

declare global {
  // Add DevnetEnvironment type to NodeJS.ProcessEnv for type safety
  namespace NodeJS {
    interface ProcessEnv {
      TEST_GLOBALS?: {
        env: DevnetEnvironment;
        resetInitialState: StateSnapshot;
        setupEnv(options: {
          resetOnEach: boolean;
          initialize?: () => Promise<unknown>;
        }): void;
      };
    }
  }
}

const t0 = Date.now();

const env = await setupDevnet({ procLog: false });

// save the initial state
const resetInitialState = await env.saveState();

console.log(new Date(), `Ready! <${Date.now() - t0}ms>`);

// the state that gets reset on each
let resetEachState: StateSnapshot | undefined = resetInitialState; // default to full reset

// the environment is shared between all tests
process.env.TEST_GLOBALS = {
  env,
  resetInitialState,
  setupEnv({ resetOnEach, initialize }) {
    beforeAll(async () => {
      if (!resetOnEach || initialize) {
        await resetInitialState();
      }
      resetEachState = resetOnEach ? resetInitialState : undefined;
      if (initialize) {
        await initialize();
        if (resetOnEach) {
          resetEachState = await env.saveState();
        }
      }
      if (!resetOnEach) {
        await env.sync();
      }
    });
  },
};

beforeEach(async () => {
  await resetEachState?.();
  if (resetEachState) {
    await env.sync();
  }
});

afterAll(async () => {
  await env.shutdown();
});
