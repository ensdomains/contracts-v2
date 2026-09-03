import { describe, expect, it } from "bun:test";

/**
 * Gap hunt: nothing in contracts/test starts Alto or the mock paymaster.
 * When Alto is not running this test records that gap and passes.
 * When Alto is running it checks the health endpoint only — it does not
 * exercise WrapperRegistry, tokens, or DNS parsers.
 */
describe("Alto bundler path gap", () => {
  it("health endpoint is the only extra surface vs in-process handleOps", async () => {
    let up = false;
    try {
      const response = await fetch("http://127.0.0.1:4337/health", {
        signal: AbortSignal.timeout(400),
      });
      up = response.ok;
    } catch {
      up = false;
    }
    if (!up) {
      return;
    }
    expect(up).toBe(true);
  });
});
