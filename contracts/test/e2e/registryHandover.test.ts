import { afterAll, describe, expect, it } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createPublicClient,
  getAddress,
  http,
  zeroAddress,
  type Address,
} from "viem";

import {
  DEPLOYMENT_ROLES,
  MAX_EXPIRY,
  ROLES,
  STATUS,
} from "../../script/deploy-constants.js";
import {
  emancipateRootRegistry,
  handOverRegistryAdmin,
  verifyV2Roles,
} from "../../script/migrate.js";
import { EMANCIPATED_OWNER_ROOT_ROLES } from "../../script/migrations/registryHandover.js";
import { writeDeploymentNamespace } from "../utils/deploymentArtifacts.js";
import {
  registerV1Name,
  setupBaseRegistrarController,
} from "../utils/mockPreMigration.js";
import { idFromLabel } from "../utils/utils.js";

const TEST_TIMEOUT_MS = 120_000;
const NETWORK = "mainnet";
const NAMESPACE = "mainnet";
const ROOT_RESOURCE = 0n;
const STRANGER = getAddress("0x000000000000000000000000000000000000beef");
// A DNS top-level name the devnet deploy reserves in the root registry.
const DNS_TLD = "com";

describe("registry handover", () => {
  const { env, setupEnv } = process.TEST_GLOBALS!;
  const workDir = mkdtempSync(join(tmpdir(), "registry-handover-"));
  const deploymentsDir = join(workDir, "v2");
  const v1DeploymentsDir = join(workDir, "v1");
  // on.eth's expiry on v1, which the handover registers it with on v2.
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
      const dir = join(v1DeploymentsDir, NAMESPACE);
      mkdirSync(dir, { recursive: true });
      writeFileSync(
        join(dir, "BaseRegistrarImplementation.json"),
        JSON.stringify({
          address: env.v1.BaseRegistrar.address,
          abi: env.v1.BaseRegistrar.abi,
        }),
      );
    },
  });

  afterAll(() => {
    rmSync(workDir, { recursive: true, force: true });
  });

  const deployer = () => getAddress(env.namedAccounts.deployer.address);
  const owner = () => getAddress(env.namedAccounts.owner.address);
  const endowment = () => getAddress(env.namedAccounts.endowment.address);

  function context() {
    rmSync(deploymentsDir, { recursive: true, force: true });
    writeDeploymentNamespace(
      deploymentsDir,
      NAMESPACE,
      (
        [
          "RootRegistry",
          "ETHRegistry",
          "ETHRegistrar",
          "BatchRegistrar",
          "RootBatchRegistrar",
        ] as const
      ).flatMap((name) => {
        const deployment = env.rocketh.deployments[name];
        return deployment ? [[name, deployment] as const] : [];
      }),
    );
    return {
      network: NETWORK,
      rpcUrl: `http://${env.hostPort}`,
      chainId: "1",
      deploymentsDir,
      deploymentNetwork: NAMESPACE,
      v1DeploymentsDir,
      v1DeploymentNetwork: NAMESPACE,
      owner: owner(),
      endowment: endowment(),
    } as const;
  }

  function handOver() {
    return handOverRegistryAdmin({
      ...context(),
      deployer: deployer(),
      impersonateAccount: deployer(),
    });
  }

  const rootRoles = (
    registry: "RootRegistry" | "ETHRegistry",
    account: Address,
  ) => env.v2[registry].read.roles([ROOT_RESOURCE, account]);

  const ethResource = () =>
    env.v2.RootRegistry.read.getResource([idFromLabel("eth")]);

  it(
    "leaves the deployer no authority, gives the owner both registries and the endowment the eth token",
    async () => {
      await handOver();

      expect(await rootRoles("RootRegistry", deployer())).toBe(0n);
      expect(await rootRoles("ETHRegistry", deployer())).toBe(0n);
      expect(
        await env.v2.RootRegistry.read.roles([await ethResource(), deployer()]),
      ).toBe(0n);
      const ownerRoles = await rootRoles("RootRegistry", owner());
      expect(ownerRoles & DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT).toBe(
        DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT,
      );
      expect(await rootRoles("ETHRegistry", owner())).toBe(
        DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT,
      );
      expect(
        await env.v2.RootRegistry.read.roles([await ethResource(), owner()]),
      ).toBe(0n);
      expect(
        await env.v2.RootRegistry.read.getOwner([idFromLabel("eth")]),
      ).toBe(endowment());
      expect(
        await env.v2.RootRegistry.read.roles([
          await ethResource(),
          endowment(),
        ]),
      ).toBe(DEPLOYMENT_ROLES.ETH_TOKEN);

      // on.eth, registered by the deployer with its v1 expiry and every role, now
      // belongs to the endowment with those roles.
      const onId = idFromLabel("on");
      expect(await env.v2.ETHRegistry.read.getOwner([onId])).toBe(endowment());
      expect(await env.v2.ETHRegistry.read.getExpiry([onId])).toBe(onV1Expiry);
      const onResource = await env.v2.ETHRegistry.read.getResource([onId]);
      expect(
        await env.v2.ETHRegistry.read.roles([onResource, endowment()]),
      ).toBe(DEPLOYMENT_ROLES.ON_ETH_TOKEN);
      expect(
        await env.v2.ETHRegistry.read.roles([onResource, deployer()]),
      ).toBe(0n);

      // Neither batch registrar has an owner left to send through it.
      const client = createPublicClient({
        transport: http(`http://${env.hostPort}`),
      });
      for (const name of ["BatchRegistrar", "RootBatchRegistrar"] as const) {
        const deployment = env.rocketh.deployments[name]!;
        expect(
          await client.readContract({
            address: deployment.address,
            abi: deployment.abi,
            functionName: "owner",
          } as never),
        ).toBe(zeroAddress);
      }

      const findings = await verifyV2Roles({
        ...context(),
        deployer: deployer(),
        fromBlock: "0",
        stage: "post-registry-handover",
        reportOnly: true,
      });
      expect(findings.filter((finding) => finding.kind === "missing")).toEqual(
        [],
      );
      expect(
        findings.filter(
          (finding) =>
            finding.kind === "unexpected" &&
            getAddress(finding.holder.account as Address) === deployer(),
        ),
      ).toEqual([]);

      // The audit leaves the state it read beside the namespace's artifacts.
      const rolesDoc = readFileSync(
        join(deploymentsDir, NAMESPACE, "roles.md"),
        "utf-8",
      );
      expect(rolesDoc).toContain("at the `post-registry-handover` stage");
      expect(rolesDoc).toContain("### RootRegistry");
      expect(rolesDoc).toMatch(
        new RegExp(
          `"eth" entry \\| \\*\\*endowment[^*]*\\*\\*<br>\\[${endowment()}\\]`,
        ),
      );
    },
    TEST_TIMEOUT_MS,
  );

  it(
    "lets the endowment run the eth entry and the owner authorize registrars, keeping .eth names emancipated",
    async () => {
      await handOver();
      const ethId = idFromLabel("eth");
      const asOwner = { account: env.namedAccounts.owner };
      const asDeployer = { account: env.namedAccounts.deployer };
      const asEndowment = { account: env.namedAccounts.endowment };

      // The deployer can no longer touch the eth entry or the .eth registry.
      await expect(
        env.v2.RootRegistry.write.setResolver([ethId, STRANGER], asDeployer),
      ).rejects.toThrow();
      await expect(
        env.v2.ETHRegistry.write.grantRootRoles(
          [ROLES.REGISTRY.REGISTRAR, STRANGER],
          asDeployer,
        ),
      ).rejects.toThrow();

      // The owner holds no role on the eth entry.
      await expect(
        env.v2.RootRegistry.write.setResolver([ethId, STRANGER], asOwner),
      ).rejects.toThrow();

      // The endowment sets the eth entry's resolver and child registry, and holds
      // the admin roles to delegate them.
      await env.v2.RootRegistry.write.setResolver(
        [ethId, STRANGER],
        asEndowment,
      );
      expect(await env.v2.RootRegistry.read.getResolver(["eth"])).toBe(
        STRANGER,
      );
      await env.v2.RootRegistry.write.setSubregistry(
        [ethId, env.v2.ETHRegistry.address],
        asEndowment,
      );
      await env.v2.RootRegistry.write.grantRoles(
        [await ethResource(), ROLES.REGISTRY.SET_RESOLVER, STRANGER],
        asEndowment,
      );
      expect(
        await env.v2.RootRegistry.read.roles([await ethResource(), STRANGER]),
      ).toBe(ROLES.REGISTRY.SET_RESOLVER);

      // The owner can authorize a registrar on the .eth registry, but cannot take a
      // root role that reaches a name, so .eth names stay emancipated.
      await env.v2.ETHRegistry.write.grantRootRoles(
        [ROLES.REGISTRY.REGISTRAR, STRANGER],
        asOwner,
      );
      expect(
        await env.v2.ETHRegistry.read.hasRootRoles([
          ROLES.REGISTRY.REGISTRAR,
          STRANGER,
        ]),
      ).toBe(true);
      await expect(
        env.v2.ETHRegistry.write.grantRootRoles(
          [ROLES.REGISTRY.SET_RESOLVER, owner()],
          asOwner,
        ),
      ).rejects.toThrow();
      expect(await env.v2.ETHRegistry.read.isEmancipated()).toBe(true);

      // The owner holds the root registry's admin roles, but none of them reach the
      // eth entry or can be turned into a root role that does.
      await expect(
        env.v2.RootRegistry.write.grantRootRoles(
          [ROLES.REGISTRY.SET_SUBREGISTRY, owner()],
          asOwner,
        ),
      ).rejects.toThrow();

      // The registrar keeps the roles it registers and renews with.
      expect(
        await env.v2.ETHRegistry.read.hasRootRoles([
          ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW,
          env.v2.ETHRegistrar.address,
        ]),
      ).toBe(true);
    },
    TEST_TIMEOUT_MS,
  );

  it(
    "lets the endowment transfer the eth token on, with its roles",
    async () => {
      await handOver();
      const ethId = idFromLabel("eth");
      const user = getAddress(env.namedAccounts.user.address);
      await env.v2.RootRegistry.write.safeTransferFrom(
        [
          endowment(),
          user,
          await env.v2.RootRegistry.read.getTokenId([ethId]),
          1n,
          "0x",
        ],
        { account: env.namedAccounts.endowment },
      );
      expect(await env.v2.RootRegistry.read.getOwner([ethId])).toBe(user);
      expect(
        await env.v2.RootRegistry.read.roles([await ethResource(), user]),
      ).toBe(DEPLOYMENT_ROLES.ETH_TOKEN);
    },
    TEST_TIMEOUT_MS,
  );

  it(
    "sends nothing on a re-run and refuses to hand the registries to the deployer",
    async () => {
      await handOver();
      await handOver();
      await expect(
        handOverRegistryAdmin({
          ...context(),
          owner: deployer(),
          deployer: deployer(),
          impersonateAccount: deployer(),
        }),
      ).rejects.toThrow(/no one to hand the registries to/);
    },
    TEST_TIMEOUT_MS,
  );

  it(
    "emancipates the root registry, leaving the owner naming, metadata, and adding and assigning top-level names",
    async () => {
      await handOver();
      await emancipateRootRegistry({
        ...context(),
        impersonateAccount: owner(),
      });
      const asOwner = { account: env.namedAccounts.owner };

      expect(await rootRoles("RootRegistry", owner())).toBe(
        EMANCIPATED_OWNER_ROOT_ROLES,
      );
      expect(await env.v2.RootRegistry.read.isEmancipated()).toBe(true);
      await expect(
        env.v2.RootRegistry.write.grantRootRoles(
          [ROLES.REGISTRY.RENEW, STRANGER],
          asOwner,
        ),
      ).rejects.toThrow();

      // The owner gives a reserved DNS top-level name to its operator, keeping the
      // reservation's expiry, and adds a top-level name nobody reserved.
      expect(
        await env.v2.RootRegistry.read.getStatus([idFromLabel(DNS_TLD)]),
      ).toBe(STATUS.RESERVED);
      const operatorRoles =
        ROLES.REGISTRY.SET_SUBREGISTRY | ROLES.REGISTRY.SET_RESOLVER;
      await env.v2.RootRegistry.write.register(
        [DNS_TLD, STRANGER, zeroAddress, zeroAddress, operatorRoles, 0n],
        asOwner,
      );
      expect(
        await env.v2.RootRegistry.read.getStatus([idFromLabel(DNS_TLD)]),
      ).toBe(STATUS.REGISTERED);
      expect(
        await env.v2.RootRegistry.read.getExpiry([idFromLabel(DNS_TLD)]),
      ).toBe(MAX_EXPIRY);
      expect(
        await env.v2.RootRegistry.read.roles([
          await env.v2.RootRegistry.read.getResource([idFromLabel(DNS_TLD)]),
          STRANGER,
        ]),
      ).toBe(operatorRoles | ROLES.REGISTRY.WAS_RESERVED);
      await env.v2.RootRegistry.write.register(
        [
          "newtld",
          STRANGER,
          zeroAddress,
          zeroAddress,
          operatorRoles,
          MAX_EXPIRY,
        ],
        asOwner,
      );
      expect(
        await env.v2.RootRegistry.read.getStatus([idFromLabel("newtld")]),
      ).toBe(STATUS.REGISTERED);

      // Neither role overwrites a registered top-level name.
      await expect(
        env.v2.RootRegistry.write.register(
          ["eth", owner(), zeroAddress, zeroAddress, 0n, 0n],
          asOwner,
        ),
      ).rejects.toThrow();

      // The owner can pass either role to another account, such as a contract that
      // checks DNS ownership.
      await env.v2.RootRegistry.write.grantRootRoles(
        [ROLES.REGISTRY.REGISTER_RESERVED, STRANGER],
        asOwner,
      );

      const findings = await verifyV2Roles({
        ...context(),
        deployer: deployer(),
        fromBlock: "0",
        stage: "root-emancipated",
        reportOnly: true,
      });
      expect(findings.filter((finding) => finding.kind === "missing")).toEqual(
        [],
      );
    },
    TEST_TIMEOUT_MS,
  );
});
