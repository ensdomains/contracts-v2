import { defineConfig } from "vitest/config";

const forkTest = !!process.argv.slice(2).find((x) => x.includes("/fork/"));

export default defineConfig({
  test: {
    reporters: ["verbose"],
    testTimeout: forkTest ? 30000 : undefined,
    include: [
      forkTest ? "test/fork/**/*.test.ts" : "test/integration/**/*.test.ts",
    ],
    setupFiles: ["test/integration/vitest-setup.ts"],
  },
});
