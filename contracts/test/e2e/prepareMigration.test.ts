import { describe, expect, it, setDefaultTimeout } from "bun:test";
setDefaultTimeout(60_000);

import type { Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { main } from "../../script/prepareMigration.js";
import { revertPrePrepareMigrationRoles } from "../utils/mockPrepareMigration.js";

const DEPLOYER_PRIVATE_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;

const ROLE_REGISTRAR = 1n << 0n;
const ROLE_REGISTRAR_ADMIN = 1n << 128n;
const ROLE_REGISTER_RESERVED = 1n << 4n;
const ROLE_REGISTER_RESERVED_ADMIN = 1n << 132n;

describe("PrepareMigration", () => {
  const { env, setupEnv } = process.env.TEST_GLOBALS!;

  setupEnv({
    resetOnEach: true,
    async initialize() {
      await revertPrePrepareMigrationRoles(env);
    },
  });

  function getAddresses() {
    return {
      rpcUrl: `http://${env.hostPort}`,
      registry: env.v2.ETHRegistry.address,
      batchRegistrar: env.rocketh.get("BatchRegistrar").address as Address,
      ethRegistrar: env.v2.ETHRegistrar.address,
      unlocked: env.v2.UnlockedMigrationController.address,
      locked: env.v2.LockedMigrationController.address,
    };
  }

  function buildArgs(
    addrs: ReturnType<typeof getAddresses>,
    overrides: { privateKey?: string | null; execute?: boolean } = {},
  ): string[] {
    const args = [
      "node",
      "prepareMigration",
      "--rpc-url",
      addrs.rpcUrl,
      "--registry",
      addrs.registry,
      "--batch-registrar",
      addrs.batchRegistrar,
      "--eth-registrar",
      addrs.ethRegistrar,
      "--unlocked-migration-controller",
      addrs.unlocked,
      "--locked-migration-controller",
      addrs.locked,
    ];
    const pk =
      overrides.privateKey === undefined
        ? DEPLOYER_PRIVATE_KEY
        : overrides.privateKey;
    if (pk !== null) args.push("--private-key", pk);
    if (overrides.execute) args.push("--execute");
    return args;
  }

  async function readRoles(account: Address): Promise<bigint> {
    return (await env.v2.ETHRegistry.read.roles([0n, account])) as bigint;
  }

  it("devnet starts in pre-prepareMigration state", async () => {
    const addrs = getAddresses();

    expect((await readRoles(addrs.batchRegistrar)) & ROLE_REGISTRAR).toBe(
      ROLE_REGISTRAR,
    );
    expect((await readRoles(addrs.ethRegistrar)) & ROLE_REGISTRAR).toBe(0n);
    expect((await readRoles(addrs.unlocked)) & ROLE_REGISTER_RESERVED).toBe(0n);
    expect((await readRoles(addrs.locked)) & ROLE_REGISTER_RESERVED).toBe(0n);
  });

  it("dry run does not mutate on-chain role state", async () => {
    const addrs = getAddresses();

    const before = {
      batch: await readRoles(addrs.batchRegistrar),
      eth: await readRoles(addrs.ethRegistrar),
      unlocked: await readRoles(addrs.unlocked),
      locked: await readRoles(addrs.locked),
    };

    await main(buildArgs(addrs));

    expect(await readRoles(addrs.batchRegistrar)).toBe(before.batch);
    expect(await readRoles(addrs.ethRegistrar)).toBe(before.eth);
    expect(await readRoles(addrs.unlocked)).toBe(before.unlocked);
    expect(await readRoles(addrs.locked)).toBe(before.locked);
  });

  it("execute revokes BatchRegistrar registrar roles and grants controller roles", async () => {
    const addrs = getAddresses();

    const batchBefore = await readRoles(addrs.batchRegistrar);
    expect(batchBefore & ROLE_REGISTRAR).toBe(ROLE_REGISTRAR);

    await main(buildArgs(addrs, { execute: true }));

    const batchAfter = await readRoles(addrs.batchRegistrar);
    expect(batchAfter & ROLE_REGISTRAR).toBe(0n);
    expect(batchAfter & ROLE_REGISTRAR_ADMIN).toBe(0n);
    expect(batchAfter & ROLE_REGISTER_RESERVED).toBe(0n);
    expect(batchAfter & ROLE_REGISTER_RESERVED_ADMIN).toBe(0n);

    expect((await readRoles(addrs.ethRegistrar)) & ROLE_REGISTRAR).toBe(
      ROLE_REGISTRAR,
    );
    expect((await readRoles(addrs.unlocked)) & ROLE_REGISTER_RESERVED).toBe(
      ROLE_REGISTER_RESERVED,
    );
    expect((await readRoles(addrs.locked)) & ROLE_REGISTER_RESERVED).toBe(
      ROLE_REGISTER_RESERVED,
    );
  });

  it("execute preserves unrelated roles on BatchRegistrar", async () => {
    const addrs = getAddresses();
    const batchBefore = await readRoles(addrs.batchRegistrar);
    const ROLE_RENEW = 1n << 16n;
    expect(batchBefore & ROLE_RENEW).toBe(ROLE_RENEW);

    await main(buildArgs(addrs, { execute: true }));

    const batchAfter = await readRoles(addrs.batchRegistrar);
    expect(batchAfter & ROLE_RENEW).toBe(ROLE_RENEW);
  });

  it("is idempotent on repeated execute", async () => {
    const addrs = getAddresses();

    await main(buildArgs(addrs, { execute: true }));
    const snapshot = {
      batch: await readRoles(addrs.batchRegistrar),
      eth: await readRoles(addrs.ethRegistrar),
      unlocked: await readRoles(addrs.unlocked),
      locked: await readRoles(addrs.locked),
    };

    await main(buildArgs(addrs, { execute: true }));

    expect(await readRoles(addrs.batchRegistrar)).toBe(snapshot.batch);
    expect(await readRoles(addrs.ethRegistrar)).toBe(snapshot.eth);
    expect(await readRoles(addrs.unlocked)).toBe(snapshot.unlocked);
    expect(await readRoles(addrs.locked)).toBe(snapshot.locked);
  });

  it("aborts when signer lacks required admin roles", async () => {
    const addrs = getAddresses();
    // user account is funded but has no root admin roles on ETHRegistry
    const userPk =
      "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as const;
    const userAddr = privateKeyToAccount(userPk).address;
    expect(await readRoles(userAddr)).toBe(0n);

    await expect(
      main(buildArgs(addrs, { privateKey: userPk, execute: true })),
    ).rejects.toThrow(/admin roles/);

    // state untouched
    expect(
      (await readRoles(addrs.batchRegistrar)) & ROLE_REGISTRAR,
    ).toBe(ROLE_REGISTRAR);
  });

  it("rejects --execute without --private-key", async () => {
    const addrs = getAddresses();
    await expect(
      main(buildArgs(addrs, { privateKey: null, execute: true })),
    ).rejects.toThrow(/--execute requires --private-key/);
  });
});
