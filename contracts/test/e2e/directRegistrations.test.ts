import { afterAll, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getAddress, namehash, zeroAddress } from "viem";

import {
  DEPLOYMENT_ROLES,
  ROLES,
  STATUS,
} from "../../script/deploy-constants.js";
import {
  registerDirectNames,
  verifyDirectNames,
} from "../../script/migrate.js";
import type { DirectRegistration } from "../../script/migrations/plumbing.js";
import { writeDeploymentNamespace } from "../utils/deploymentArtifacts.js";
import {
  registerV1Name,
  setupBaseRegistrarController,
} from "../utils/mockPreMigration.js";
import { idFromLabel } from "../utils/utils.js";

const TEST_TIMEOUT_MS = 120_000;
const NAMESPACE = "mainnet";
const ROOT_RESOURCE = 0n;
const V1_RESOLVER = getAddress("0x00000000000000000000000000000000000000f1");

describe("direct registrations", () => {
  const { env, setupEnv } = process.TEST_GLOBALS!;
  const workDir = mkdtempSync(join(tmpdir(), "direct-registrations-"));
  const deploymentsDir = join(workDir, "v2");
  const v1DeploymentsDir = join(workDir, "v1");
  // on.eth's expiry on v1, which the registration copies.
  let onV1Expiry = 0n;

  setupEnv({
    resetOnEach: true,
    async initialize() {
      await setupBaseRegistrarController(env);
      onV1Expiry = await registerV1Name(
        env,
        "on",
        env.namedAccounts.owner.address,
        365 * 24 * 60 * 60,
      );
      await env.v1.ENSRegistry.write.setResolver(
        [namehash("on.eth"), V1_RESOLVER],
        { account: env.namedAccounts.owner },
      );
      const dir = join(v1DeploymentsDir, NAMESPACE);
      mkdirSync(dir, { recursive: true });
      for (const [name, contract] of [
        ["BaseRegistrarImplementation", env.v1.BaseRegistrar],
        ["ENSRegistry", env.v1.ENSRegistry],
      ] as const) {
        writeFileSync(
          join(dir, `${name}.json`),
          JSON.stringify({ address: contract.address, abi: contract.abi }),
        );
      }
    },
  });

  afterAll(() => {
    rmSync(workDir, { recursive: true, force: true });
  });

  const deployer = () => getAddress(env.namedAccounts.deployer.address);
  const endowment = () => getAddress(env.namedAccounts.endowment.address);
  const table = (): DirectRegistration[] => [
    { label: "on", owner: endowment(), resolver: "v1", expiry: "v1" },
  ];

  function context() {
    rmSync(deploymentsDir, { recursive: true, force: true });
    writeDeploymentNamespace(
      deploymentsDir,
      NAMESPACE,
      (["RootRegistry", "ETHRegistry", "ETHRegistrar"] as const).flatMap(
        (name) => {
          const deployment = env.rocketh.deployments[name];
          return deployment ? [[name, deployment] as const] : [];
        },
      ),
    );
    return {
      network: "mainnet",
      rpcUrl: `http://${env.hostPort}`,
      chainId: "1",
      deploymentsDir,
      deploymentNetwork: NAMESPACE,
      v1DeploymentsDir,
      v1DeploymentNetwork: NAMESPACE,
      deployer: deployer(),
      impersonateAccount: deployer(),
      directRegistrations: table(),
    } as const;
  }

  // The deployer's regular .eth registry roles that let it register, which the
  // command must leave as it found them.
  const registerRoles = async () =>
    (await env.v2.ETHRegistry.read.roles([ROOT_RESOURCE, deployer()])) &
    (ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.REGISTER_RESERVED);

  // On mainnet the deployer holds only the admin bits for these roles until it
  // registers; the devnet fixture also hands it the regular registrar role.
  async function dropRegisterRoles() {
    const held = await registerRoles();
    if (held !== 0n) {
      await env.v2.ETHRegistry.write.revokeRootRoles([held, deployer()], {
        account: env.namedAccounts.deployer,
      });
    }
  }

  async function expectRegisteredToEndowment() {
    const onId = idFromLabel("on");
    expect(await env.v2.ETHRegistry.read.getOwner([onId])).toBe(endowment());
    expect(await env.v2.ETHRegistry.read.getExpiry([onId])).toBe(onV1Expiry);
    expect(await env.v2.ETHRegistry.read.getResolver(["on"])).toBe(V1_RESOLVER);
    const resource = await env.v2.ETHRegistry.read.getResource([onId]);
    expect(await env.v2.ETHRegistry.read.roles([resource, endowment()])).toBe(
      DEPLOYMENT_ROLES.DIRECT_REGISTRATION,
    );
  }

  it(
    "registers on.eth to the endowment with every role and its v1 resolver and expiry",
    async () => {
      await dropRegisterRoles();
      await registerDirectNames(context());
      await expectRegisteredToEndowment();
      expect(await registerRoles()).toBe(0n);

      // A second run finds it registered and sends nothing.
      await registerDirectNames(context());
      await verifyDirectNames(context());
    },
    TEST_TIMEOUT_MS,
  );

  it(
    "registers a reserved on.eth through the register-reserved role",
    async () => {
      const asDeployer = { account: env.namedAccounts.deployer };
      await env.v2.ETHRegistry.write.grantRootRoles(
        [ROLES.REGISTRY.REGISTRAR, deployer()],
        asDeployer,
      );
      await env.v2.ETHRegistry.write.register(
        ["on", zeroAddress, zeroAddress, zeroAddress, 0n, onV1Expiry + 1000n],
        asDeployer,
      );
      expect(await env.v2.ETHRegistry.read.getStatus([idFromLabel("on")])).toBe(
        STATUS.RESERVED,
      );
      await dropRegisterRoles();

      await registerDirectNames(context());
      await expectRegisteredToEndowment();
      expect(await registerRoles()).toBe(0n);
    },
    TEST_TIMEOUT_MS,
  );

  it(
    "refuses a name registered to anyone else",
    async () => {
      const asDeployer = { account: env.namedAccounts.deployer };
      await env.v2.ETHRegistry.write.grantRootRoles(
        [ROLES.REGISTRY.REGISTRAR, deployer()],
        asDeployer,
      );
      await env.v2.ETHRegistry.write.register(
        [
          "on",
          env.namedAccounts.user.address,
          zeroAddress,
          zeroAddress,
          0n,
          onV1Expiry,
        ],
        asDeployer,
      );

      await expect(registerDirectNames(context())).rejects.toThrow(
        /on\.eth is registered with owner/,
      );
      await expect(verifyDirectNames(context())).rejects.toThrow(
        /on\.eth is registered with owner/,
      );
    },
    TEST_TIMEOUT_MS,
  );
});
