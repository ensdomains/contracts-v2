import { afterAll, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getAddress, type Address } from "viem";

import { DEPLOYMENT_ROLES, ROLES } from "../../script/deploy-constants.js";
import {
  emancipateRootRegistry,
  handOverRegistryAdmin,
  verifyV2Roles,
} from "../../script/migrate.js";
import { writeDeploymentNamespace } from "../utils/deploymentArtifacts.js";
import { idFromLabel } from "../utils/utils.js";

const TEST_TIMEOUT_MS = 120_000;
const NETWORK = "mainnet";
const NAMESPACE = "mainnet";
const ROOT_RESOURCE = 0n;
const STRANGER = getAddress("0x000000000000000000000000000000000000beef");

describe("registry handover", () => {
  const { env, setupEnv } = process.TEST_GLOBALS!;
  const workDir = mkdtempSync(join(tmpdir(), "registry-handover-"));
  const deploymentsDir = join(workDir, "v2");

  setupEnv({ resetOnEach: true });

  afterAll(() => {
    rmSync(workDir, { recursive: true, force: true });
  });

  const deployer = () => getAddress(env.namedAccounts.deployer.address);
  const owner = () => getAddress(env.namedAccounts.owner.address);

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
      network: NETWORK,
      rpcUrl: `http://${env.hostPort}`,
      chainId: "1",
      deploymentsDir,
      deploymentNetwork: NAMESPACE,
      owner: owner(),
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
    "leaves the deployer no authority and gives the owner both registries",
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
      ).toBe(DEPLOYMENT_ROLES.ETH_TOKEN_OPERATOR);

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
    },
    TEST_TIMEOUT_MS,
  );

  it(
    "lets the owner set the eth entry and authorize registrars, keeping .eth names emancipated",
    async () => {
      await handOver();
      const ethId = idFromLabel("eth");
      const asOwner = { account: env.namedAccounts.owner };
      const asDeployer = { account: env.namedAccounts.deployer };

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

      // The owner sets the eth entry's resolver and child registry, but cannot pass
      // those roles on: admin roles on a name stay with its token holder.
      await env.v2.RootRegistry.write.setResolver([ethId, STRANGER], asOwner);
      expect(await env.v2.RootRegistry.read.getResolver(["eth"])).toBe(STRANGER);
      await env.v2.RootRegistry.write.setSubregistry(
        [ethId, env.v2.ETHRegistry.address],
        asOwner,
      );
      await expect(
        env.v2.RootRegistry.write.grantRoles(
          [await ethResource(), ROLES.REGISTRY.SET_RESOLVER, STRANGER],
          asOwner,
        ),
      ).rejects.toThrow();

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
    "emancipates the root registry, leaving the owner only naming and metadata",
    async () => {
      await handOver();
      await emancipateRootRegistry({
        ...context(),
        impersonateAccount: owner(),
      });

      expect(await rootRoles("RootRegistry", owner())).toBe(
        DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER,
      );
      await expect(
        env.v2.RootRegistry.write.grantRootRoles(
          [ROLES.REGISTRY.REGISTRAR, STRANGER],
          { account: env.namedAccounts.owner },
        ),
      ).rejects.toThrow();

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
