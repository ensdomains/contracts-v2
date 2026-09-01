#!/usr/bin/env bun
/// Weighted ENSv1 migration fixture.
///
/// Registers the weighted migration corpus on ENSv1, shapes each name into the
/// exact pre-migration state its scenario specifies, and emits the label list
/// the pre-migration CLI reserves on v2 alongside the real registration export.
/// See docs/migration.md.

import { Command } from "commander";
import {
  createWalletClient,
  encodeAbiParameters,
  getAddress,
  http,
  keccak256,
  namehash,
  stringToHex,
  zeroAddress,
  zeroHash,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

import { Artifact_MigrationFixtureBatcher } from "generated/artifacts/MigrationFixtureBatcher.js";
import { Artifact_CustomResolver } from "generated/artifacts/CustomResolver.js";
import { Artifact_UnsupportedResolver } from "generated/artifacts/UnsupportedResolver.js";
import { Artifact_ERC1155ReceiverOwner } from "generated/artifacts/ERC1155ReceiverOwner.js";
import { Artifact_NonReceiverOwner } from "generated/artifacts/NonReceiverOwner.js";
import { Artifact_CustomSubregistry } from "generated/artifacts/CustomSubregistry.js";

import {
  accounts,
  clients,
  fixtureDigest,
  loadDotEnv,
  loadFixture,
  networkChain,
  optionalV1Deployment,
  parseNumber,
  premigrationCsvFile,
  readJson,
  receipt,
  rpc,
  runStatePath,
  v1Deployment,
  v2Deployment,
} from "./migrationFixture/config.js";
import {
  executionProfile,
  expectedResult,
  migrationRoute,
  preMigrationOwnerAlias,
  wrapperState,
  type RefContext,
} from "./migrationFixture/scenario.js";
import {
  planSetupSteps,
  tokenIdOf,
  type PlanContext,
  type PlannedCall,
} from "./migrationFixture/plan.js";
import {
  actorsNeedingHelperApproval,
  buildHelperArgs,
  migrationTarget,
  partitionMigration,
  type MigrationTarget,
} from "./migrationFixture/migrate.js";
import {
  executePlannedCalls,
  fundActors,
  fundAndImpersonate,
  type Executor,
} from "./migrationFixture/execute.js";
import {
  MIGRATION_DATA_COMPONENTS,
  type CommonOptions,
  type FixtureRunName,
  type FixtureRunState,
} from "./migrationFixture/types.js";

/// Corpus fixture contracts, in the order the run state records them.
const FIXTURE_ARTIFACTS = [
  { name: "CustomResolver", artifact: Artifact_CustomResolver, needsRegistry: true },
  { name: "UnsupportedResolver", artifact: Artifact_UnsupportedResolver, needsRegistry: false },
  { name: "ERC1155ReceiverOwner", artifact: Artifact_ERC1155ReceiverOwner, needsRegistry: false },
  { name: "NonReceiverOwner", artifact: Artifact_NonReceiverOwner, needsRegistry: false },
  { name: "CustomSubregistry", artifact: Artifact_CustomSubregistry, needsRegistry: false },
] as const;

/// Price is quoted before the transaction lands, so a buffer absorbs movement
/// between quote and execution. Without it one underfunded name reverts the
/// whole registration batch it travels in.
const PRICE_BUFFER_BPS = 1_000n;

const withBuffer = (price: bigint) => price + (price * PRICE_BUFFER_BPS) / 10_000n;

function v1Addresses(opts: CommonOptions) {
  return {
    base: v1Deployment(opts, "BaseRegistrarImplementation"),
    registry: v1Deployment(opts, "ENSRegistry"),
    wrapper: v1Deployment(opts, "NameWrapper"),
    controller: v1Deployment(opts, "ETHRegistrarController"),
    publicResolver: v1Deployment(opts, "PublicResolver"),
    reverseRegistrar: v1Deployment(opts, "ReverseRegistrar"),
    defaultReverse: optionalV1Deployment(opts, "DefaultReverseRegistrar"),
  };
}

function refContext(
  opts: CommonOptions,
  fixtureContracts: Record<string, Address>,
): RefContext {
  return {
    actors: new Map(accounts(opts).map((a) => [a.alias, a.account.address])),
    fixtureContracts,
    v1Address: (name) => v1Deployment(opts, name).address,
    v2Address: (name) => v2Deployment(opts, name).address,
  };
}

function planContext(
  opts: CommonOptions,
  fixtureContracts: Record<string, Address>,
  batcher: Address,
): PlanContext {
  const v1 = v1Addresses(opts);
  return {
    ...refContext(opts, fixtureContracts),
    batcher,
    addresses: {
      baseRegistrar: v1.base.address,
      registry: v1.registry.address,
      wrapper: v1.wrapper.address,
      controller: v1.controller.address,
      publicResolver: v1.publicResolver.address,
      reverseRegistrar: v1.reverseRegistrar.address,
      defaultReverseRegistrar:
        v1.defaultReverse?.address ?? v1.reverseRegistrar.address,
    },
  };
}

const PRIOR_RENEWER_ABI = [
  { type: "function", name: "owner", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  {
    type: "function",
    name: "transferRegistrarOwnership",
    stateMutability: "nonpayable",
    inputs: [{ type: "address", name: "newOwner" }],
    outputs: [],
  },
] as const;

async function ownerWallet(opts: CommonOptions, owner: Address) {
  const chain = networkChain(opts.network, opts.rpcUrl, opts.chainId);
  const key =
    opts.v1OwnerKey ??
    (process.env.SEPOLIA_V1_OWNER_KEY as Hex | undefined) ??
    (process.env.V1_OWNER_KEY as Hex | undefined);
  if (key) {
    const account = privateKeyToAccount(key);
    if (getAddress(account.address) !== getAddress(owner)) {
      throw new Error(`V1 owner key controls ${account.address}, expected ${owner}`);
    }
    return createWalletClient({ chain, account, transport: http(opts.rpcUrl) });
  }
  if (!opts.rpcStateControls) throw new Error(`missing V1 owner key for ${owner}`);
  await fundAndImpersonate(opts, owner);
  return createWalletClient({ chain, account: owner, transport: http(opts.rpcUrl) });
}

/// Ensures the official v1 controller can register.
///
/// On a chain whose registrations are still open this is a read-only no-op. It
/// only acts on a rehearsal or re-deploy where an earlier migration disabled
/// the controller, and needs the v1 owner key to undo that.
async function ensureV1ControllerEnabled(opts: CommonOptions): Promise<void> {
  const { client } = clients(opts);
  const base = v1Deployment(opts, "BaseRegistrarImplementation");
  const controller = v1Deployment(opts, "ETHRegistrarController");

  const enabled = (await client.readContract({
    address: base.address,
    abi: base.abi,
    functionName: "controllers",
    args: [controller.address],
  })) as boolean;
  if (enabled) return;

  const configured =
    opts.v1Owner ?? (process.env.MIGRATION_FIXTURE_V1_OWNER as Address | undefined);
  if (!configured) {
    throw new Error(
      "v1 ETHRegistrarController is not authorised and no --v1-owner was supplied; " +
        "seed before phase 3, or pass the v1 owner to re-enable it",
    );
  }
  const v1Owner = getAddress(configured);
  let currentOwner = getAddress(
    (await client.readContract({
      address: base.address,
      abi: base.abi,
      functionName: "owner",
    })) as Address,
  );

  if (currentOwner !== v1Owner) {
    // A completed migration hands registrar ownership to its renewer contract,
    // whose own owner can hand it back. Against an EOA this read reverts, which
    // is the right outcome: it means --v1-owner does not match the chain.
    const priorOwner = getAddress(
      (await client.readContract({
        address: currentOwner,
        abi: PRIOR_RENEWER_ABI,
        functionName: "owner",
      })) as Address,
    );
    const wallet = await ownerWallet(opts, priorOwner);
    const hash = await wallet.writeContract({
      address: currentOwner,
      abi: PRIOR_RENEWER_ABI,
      functionName: "transferRegistrarOwnership",
      args: [v1Owner],
    });
    await receipt(client, hash, "reclaim v1 registrar ownership");
    currentOwner = v1Owner;
  }

  const security = optionalV1Deployment(opts, "RegistrarSecurityController");
  const target = security ?? base;
  const targetOwner = getAddress(
    (await client.readContract({
      address: target.address,
      abi: target.abi,
      functionName: "owner",
    })) as Address,
  );
  const wallet = await ownerWallet(opts, targetOwner);
  const hash = await wallet.writeContract({
    address: target.address,
    abi: target.abi,
    functionName: security ? "addRegistrarController" : "addController",
    args: [controller.address],
  });
  await receipt(client, hash, "enable v1 registrar controller");
}

async function deployBatcher(opts: CommonOptions): Promise<Address> {
  const { client, wallet, account } = clients(opts);
  const controller = v1Deployment(opts, "ETHRegistrarController");
  const hash = await wallet.deployContract({
    abi: Artifact_MigrationFixtureBatcher.abi,
    bytecode: Artifact_MigrationFixtureBatcher.bytecode,
    args: [controller.address, account.address],
  });
  const r = await receipt(client, hash, "deploy MigrationFixtureBatcher");
  if (!r.contractAddress) throw new Error("batcher deployment had no contract address");
  return getAddress(r.contractAddress);
}

async function deployFixtureContracts(
  opts: CommonOptions,
  existing: Record<string, Address>,
): Promise<Record<string, Address>> {
  const { client, wallet } = clients(opts);
  const registry = v1Deployment(opts, "ENSRegistry");
  const out: Record<string, Address> = { ...existing };
  for (const { name, artifact, needsRegistry } of FIXTURE_ARTIFACTS) {
    if (out[name]) continue;
    const hash = await wallet.deployContract({
      abi: artifact.abi,
      bytecode: artifact.bytecode,
      args: (needsRegistry ? [registry.address] : []) as never,
    });
    const r = await receipt(client, hash, `deploy ${name}`);
    if (!r.contractAddress) throw new Error(`${name} deployment had no address`);
    out[name] = getAddress(r.contractAddress);
    console.log(`  ${name}: ${out[name]}`);
  }
  return out;
}

const deterministicSecret = (fixtureId: string): Hex =>
  keccak256(stringToHex(`ens-migration-fixture:${fixtureId}`));

function chunk<T>(values: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < values.length; i += size) out.push(values.slice(i, i + size));
  return out;
}

async function waitCommitmentAge(opts: CommonOptions, seconds: bigint): Promise<void> {
  if (seconds <= 0n) return;
  if (opts.rpcStateControls) {
    await rpc(opts, "evm_increaseTime", [Number(seconds)]);
    await rpc(opts, "evm_mine", []);
    return;
  }
  const deadline = Date.now() + Number(seconds + 1n) * 1000;
  while (Date.now() < deadline) await sleep(Math.min(5000, deadline - Date.now()));
}

function loadRunState(opts: CommonOptions): FixtureRunState | null {
  const path = runStatePath(opts);
  return existsSync(path) ? readJson<FixtureRunState>(path) : null;
}

function saveRunState(opts: CommonOptions, state: FixtureRunState): void {
  state.updatedAt = new Date().toISOString();
  writeFileSync(runStatePath(opts), `${JSON.stringify(state, null, 2)}\n`);
}

/// Emits the label list for the pre-migration CLI. The source CSV already leads
/// with a `labelName` column, which is the column preMigration.ts locates by
/// name, so the filtered file needs no transformation downstream.
function writePremigrationCsv(opts: CommonOptions, state: FixtureRunState): string {
  const source = premigrationCsvFile(opts);
  if (!existsSync(source)) throw new Error(`missing premigration CSV: ${source}`);
  const selected = new Set(state.names.map((n) => n.fixtureId));
  const lines = readFileSync(source, "utf8").trimEnd().split(/\r?\n/);
  const output = [lines[0]];
  for (const line of lines.slice(1)) {
    if (selected.has(line.split(",")[1])) output.push(line);
  }
  const destination = join(resolve(opts.workDir), "fixture-premigration.csv");
  writeFileSync(destination, `${output.join("\n")}\n`);
  return destination;
}

/// DNS wire encoding for MigrationHelper's `parentName`.
function dnsEncode(name: string): Hex {
  let out = "0x";
  for (const part of name.split(".").filter(Boolean)) {
    const bytes = new TextEncoder().encode(part);
    out += bytes.length.toString(16).padStart(2, "0");
    out += [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  }
  return `${out}00` as Hex;
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/// Offline validation: parses the corpus, checks the replica contract, and
/// plans every scenario's setup calls so an unsupported action or unresolvable
/// reference surfaces before anything touches a chain.
async function verify(opts: CommonOptions): Promise<void> {
  const rows = loadFixture(opts);
  if (!rows.length) throw new Error("fixture selection is empty");

  const ids = new Set<string>();
  const labels = new Set<string>();
  const perVector = new Map<string, number>();
  for (const row of rows) {
    if (ids.has(row.fixture_id)) throw new Error(`duplicate fixture ID ${row.fixture_id}`);
    if (labels.has(row.label)) throw new Error(`duplicate fixture label ${row.label}`);
    ids.add(row.fixture_id);
    labels.add(row.label);
    perVector.set(row.source_scenario_id, (perVector.get(row.source_scenario_id) ?? 0) + 1);
  }

  // Placeholder addresses are enough to prove every action resolves, and keep
  // the check runnable without deployments or an RPC.
  const placeholder = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
  const ctx: PlanContext = {
    actors: new Map(accounts(opts).map((a, i) => [a.alias, placeholder(0x1000 + i)])),
    fixtureContracts: Object.fromEntries(
      FIXTURE_ARTIFACTS.map((f, i) => [f.name, placeholder(0x2000 + i)]),
    ),
    v1Address: (name) => placeholder(0x3000 + name.length),
    v2Address: (name) => placeholder(0x4000 + name.length),
    batcher: placeholder(0x9999),
    addresses: {
      baseRegistrar: placeholder(0x3001),
      registry: placeholder(0x3002),
      wrapper: placeholder(0x3003),
      controller: placeholder(0x3004),
      publicResolver: placeholder(0x3005),
      reverseRegistrar: placeholder(0x3006),
      defaultReverseRegistrar: placeholder(0x3007),
    },
  };

  let batcherCalls = 0;
  let actorCalls = 0;
  const profiles = new Map<string, number>();
  const routes = new Map<string, number>();
  for (const row of rows) {
    expectedResult(row.scenario);
    wrapperState(row.scenario);
    const route = migrationRoute(row.scenario);
    routes.set(route, (routes.get(route) ?? 0) + 1);
    const profile = executionProfile(row.scenario);
    profiles.set(profile, (profiles.get(profile) ?? 0) + 1);
    for (const call of planSetupSteps(row, ctx)) {
      if (call.signer.kind === "batcher") batcherCalls += 1;
      else actorCalls += 1;
    }
  }

  const targets = rows.map((r) => migrationTarget(r, ctx));
  const { batches, singles } = partitionMigration(targets);
  let wrappedGroups = 0;
  for (const b of batches) {
    const args = buildHelperArgs(b.members);
    wrappedGroups +=
      args.unlockedGroups.length +
      args.lockedGroups.length +
      args.lockedChildren.reduce((n, c) => n + c.groups.length, 0);
  }

  console.log(
    JSON.stringify(
      {
        selected: rows.length,
        sourceScenarios: perVector.size,
        replicasPerVector: {
          min: Math.min(...perVector.values()),
          max: Math.max(...perVector.values()),
        },
        executionProfiles: Object.fromEntries(profiles),
        migrationRoutes: Object.fromEntries(routes),
        setupCalls: { batcher: batcherCalls, actor: actorCalls },
        migration: { batches: batches.length, wrappedGroups, singles: singles.length },
        helperApprovalActors: [...actorsNeedingHelperApproval(targets)].sort(),
        digest: fixtureDigest(rows),
      },
      null,
      2,
    ),
  );
}

async function deployFixtures(opts: CommonOptions): Promise<void> {
  mkdirSync(resolve(opts.workDir), { recursive: true });
  const { chain } = clients(opts);
  const existing = loadRunState(opts);
  const fixtureContracts = await deployFixtureContracts(
    opts,
    existing?.fixtureContracts ?? {},
  );
  const batcher = existing?.batcher ?? (await deployBatcher(opts));
  const now = new Date().toISOString();
  const state: FixtureRunState = existing ?? {
    version: 1,
    chainId: chain.id,
    fixtureRoot: resolve(opts.fixtureRoot),
    fixtureDigest: "0x" as Hex,
    createdAt: now,
    updatedAt: now,
    batcher,
    fixtureContracts,
    actorAddresses: {},
    names: [],
  };
  state.batcher = batcher;
  state.fixtureContracts = fixtureContracts;
  saveRunState(opts, state);
  console.log(`batcher: ${batcher}`);
  console.log(`run state: ${runStatePath(opts)}`);
}

async function seedV1(opts: CommonOptions): Promise<void> {
  mkdirSync(resolve(opts.workDir), { recursive: true });
  const rows = loadFixture(opts);
  if (!rows.length) throw new Error("fixture selection is empty");

  const actors = accounts(opts);
  const { chain, client, wallet } = clients(opts);
  await ensureV1ControllerEnabled(opts);

  const existing = loadRunState(opts);
  const batcher = existing?.batcher ?? (await deployBatcher(opts));
  const fixtureContracts = await deployFixtureContracts(
    opts,
    existing?.fixtureContracts ?? {},
  );

  const v1 = v1Addresses(opts);
  const ctx = planContext(opts, fixtureContracts, batcher);
  const executor: Executor = {
    opts,
    chain,
    client,
    wallet,
    batcher,
    actors: new Map(actors.map((a) => [a.alias, a])),
  };

  const runNames: FixtureRunName[] = rows.map((row) => {
    const state = wrapperState(row.scenario);
    const ownerAlias = preMigrationOwnerAlias(row.scenario);
    const actor = actors.find((a) => a.alias === ownerAlias);
    if (!actor) throw new Error(`unknown actor "${ownerAlias}" for ${row.fixture_id}`);
    return {
      fixtureId: row.fixture_id,
      sourceScenarioId: row.source_scenario_id,
      label: row.label,
      name: row.name,
      ownerAlias,
      owner: actor.account.address,
      form: state.form,
      wrapped: state.wrapped,
      locked: state.locked,
      fuses: state.fuses,
      route: migrationRoute(row.scenario),
      batchId: row.scenario.migration.batch?.batch_id ?? null,
      expectedResult: expectedResult(row.scenario),
      seedTransactions: [],
    };
  });

  const alreadySeeded = new Set(existing?.names.map((n) => n.fixtureId) ?? []);
  const pending = runNames.filter((n) => !alreadySeeded.has(n.fixtureId));
  const rowById = new Map(rows.map((r) => [r.fixture_id, r]));

  const registrations: {
    run: FixtureRunName;
    registration: any;
    commitment: Hex;
  }[] = [];

  for (const run of pending) {
    const row = rowById.get(run.fixtureId)!;
    const tokenId = tokenIdOf(run.label);
    const expiry = (await client.readContract({
      address: v1.base.address,
      abi: v1.base.abi,
      functionName: "nameExpires",
      args: [tokenId],
    })) as bigint;

    if (expiry > 0n) {
      // Resuming is only safe when the existing registration is one of ours.
      // Any other holder means the label collides with a name we do not
      // control, and shaping state against it would corrupt that name.
      const owner = getAddress(
        (await client.readContract({
          address: v1.base.address,
          abi: v1.base.abi,
          functionName: "ownerOf",
          args: [tokenId],
        })) as Address,
      );
      const ours = new Set(
        [batcher, v1.wrapper.address, ...actors.map((a) => a.account.address)].map((a) =>
          getAddress(a),
        ),
      );
      if (!ours.has(owner)) {
        throw new Error(
          `${run.fixtureId}: ${run.name} is already registered to ${owner}, which is not a fixture actor`,
        );
      }
      continue;
    }

    const registration = {
      label: run.label,
      owner: batcher,
      // Several scenarios turn on a short lease; a blanket duration erases the
      // expiry and grace behaviour they exist to exercise.
      duration: BigInt(row.scenario.v1.registration.duration_seconds),
      secret: deterministicSecret(run.fixtureId),
      resolver: zeroAddress,
      data: [] as Hex[],
      reverseRecord: 0,
      referrer: zeroHash,
    };
    const commitment = (await client.readContract({
      address: v1.controller.address,
      abi: v1.controller.abi,
      functionName: "makeCommitment",
      args: [registration],
    })) as Hex;
    registrations.push({ run, registration, commitment });
  }

  const commitBatchSize = Math.max(
    1,
    parseNumber(process.env.MIGRATION_FIXTURE_COMMIT_BATCH_SIZE, 80),
  );
  const registerBatchSize = Math.max(
    1,
    parseNumber(process.env.MIGRATION_FIXTURE_REGISTER_BATCH_SIZE, 12),
  );

  for (const batch of chunk(registrations, commitBatchSize)) {
    const hash = await wallet.writeContract({
      address: batcher,
      abi: Artifact_MigrationFixtureBatcher.abi,
      functionName: "commitBatch",
      args: [batch.map((x) => x.commitment)],
    });
    await receipt(client, hash, `commit batch (${batch.length})`);
    for (const x of batch) x.run.seedTransactions.push(hash);
  }

  if (registrations.length) {
    const minAge = (await client.readContract({
      address: v1.controller.address,
      abi: v1.controller.abi,
      functionName: "minCommitmentAge",
    })) as bigint;
    await waitCommitmentAge(opts, minAge + 1n);
  }

  for (const batch of chunk(registrations, registerBatchSize)) {
    const values: bigint[] = [];
    for (const x of batch) {
      const price = (await client.readContract({
        address: v1.controller.address,
        abi: v1.controller.abi,
        functionName: "rentPrice",
        args: [x.run.label, x.registration.duration],
      })) as { base: bigint; premium: bigint };
      values.push(withBuffer(price.base + price.premium));
    }
    const hash = await wallet.writeContract({
      address: batcher,
      abi: Artifact_MigrationFixtureBatcher.abi,
      functionName: "registerBatch",
      args: [batch.map((x) => x.registration), values],
      value: values.reduce((a, b) => a + b, 0n),
    });
    await receipt(client, hash, `register batch (${batch.length})`);
    for (const x of batch) x.run.seedTransactions.push(hash);
  }

  const perName = new Map<string, PlannedCall[]>();
  for (const run of pending) {
    perName.set(run.fixtureId, planSetupSteps(rowById.get(run.fixtureId)!, ctx));
  }
  const byId = new Map(pending.map((r) => [r.fixtureId, r]));
  await executePlannedCalls(executor, perName, (fixtureId, hash) => {
    byId.get(fixtureId)?.seedTransactions.push(hash);
  });

  const now = new Date().toISOString();
  const state: FixtureRunState = {
    version: 1,
    chainId: chain.id,
    fixtureRoot: resolve(opts.fixtureRoot),
    fixtureDigest: fixtureDigest(rows),
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
    batcher,
    fixtureContracts,
    actorAddresses: Object.fromEntries(actors.map((a) => [a.alias, a.account.address])),
    names: [
      ...(existing?.names.filter((n) => !runNames.some((x) => x.fixtureId === n.fixtureId)) ??
        []),
      ...runNames,
    ],
  };
  saveRunState(opts, state);
  const csv = writePremigrationCsv(opts, state);

  console.log(`seeded ${state.names.length} fixture names on v1`);
  console.log(`batcher: ${batcher}`);
  console.log(`run state: ${runStatePath(opts)}`);
  console.log(`premigration CSV: ${csv}`);
  console.log(`next: bun run migration -- premigration run --csv-file ${csv}`);
}

/// Grants MigrationHelper operator approval to every actor holding a name that
/// takes a helper route. `migrate` runs as one sender and the helper checks
/// approval for each token's own owner, so the set is the union of the batch
/// members' v1 owners — not only actors whose route names the helper.
async function prepare(opts: CommonOptions): Promise<void> {
  const state = loadRunState(opts);
  if (!state) throw new Error(`no run state at ${runStatePath(opts)}; run seed-v1 first`);
  const rows = loadFixture(opts);
  const ctx = refContext(opts, state.fixtureContracts);
  const aliases = actorsNeedingHelperApproval(rows.map((r) => migrationTarget(r, ctx)));

  const { chain, client } = clients(opts);
  const helper = v2Deployment(opts, "MigrationHelper");
  const v1 = v1Addresses(opts);
  const actors = accounts(opts);

  for (const alias of aliases) {
    const actor = actors.find((a) => a.alias === alias);
    if (!actor) throw new Error(`unknown actor "${alias}"`);
    if (opts.rpcStateControls) await fundAndImpersonate(opts, actor.account.address);
    const wallet = createWalletClient({
      chain,
      account: actor.account,
      transport: http(opts.rpcUrl),
    });
    for (const token of [v1.base, v1.wrapper]) {
      const approved = (await client.readContract({
        address: token.address,
        abi: token.abi,
        functionName: "isApprovedForAll",
        args: [actor.account.address, helper.address],
      })) as boolean;
      if (approved) continue;
      const hash = await wallet.writeContract({
        address: token.address,
        abi: token.abi,
        functionName: "setApprovalForAll",
        args: [helper.address, true],
      });
      await receipt(client, hash, `${alias} approve MigrationHelper`);
    }
  }
  console.log(
    `approved MigrationHelper for ${aliases.size} actors: ${[...aliases].sort().join(", ")}`,
  );
}

async function migrate(opts: CommonOptions): Promise<void> {
  const state = loadRunState(opts);
  if (!state) throw new Error(`no run state at ${runStatePath(opts)}; run seed-v1 first`);
  const rows = loadFixture(opts);
  const ctx = refContext(opts, state.fixtureContracts);
  const { chain, client } = clients(opts);
  const actors = accounts(opts);

  const helper = v2Deployment(opts, "MigrationHelper");
  const unlocked = v2Deployment(opts, "UnlockedMigrationController");
  const locked = v2Deployment(opts, "LockedMigrationController");
  const ethRegistry = v2Deployment(opts, "ETHRegistry");
  const v1 = v1Addresses(opts);

  const byId = new Map(state.names.map((n) => [n.fixtureId, n]));
  const targets = rows
    .filter((r) => byId.has(r.fixture_id))
    .map((r) => migrationTarget(r, ctx));
  const { batches, singles } = partitionMigration(targets);

  const walletFor = async (alias: string) => {
    const actor = actors.find((a) => a.alias === alias);
    if (!actor) throw new Error(`unknown actor "${alias}"`);
    if (opts.rpcStateControls) await fundAndImpersonate(opts, actor.account.address);
    return createWalletClient({
      chain,
      account: actor.account,
      transport: http(opts.rpcUrl),
    });
  };

  const encodePayload = (t: MigrationTarget) =>
    encodeAbiParameters([{ type: "tuple", components: MIGRATION_DATA_COMPONENTS }], [
      t.data,
    ]);

  const helperArgsFor = (members: MigrationTarget[]) => {
    const args = buildHelperArgs(members);
    return [
      args.unwrapped,
      args.unlockedGroups,
      args.lockedGroups,
      args.lockedChildren.map((c) => ({
        parentName: dnsEncode(c.parentName),
        groups: c.groups,
      })),
    ] as const;
  };

  const assertV2Registered = async (t: MigrationTarget) => {
    const v2State = (await client.readContract({
      address: ethRegistry.address,
      abi: ethRegistry.abi,
      functionName: "getState",
      args: [BigInt(keccak256(stringToHex(t.label)))],
    })) as { status: number; latestOwner: Address };
    if (Number(v2State.status) !== 2) {
      throw new Error(`${t.fixtureId}: expected REGISTERED, got status ${v2State.status}`);
    }
    if (getAddress(v2State.latestOwner) !== getAddress(t.data.owner)) {
      throw new Error(
        `${t.fixtureId}: v2 owner ${v2State.latestOwner}, expected ${t.data.owner}`,
      );
    }
  };

  for (const { batchId, members } of batches) {
    if (members.every((m) => byId.get(m.fixtureId)?.actualResult)) continue;
    const wallet = await walletFor(members[0].callerAlias);
    try {
      const hash = await wallet.writeContract({
        address: helper.address,
        abi: helper.abi,
        functionName: "migrate",
        args: helperArgsFor(members),
      });
      const r = await receipt(client, hash, `batch ${batchId} (${members.length})`);
      for (const m of members) {
        const run = byId.get(m.fixtureId)!;
        run.migrationTransaction = hash;
        run.migrationBlock = String(r.blockNumber);
        run.actualResult = "success";
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      for (const m of members) {
        const run = byId.get(m.fixtureId)!;
        run.actualResult = "revert";
        run.error = message;
      }
      if (members.some((m) => byId.get(m.fixtureId)!.expectedResult !== "revert")) {
        saveRunState(opts, state);
        throw error;
      }
    }
    saveRunState(opts, state);
  }

  // Parents before children, so a child's destination registry exists.
  const ordered = [...singles].sort(
    (a, b) =>
      a.name.split(".").length - b.name.split(".").length ||
      a.fixtureId.localeCompare(b.fixtureId),
  );

  for (const t of ordered) {
    const run = byId.get(t.fixtureId)!;
    if (run.actualResult) continue;
    const wallet = await walletFor(t.callerAlias);
    const owner = (ctx.actors.get(t.v1OwnerAlias) ?? t.data.owner) as Address;
    const payload = encodePayload(t);

    const send = async (): Promise<Hex> => {
      switch (t.route) {
        case "migration_helper":
          return wallet.writeContract({
            address: helper.address,
            abi: helper.abi,
            functionName: "migrate",
            args: helperArgsFor([t]),
          });
        case "locked_controller":
          return wallet.writeContract({
            address: v1.wrapper.address,
            abi: v1.wrapper.abi,
            functionName: "safeTransferFrom",
            args: [owner, locked.address, BigInt(namehash(t.name)), 1n, payload],
          });
        case "unlocked_controller":
          return t.form === "unwrapped"
            ? wallet.writeContract({
                address: v1.base.address,
                abi: v1.base.abi,
                functionName: "safeTransferFrom",
                args: [owner, unlocked.address, tokenIdOf(t.label), payload],
              })
            : wallet.writeContract({
                address: v1.wrapper.address,
                abi: v1.wrapper.abi,
                functionName: "safeTransferFrom",
                args: [owner, unlocked.address, BigInt(namehash(t.name)), 1n, payload],
              });
        // A child is delivered to the registry its migrated parent deployed, so
        // the destination is read from v2 rather than being a fixed address.
        case "wrapper_registry_receiver": {
          const parentLabel = t.name.split(".").slice(1).join(".").replace(/\.eth$/, "");
          const parentRegistry = (await client.readContract({
            address: ethRegistry.address,
            abi: ethRegistry.abi,
            functionName: "getSubregistry",
            args: [parentLabel],
          })) as Address;
          if (getAddress(parentRegistry) === zeroAddress) {
            throw new Error(`${t.fixtureId}: parent ${parentLabel}.eth is not migrated`);
          }
          return wallet.writeContract({
            address: v1.wrapper.address,
            abi: v1.wrapper.abi,
            functionName: "safeTransferFrom",
            args: [owner, parentRegistry, BigInt(namehash(t.name)), 1n, payload],
          });
        }
        default:
          throw new Error(
            `${t.fixtureId}: route "${t.route}" is not executed by this command`,
          );
      }
    };

    // A wrong terminal state is a distinct failure from a revert, so the two
    // are tracked separately rather than collapsed into one catch.
    let quarantined = false;
    try {
      const hash = await send();
      const r = await receipt(client, hash, `migrate ${t.name}`);
      if (run.expectedResult === "revert") {
        throw new Error(`${t.fixtureId}: expected revert but migration succeeded`);
      }
      run.migrationTransaction = hash;
      run.migrationBlock = String(r.blockNumber);
      run.actualResult = "success";
      try {
        await assertV2Registered(t);
      } catch (stateError) {
        quarantined = true;
        run.actualResult = "quarantined";
        run.error =
          stateError instanceof Error ? stateError.message : String(stateError);
        saveRunState(opts, state);
        throw stateError;
      }
    } catch (error) {
      if (quarantined) throw error;
      run.error = error instanceof Error ? error.message : String(error);
      run.actualResult = "revert";
      if (run.expectedResult !== "revert") {
        saveRunState(opts, state);
        throw error;
      }
    }
    saveRunState(opts, state);
  }

  const summary = state.names.reduce<Record<string, number>>((acc, n) => {
    const key = n.actualResult ?? "pending";
    acc[key] = (acc[key] ?? 0) + 1;
    return acc;
  }, {});
  console.log(`migration summary: ${JSON.stringify(summary)}`);
}

async function fundActorAccounts(opts: CommonOptions, floor: string): Promise<void> {
  const { chain, client, wallet } = clients(opts);
  const actors = accounts(opts);
  await fundActors(
    {
      opts,
      chain,
      client,
      wallet,
      batcher: zeroAddress,
      actors: new Map(actors.map((a) => [a.alias, a])),
    },
    floor,
  );
  for (const a of actors) {
    const balance = await client.getBalance({ address: a.account.address });
    console.log(`  ${a.alias} ${a.account.address} ${balance}`);
  }
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function addCommon(command: Command): Command {
  return command
    .requiredOption("--network <network>", "sepolia or mainnet")
    .option("--rpc-url <url>", "RPC URL")
    .option("--chain-id <id>", "Chain ID override")
    .requiredOption("--fixture-root <path>", "Weighted fixture bundle root")
    .requiredOption("--work-dir <path>", "Run/checkpoint directory")
    .option("--deployments-dir <path>", "V2 deployments root", "./deployments")
    .option("--deployment-network <name>", "V2 deployment namespace")
    .option("--v1-deployments-dir <path>", "V1 deployments root")
    .option("--v1-deployment-network <name>", "V1 deployment namespace")
    .option("--private-key <key>", "Fixture operator private key")
    .option("--v1-owner <address>", "Canonical V1 owner address")
    .option("--v1-owner-key <key>", "V1 owner / prior renewer owner private key")
    .option("--actor-mnemonic <mnemonic>", "Dedicated fixture actor mnemonic")
    .option("--limit <count>", "Limit selected fixture instances")
    .option("--tiers <tiers>", "Comma-separated popularity tiers")
    .option("--profiles <profiles>", "Comma-separated execution profiles, e.g. live_now")
    .option("--fixture-ids <ids>", "Comma-separated fixture IDs")
    .option(
      "--replicas-per-vector <count>",
      "Keep at most N replicas of each source scenario",
    )
    .option("--rpc-state-controls", "Enable impersonation/time control RPC methods", false);
}

function normalizeOptions(raw: any): CommonOptions {
  const network = raw.network as "sepolia" | "mainnet";
  if (network !== "sepolia" && network !== "mainnet") {
    throw new Error(`unsupported network: ${raw.network}`);
  }
  const rpcUrl =
    raw.rpcUrl ??
    process.env[network === "sepolia" ? "SEPOLIA_RPC_URL" : "MAINNET_RPC_URL"];
  if (!rpcUrl) throw new Error("missing --rpc-url or network RPC environment variable");
  return { ...raw, network, rpcUrl } as CommonOptions;
}

/// Adds the fixture subcommands to a parent command. Shared by this script's
/// own CLI and by the `fixture` group in migration.ts, so the two can never
/// drift apart on options or behaviour.
export function addFixtureSubcommands(program: Command): Command {
  program.addCommand(
    addCommon(
      new Command("verify").description(
        "Offline: validate the selection and plan every scenario's calls",
      ),
    ).action((raw) => verify(normalizeOptions(raw))),
  );
  program.addCommand(
    addCommon(new Command("fund-actors").description("Top up the fixture actor accounts"))
      .option("--floor <eth>", "Minimum balance per actor", "0.5")
      .action((raw) => fundActorAccounts(normalizeOptions(raw), raw.floor)),
  );
  program.addCommand(
    addCommon(
      new Command("deploy-fixtures").description(
        "Deploy the batcher and the fixture.* corpus contracts",
      ),
    ).action((raw) => deployFixtures(normalizeOptions(raw))),
  );
  program.addCommand(
    addCommon(
      new Command("seed-v1").description(
        "Register the corpus on v1 and shape each name's pre-migration state (before phase 3)",
      ),
    ).action((raw) => seedV1(normalizeOptions(raw))),
  );
  program.addCommand(
    addCommon(
      new Command("prepare").description(
        "After phase 1: approve MigrationHelper for every actor holding helper-routed names",
      ),
    ).action((raw) => prepare(normalizeOptions(raw))),
  );
  program.addCommand(
    addCommon(
      new Command("migrate").description("After phase 6: execute the fixture migrations"),
    ).action((raw) => migrate(normalizeOptions(raw))),
  );

  return program;
}

export async function main(argv = process.argv): Promise<void> {
  loadDotEnv(resolve(".env"));
  const program = addFixtureSubcommands(
    new Command("migration-fixture").description(
      "Seed the weighted ENSv1 migration fixture and carry it through pre-migration.",
    ),
  );
  await program.parseAsync(argv);
}

if (import.meta.main) {
  await main();
}
