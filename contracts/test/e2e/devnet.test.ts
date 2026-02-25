import { beforeAll, describe, expect, it } from "bun:test";
import { toHex } from "viem";
import { expectVar } from "../utils/expectVar.js";

describe("Devnet", () => {
  const { env, setupEnv, resetInitialState } = process.env.TEST_GLOBALS!;

  setupEnv({ resetOnEach: true });

  it("sync", async () => {
    await env.deployment.client.mine({ blocks: 1, interval: 10 }); // advance chain
    const block0 = await env.getBlock();
    const t = await env.sync();
    const block1 = await env.getBlock();
    expect(block1.timestamp).toBeGreaterThanOrEqual(block0.timestamp);
    expectVar({ t }).toStrictEqual(block1.timestamp);
  });

  it("warp", async () => {
    const warpSec = 60;
    const block0 = await env.getBlock();
    const t = await env.sync({ warpSec }); // time warp
    const block1 = await env.getBlock();
    expect(block1.timestamp - block0.timestamp).toBeGreaterThanOrEqual(warpSec);
    expect(block1.timestamp).toBeGreaterThanOrEqual(t);
    expectVar({ t }).toBeGreaterThanOrEqual(Math.floor(Date.now() / 1000));
  });

  it("saveState", async () => {
    const gateways =
      await env.deployment.contracts.BatchGatewayProvider.read.gateways();
    await env.deployment.contracts.BatchGatewayProvider.write.setGateways(
      [[]],
      {
        account: env.namedAccounts.owner,
      },
    );
    expect(
      env.deployment.contracts.BatchGatewayProvider.read.gateways(),
    ).resolves.toStrictEqual([]);
    await resetInitialState();
    expect(
      env.deployment.contracts.BatchGatewayProvider.read.gateways(),
    ).resolves.toStrictEqual(gateways);
  });

  it(`computeVerifiableProxyAddress`, async () => {
    const account = env.namedAccounts.deployer;
    const salt = 1234n;
    const contract = await env.deployment.deployPermissionedResolver({
      account,
      salt,
    });
    const address = await env.deployment.computeVerifiableProxyAddress({
      deployer: account.address,
      salt,
    });
    expect(address).toStrictEqual(contract.address);
  });
});
