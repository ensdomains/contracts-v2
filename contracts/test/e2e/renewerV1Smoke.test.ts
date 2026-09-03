import { describe, expect, it, setDefaultTimeout } from "bun:test";
setDefaultTimeout(120_000);

import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  encodeAbiParameters,
  getAddress,
  keccak256,
  namehash,
  toHex,
  zeroAddress,
  type Address,
} from "viem";
import { mnemonicToAccount } from "viem/accounts";

import { renewViaEthRenewerV1 } from "../../script/migration.js";
import { main as preMigrationMain } from "../../script/preMigration.js";
import {
  buildMainArgs,
  createCSVFile,
  registerV1Name,
  setupBaseRegistrarController,
} from "../utils/mockPreMigration.js";

const ONE_YEAR_SECONDS = 365 * 24 * 60 * 60;
const TEST_MNEMONIC =
  "test test test test test test test test test test test junk";

function testPrivateKeyFor(address: Address): `0x${string}` {
  for (let index = 0; index < 10; index++) {
    const account = mnemonicToAccount(TEST_MNEMONIC, { addressIndex: index });
    if (getAddress(account.address) === getAddress(address)) {
      return toHex(account.getHdKey().privateKey!);
    }
  }
  throw new Error(`no test key for ${address}`);
}

describe("ETHRenewerV1 renewal smoke", () => {
  const { env, setupEnv } = process.TEST_GLOBALS!;

  setupEnv({
    resetOnEach: true,
    async initialize() {
      await setupBaseRegistrarController(env);
    },
  });

  // Registers a name on v1 and reserves it on v2 through the real pre-migration
  // path, which is the state an unmigrated name is in during the migration window.
  async function reservedName(label: string) {
    const { user } = env.namedAccounts;
    const workDir = mkdtempSync(join(tmpdir(), "renewer-"));
    const csvFile = join(workDir, "registrations.csv");
    await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);
    createCSVFile(csvFile, [label]);
    await preMigrationMain(buildMainArgs(env, csvFile));
  }

  function renew(label: string) {
    const payer = env.namedAccounts.deployer;
    return renewViaEthRenewerV1({
      rpcUrl: `http://${env.hostPort}`,
      chain: env.client.chain,
      label,
      privateKey: testPrivateKeyFor(payer.address),
      ethRenewerV1: env.rocketh.get("ETHRenewerV1"),
      ethRegistry: env.rocketh.get("ETHRegistry"),
      v1BaseRegistrar: {
        address: env.v1.BaseRegistrar.address,
        abi: env.v1.BaseRegistrar.abi,
      },
      nameWrapper: {
        address: env.v1.NameWrapper.address,
        abi: env.v1.NameWrapper.abi,
      },
      mockUsdc: env.rocketh.get("MockUSDC"),
      duration: BigInt(ONE_YEAR_SECONDS),
    });
  }

  // Authorizes ETHRenewerV1 as a v1 controller — the state phase 4 leaves behind.
  async function authorizeRenewerAsController() {
    await env.v1.RegistrarSecurityController.write.addRegistrarController(
      [env.rocketh.get("ETHRenewerV1").address],
      { account: env.namedAccounts.owner },
    );
  }

  // Hands the v1 BaseRegistrar to ETHRenewerV1 — the state phase 6 leaves behind.
  async function transferRegistrarToRenewer() {
    await env.v1.RegistrarSecurityController.write.transferRegistrarOwnership(
      [env.rocketh.get("ETHRenewerV1").address],
      { account: env.namedAccounts.owner },
    );
  }

  it("cannot renew while ETHRenewerV1 is only a controller, as it is between phases 4 and 6", async () => {
    const label = "renewlater";
    await reservedName(label);
    await authorizeRenewerAsController();

    // Phase 4 authorizes ETHRenewerV1 as a controller and the docs describe that
    // as keeping unmigrated names renewable. It is not sufficient on its own:
    // `renew()` calls `syncWrapper()`, which calls the owner-gated `addController`
    // on the v1 BaseRegistrar. Until phase 6 transfers ownership, a renewal
    // through ETHRenewerV1 reverts.
    await expect(renew(label)).rejects.toThrow();
  }, 120_000);

  it("extends v1 and v2 together once ETHRenewerV1 owns the registrar", async () => {
    const label = "renewme";
    await reservedName(label);
    await authorizeRenewerAsController();
    await transferRegistrarToRenewer();

    // Asserts the whole invariant internally: reaching here means the v1
    // registration and the v2 reservation both advanced by the same duration and
    // the entry stayed RESERVED.
    await renew(label);
  }, 120_000);

  it("syncs the NameWrapper expiry when the name is wrapped", async () => {
    const label = "wrappedrenew";
    const { user } = env.namedAccounts;
    const workDir = mkdtempSync(join(tmpdir(), "renewer-wrapped-"));
    const csvFile = join(workDir, "registrations.csv");
    // The registrar keys tokens by labelhash; NameWrapper keys them by namehash.
    const registrarTokenId = BigInt(keccak256(toHex(label)));
    const wrapperTokenId = BigInt(namehash(`${label}.eth`));

    await registerV1Name(env, label, user.address, ONE_YEAR_SECONDS);

    // Wrap it, so the NameWrapper holds its own copy of the expiry — the third
    // place a renewal has to keep in step, and the branch an unwrapped name
    // never reaches.
    await env.v1.BaseRegistrar.write.safeTransferFrom(
      [
        user.address,
        env.v1.NameWrapper.address,
        registrarTokenId,
        encodeAbiParameters(
          [
            { name: "label", type: "string" },
            { name: "owner", type: "address" },
            { name: "fuses", type: "uint16" },
            { name: "resolver", type: "address" },
          ],
          [label, user.address, 0, zeroAddress],
        ),
      ],
      { account: user },
    );

    createCSVFile(csvFile, [label]);
    await preMigrationMain(buildMainArgs(env, csvFile));
    await authorizeRenewerAsController();
    await transferRegistrarToRenewer();

    const wrapperExpiryBefore = (
      await env.v1.NameWrapper.read.getData([wrapperTokenId])
    )[2];
    expect(wrapperExpiryBefore).toBeGreaterThan(0n);

    await renew(label);

    const wrapperExpiryAfter = (
      await env.v1.NameWrapper.read.getData([wrapperTokenId])
    )[2];
    expect(wrapperExpiryAfter).toBeGreaterThan(wrapperExpiryBefore);
  }, 120_000);
});
