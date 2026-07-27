import { afterAll, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getAddress, type Address } from "viem";
import {
  disableV1Registrars,
  verifyV1RegistrarsDisabled,
} from "../../script/migration.js";

// Each revoke waits a full receipt poll, so the freeze needs more than the default
// per-test budget.
const TEST_TIMEOUT_MS = 120_000;

// The devnet runs on chain id 1, so the freeze's mainnet config applies and the
// locally deployed RegistrarSecurityController is discovered the same way the
// bundled mainnet artifact is.
const NETWORK = "mainnet";
const ACTIVE_NAMESPACE = "mainnet";
const ARCHIVED_NAMESPACE = "mainnet-archived-20260101";

// Stand-ins for a superseded deployment's handoff contracts: the freeze only reads
// their controller flags, so any address that is not an active deployment's works.
const ARCHIVED_REVERSE_ADAPTER = getAddress(
  "0x00000000000000000000000000000000000ada01",
);
const ARCHIVED_DEFAULT_REVERSE_ADAPTER = getAddress(
  "0x00000000000000000000000000000000000ada02",
);
const ARCHIVED_ETH_RENEWER = getAddress(
  "0x00000000000000000000000000000000000ada03",
);

describe("v1 registrar freeze", () => {
  const { env, setupEnv } = process.TEST_GLOBALS!;
  const workDir = mkdtempSync(join(tmpdir(), "v1-registrar-freeze-"));
  const v1DeploymentsDir = join(workDir, "v1");
  const deploymentsDir = join(workDir, "v2");

  setupEnv({ resetOnEach: true });

  afterAll(() => {
    rmSync(workDir, { recursive: true, force: true });
  });

  function writeDeployment(
    root: string,
    namespace: string,
    name: string,
    deployment: { address: Address; abi: readonly unknown[] },
  ) {
    const dir = join(root, namespace);
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, `${name}.json`),
      JSON.stringify({ address: deployment.address, abi: deployment.abi }),
    );
  }

  function writeNamespaceMetadata(root: string, namespace: string) {
    writeFileSync(
      join(root, namespace, ".chain"),
      JSON.stringify({ environment: namespace, chainId: 1 }),
    );
  }

  // Mirrors the artifact layout the freeze reads: the shared v1 contracts under the
  // v1 deployments root, and one v2 namespace per deployment — the active one plus a
  // superseded one whose handoff contracts must be revoked.
  function writeDeploymentArtifacts() {
    rmSync(workDir, { recursive: true, force: true });
    for (const [name, contract] of [
      ["BaseRegistrarImplementation", env.v1.BaseRegistrar],
      ["RegistrarSecurityController", env.v1.RegistrarSecurityController],
      ["ReverseRegistrar", env.v1.ReverseRegistrar],
      ["DefaultReverseRegistrar", env.shared.DefaultReverseRegistrar],
    ] as const) {
      writeDeployment(v1DeploymentsDir, NETWORK, name, contract);
    }

    for (const [name, contract] of [
      ["ReverseRegistrarAdapter", env.shared.ReverseRegistrarAdapter],
      [
        "DefaultReverseRegistrarAdapter",
        env.shared.DefaultReverseRegistrarAdapter,
      ],
    ] as const) {
      writeDeployment(deploymentsDir, ACTIVE_NAMESPACE, name, contract);
    }
    writeNamespaceMetadata(deploymentsDir, ACTIVE_NAMESPACE);

    for (const [name, address] of [
      ["ReverseRegistrarAdapter", ARCHIVED_REVERSE_ADAPTER],
      ["DefaultReverseRegistrarAdapter", ARCHIVED_DEFAULT_REVERSE_ADAPTER],
      ["ETHRenewerV1", ARCHIVED_ETH_RENEWER],
    ] as const) {
      writeDeployment(deploymentsDir, ARCHIVED_NAMESPACE, name, {
        address,
        abi: [],
      });
    }
    writeNamespaceMetadata(deploymentsDir, ARCHIVED_NAMESPACE);
  }

  function freezeOptions() {
    return {
      network: NETWORK,
      rpcUrl: `http://${env.hostPort}`,
      chainId: "1",
      deploymentsDir,
      deploymentNetwork: ACTIVE_NAMESPACE,
      v1DeploymentsDir,
      v1DeploymentNetwork: NETWORK,
      impersonateOwner: true,
    } as const;
  }

  async function ownerAccountOf(contract: {
    read: { owner: () => Promise<Address> };
  }) {
    const owner = await contract.read.owner();
    const account = env.accounts.find(
      (candidate) => getAddress(candidate.address) === getAddress(owner),
    );
    if (!account) throw new Error(`no local account for owner ${owner}`);
    return account;
  }

  // Grants a superseded deployment's handoff contracts the same v1 authorizations a
  // prior migration would have left behind.
  async function authorizeArchivedHandoffContracts() {
    const reverseOwner = await ownerAccountOf(env.v1.ReverseRegistrar);
    await env.v1.ReverseRegistrar.write.setController(
      [ARCHIVED_REVERSE_ADAPTER, true],
      { account: reverseOwner },
    );
    const defaultReverseOwner = await ownerAccountOf(
      env.shared.DefaultReverseRegistrar,
    );
    await env.shared.DefaultReverseRegistrar.write.setController(
      [ARCHIVED_DEFAULT_REVERSE_ADAPTER, true],
      { account: defaultReverseOwner },
    );
    const securityOwner = await ownerAccountOf(
      env.v1.RegistrarSecurityController,
    );
    await env.v1.RegistrarSecurityController.write.addRegistrarController(
      [ARCHIVED_ETH_RENEWER],
      { account: securityOwner },
    );
  }

  // Moves the BaseRegistrar out from under the security controller, the state a
  // re-migration leaves behind once ownership has been reclaimed to the v1 owner.
  async function reclaimRegistrarOwnershipToEoa() {
    const securityOwner = await ownerAccountOf(
      env.v1.RegistrarSecurityController,
    );
    await env.v1.RegistrarSecurityController.write.transferRegistrarOwnership(
      [securityOwner.address],
      { account: securityOwner },
    );
    return securityOwner;
  }

  it(
    "revokes a superseded deployment's reverse registrar adapters",
    async () => {
      writeDeploymentArtifacts();
      await authorizeArchivedHandoffContracts();

      // The audit must see the archived adapters, so the pre-freeze state fails.
      await expect(verifyV1RegistrarsDisabled(freezeOptions())).rejects.toThrow(
        /superseded v1 authorizations still enabled/,
      );

      await disableV1Registrars(freezeOptions());

      await expect(
        env.v1.ReverseRegistrar.read.controllers([ARCHIVED_REVERSE_ADAPTER]),
      ).resolves.toBe(false);
      await expect(
        env.shared.DefaultReverseRegistrar.read.controllers([
          ARCHIVED_DEFAULT_REVERSE_ADAPTER,
        ]),
      ).resolves.toBe(false);
      await expect(
        env.v1.BaseRegistrar.read.controllers([ARCHIVED_ETH_RENEWER]),
      ).resolves.toBe(false);

      // The active deployment's adapters keep writing reverse records.
      await expect(
        env.v1.ReverseRegistrar.read.controllers([
          env.shared.ReverseRegistrarAdapter.address,
        ]),
      ).resolves.toBe(true);
      await expect(
        env.shared.DefaultReverseRegistrar.read.controllers([
          env.shared.DefaultReverseRegistrarAdapter.address,
        ]),
      ).resolves.toBe(true);

      await verifyV1RegistrarsDisabled(freezeOptions());
    },
    TEST_TIMEOUT_MS,
  );

  it(
    "revokes registrar controllers while the security controller owns the registrar",
    async () => {
      writeDeploymentArtifacts();
      await authorizeArchivedHandoffContracts();

      await disableV1Registrars(freezeOptions());

      await expect(
        env.v1.BaseRegistrar.read.controllers([ARCHIVED_ETH_RENEWER]),
      ).resolves.toBe(false);
      await expect(
        env.v1.BaseRegistrar.read.controllers([env.v1.NameWrapper.address]),
      ).resolves.toBe(false);
    },
    TEST_TIMEOUT_MS,
  );

  it(
    "revokes registrar controllers after ownership is reclaimed from the security controller",
    async () => {
      writeDeploymentArtifacts();
      await authorizeArchivedHandoffContracts();
      const registrarOwner = await reclaimRegistrarOwnershipToEoa();

      // Routing through the security controller would revert here: it is a
      // pass-through that only works while it owns the registrar.
      expect(getAddress(await env.v1.BaseRegistrar.read.owner())).toBe(
        getAddress(registrarOwner.address),
      );

      await disableV1Registrars(freezeOptions());

      await expect(
        env.v1.BaseRegistrar.read.controllers([ARCHIVED_ETH_RENEWER]),
      ).resolves.toBe(false);
      await expect(
        env.v1.BaseRegistrar.read.controllers([env.v1.NameWrapper.address]),
      ).resolves.toBe(false);
      await expect(
        env.v1.ReverseRegistrar.read.controllers([ARCHIVED_REVERSE_ADAPTER]),
      ).resolves.toBe(false);

      await verifyV1RegistrarsDisabled(freezeOptions());
    },
    TEST_TIMEOUT_MS,
  );
});
