#!/usr/bin/env bun
// ENS v1 → v2 post-migration monitor.
//
// Continuously watches a migrated network (sepolia/mainnet) for regressions in
// the v1 ↔ v2 handoff: authorization drift on either side, resolution or
// renewal breakage, Universal Resolver proxy changes, and — most critically —
// organic v2 registrations of names that a still-protected v1 registration
// should have reserved (a "missed name", the primary migration risk).
//
// Two modes:
//   `check` — one pass of every check, exit code reflects the worst severity.
//   `watch` — daemon loop: checks + incremental event scanning + alert sinks.
//
// Read-only: the monitor never signs or broadcasts a transaction.
//
// See docs/monitoring.md for the full check catalogue and operations guide.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { resolve } from "node:path";
import { Command } from "commander";
import {
  createPublicClient,
  decodeFunctionResult,
  encodeFunctionData,
  getAddress,
  http,
  namehash,
  parseAbi,
  parseAbiItem,
  zeroAddress,
  type AbiEvent,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
} from "viem";
import { mainnet, sepolia } from "viem/chains";
import { bold, gray, green, red, yellow } from "yoctocolors";
import {
  DEPLOYED_UNIVERSAL_RESOLVER_PROXY,
  GRACE_PERIOD_V1,
  MAINNET_USDC,
  ROLES,
  SEC_PER_YEAR,
  SEPOLIA_USDC,
} from "./deploy-constants.js";

////////////////////////////////////////////////////////////////////////
// Network + filesystem configuration
////////////////////////////////////////////////////////////////////////

type MonitorNetwork = "sepolia" | "mainnet";

type NetworkConfig = {
  chain: Chain;
  rpcEnv: string;
  defaultPaymentTokens: Address[];
  defaultNames: string[];
  defaultRenewalStaleHours: number;
};

const NETWORKS: Record<MonitorNetwork, NetworkConfig> = {
  sepolia: {
    chain: sepolia,
    rpcEnv: "SEPOLIA_RPC_URL",
    defaultPaymentTokens: [SEPOLIA_USDC],
    defaultNames: [],
    // Sepolia renewal traffic is sparse, so liveness tracking is opt-in there.
    defaultRenewalStaleHours: 0,
  },
  mainnet: {
    chain: mainnet,
    rpcEnv: "MAINNET_RPC_URL",
    defaultPaymentTokens: [MAINNET_USDC],
    defaultNames: ["nick.eth", "vitalik.eth"],
    defaultRenewalStaleHours: 6,
  },
};

const CONTRACTS_DIR = resolve(import.meta.dirname, "..");
const DEFAULT_DEPLOYMENTS_DIR = resolve(CONTRACTS_DIR, "deployments");
const LOCAL_V1_DEPLOYMENTS_DIR = resolve(CONTRACTS_DIR, "deployments/v1");
const BUNDLED_V1_DEPLOYMENTS_DIR = resolve(
  CONTRACTS_DIR,
  "lib/ens-contracts/deployments",
);

const REGISTRAR_ROLES = ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW;

// Root-resource id in EnhancedAccessControl; role changes here are
// governance-level and always worth an alert.
const ROOT_RESOURCE = 0n;

// v1 registration controllers removed by the phase 3 freeze. They must never
// come back.
const V1_FROZEN_CONTROLLER_NAMES = [
  "LegacyETHRegistrarController",
  "ETHRegistrarController",
  "WrappedETHRegistrarController",
  "NameWrapper",
] as const;

// Label with ≥5 codepoints so the standard oracle prices it in the cheapest
// nonzero tier; used for state-free pricing probes.
const PRICE_PROBE_LABEL = "monitorprobe";

// Mirrors loadDotEnv in migration.ts: values already present in the
// environment win over the file.
function loadDotEnv(filePath: string): void {
  if (!existsSync(filePath)) return;
  for (const rawLine of readFileSync(filePath, "utf8").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = value;
  }
}

////////////////////////////////////////////////////////////////////////
// Minimal ABIs
////////////////////////////////////////////////////////////////////////

// The monitor carries its own minimal ABIs so it runs without a compile step;
// signatures mirror src/ interfaces and the stable v1 contracts.

const v1BaseRegistrarAbi = parseAbi([
  "function owner() view returns (address)",
  "function controllers(address) view returns (bool)",
  "function nameExpires(uint256 id) view returns (uint256)",
  "function ownerOf(uint256 id) view returns (address)",
]);

const v1RegistryAbi = parseAbi([
  "function owner(bytes32 node) view returns (address)",
  "function resolver(bytes32 node) view returns (address)",
]);

const v1ReverseRegistrarAbi = parseAbi([
  "function controllers(address) view returns (bool)",
]);

const v2RegistryAbi = parseAbi([
  "function hasRootRoles(uint256 roleBitmap, address account) view returns (bool)",
  "function getSubregistry(string label) view returns (address)",
  "function getState(uint256 anyId) view returns ((uint8 status, uint64 expiry, address latestOwner, uint256 tokenId, uint256 resource))",
]);

const registrarAbi = parseAbi([
  "function owner() view returns (address)",
  "function rentPriceOracle() view returns (address)",
  "function isRenewable(string label) view returns (bool)",
  "function getRenewPrice(string label, uint64 duration, address paymentToken) view returns (uint256)",
]);

const renewerAbi = parseAbi([
  "function syncWrapper(string[] labels)",
  "function BASE_REGISTRAR() view returns (address)",
  "function NAME_WRAPPER() view returns (address)",
]);

const oracleAbi = parseAbi([
  "function getRenewPrice(string label, uint64 expiry, uint64 duration, address paymentToken) view returns (uint256)",
]);

const urpAbi = parseAbi([
  "function admin() view returns (address)",
  "function implementation() view returns (address)",
]);

const urAbi = parseAbi([
  "function findExactRegistry(bytes name) view returns (address)",
  "function resolve(bytes name, bytes data) view returns (bytes, address)",
]);

const addrAbi = parseAbi([
  "function addr(bytes32 node) view returns (address)",
]);

// Event definitions, grouped by the contract set they are scanned from.

const EV_LABEL_REGISTERED = parseAbiItem(
  "event LabelRegistered(uint256 indexed tokenId, bytes32 indexed labelHash, string label, address owner, uint64 expiry, address indexed sender)",
);
const EV_LABEL_RESERVED = parseAbiItem(
  "event LabelReserved(uint256 indexed tokenId, bytes32 indexed labelHash, string label, uint64 expiry, address indexed sender)",
);
const EV_LABEL_UNREGISTERED = parseAbiItem(
  "event LabelUnregistered(uint256 indexed tokenId, address indexed sender)",
);
const EV_EAC_ROLES_CHANGED = parseAbiItem(
  "event EACRolesChanged(uint256 indexed resource, address indexed account, uint256 oldRoleBitmap, uint256 newRoleBitmap)",
);
const EV_SUBREGISTRY_UPDATED = parseAbiItem(
  "event SubregistryUpdated(uint256 indexed tokenId, address indexed subregistry, address indexed sender)",
);
const EV_RESOLVER_UPDATED = parseAbiItem(
  "event ResolverUpdated(uint256 indexed tokenId, address indexed resolver, address indexed sender)",
);

const EV_V2_NAME_RENEWED = parseAbiItem(
  "event NameRenewed(uint256 indexed tokenId, string label, uint64 duration, uint64 newExpiry, address paymentToken, bytes32 indexed referrer, uint256 amount)",
);
const EV_ORACLE_UPDATED = parseAbiItem(
  "event RentPriceOracleUpdated(address oracle)",
);

const EV_V1_CONTROLLER_ADDED = parseAbiItem(
  "event ControllerAdded(address indexed controller)",
);
const EV_V1_CONTROLLER_REMOVED = parseAbiItem(
  "event ControllerRemoved(address indexed controller)",
);
const EV_V1_NAME_REGISTERED = parseAbiItem(
  "event NameRegistered(uint256 indexed id, address indexed owner, uint256 expires)",
);
const EV_V1_NAME_RENEWED = parseAbiItem(
  "event NameRenewed(uint256 indexed id, uint256 expires)",
);
const EV_OWNERSHIP_TRANSFERRED = parseAbiItem(
  "event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)",
);
const EV_V1_CONTROLLER_CHANGED = parseAbiItem(
  "event ControllerChanged(address indexed controller, bool enabled)",
);

const EV_URP_UPGRADED = parseAbiItem(
  "event Upgraded(address indexed implementation)",
);
const EV_URP_ADMIN_CHANGED = parseAbiItem(
  "event AdminChanged(address indexed previousAdmin, address indexed newAdmin)",
);
const EV_URP_ADMIN_REMOVED = parseAbiItem(
  "event AdminRemoved(address indexed admin)",
);

////////////////////////////////////////////////////////////////////////
// Deployment address resolution
////////////////////////////////////////////////////////////////////////

type JsonDeployment = {
  address: Address;
  abi: readonly unknown[];
};

function loadDeploymentFromRoot(
  root: string,
  environment: string,
  name: string,
): JsonDeployment | null {
  const path = resolve(root, environment, `${name}.json`);
  if (!existsSync(path)) return null;
  const parsed = JSON.parse(readFileSync(path, "utf8"));
  if (!parsed?.address) return null;
  return { address: getAddress(parsed.address), abi: parsed.abi ?? [] };
}

type AddressBookOptions = {
  network: MonitorNetwork;
  deploymentsDir: string;
  deploymentNetwork: string;
  v1DeploymentsDir?: string;
  v1DeploymentNetwork?: string;
};

// Every contract the monitor touches. Optional entries cover contracts that
// legitimately do not exist on every network (testnet helpers, adapters).
type AddressBook = {
  ethRegistry: Address;
  rootRegistry: Address;
  ethRegistrar: Address;
  ethRenewerV1: Address;
  batchRegistrar: Address;
  graveyard: Address;
  unlockedMigrationController: Address;
  lockedMigrationController: Address;
  universalResolverV2: Address;
  managedUrp: Address;
  topUrp: Address;
  rentPriceOracle: Address | null;
  ensV2Resolver: Address | null;
  reverseRegistrarAdapter: Address | null;
  defaultReverseRegistrarAdapter: Address | null;
  testnetV1PremigrationRegistrar: Address | null;
  dnsV1MirrorRootBatchRegistrar: Address | null;
  v1BaseRegistrar: Address;
  v1Registry: Address;
  v1NameWrapper: Address;
  v1ReverseRegistrar: Address | null;
  v1DefaultReverseRegistrar: Address | null;
  v1FrozenControllers: { name: string; address: Address }[];
};

function loadAddressBook(
  opts: AddressBookOptions,
  overrides: Partial<Record<string, Address>>,
): AddressBook {
  const v2 = (name: string): Address | null =>
    loadDeploymentFromRoot(opts.deploymentsDir, opts.deploymentNetwork, name)
      ?.address ?? null;
  const requireV2 = (name: string): Address => {
    const address = v2(name);
    if (!address) {
      throw new Error(
        `Missing v2 deployment: ${opts.deploymentsDir}/${opts.deploymentNetwork}/${name}.json`,
      );
    }
    return address;
  };
  const v1Roots = opts.v1DeploymentsDir
    ? [resolve(opts.v1DeploymentsDir)]
    : [LOCAL_V1_DEPLOYMENTS_DIR, BUNDLED_V1_DEPLOYMENTS_DIR];
  const v1Env = opts.v1DeploymentNetwork ?? opts.network;
  const v1 = (name: string): Address | null => {
    for (const root of v1Roots) {
      const deployment = loadDeploymentFromRoot(root, v1Env, name);
      if (deployment) return deployment.address;
    }
    return null;
  };
  const requireV1 = (name: string): Address => {
    const address = v1(name);
    if (!address) {
      throw new Error(
        `Missing v1 deployment ${name} for ${v1Env}; looked in ${v1Roots.join(", ")}. ` +
          `Check out lib/ens-contracts or pass the address explicitly.`,
      );
    }
    return address;
  };
  const pick = (key: string, fallback: () => Address): Address =>
    overrides[key] ?? fallback();
  const pickOptional = (
    key: string,
    fallback: () => Address | null,
  ): Address | null => overrides[key] ?? fallback();

  const frozen: { name: string; address: Address }[] = [];
  for (const name of V1_FROZEN_CONTROLLER_NAMES) {
    const address = v1(name);
    if (address) frozen.push({ name, address });
  }

  return {
    ethRegistry: pick("ethRegistry", () => requireV2("ETHRegistry")),
    rootRegistry: pick("rootRegistry", () => requireV2("RootRegistry")),
    ethRegistrar: pick("ethRegistrar", () => requireV2("ETHRegistrar")),
    ethRenewerV1: pick("ethRenewerV1", () => requireV2("ETHRenewerV1")),
    batchRegistrar: pick("batchRegistrar", () => requireV2("BatchRegistrar")),
    graveyard: pick("graveyard", () => requireV2("Graveyard")),
    unlockedMigrationController: requireV2("UnlockedMigrationController"),
    lockedMigrationController: requireV2("LockedMigrationController"),
    universalResolverV2: requireV2("UniversalResolverV2"),
    managedUrp: pick("managedUrp", () =>
      requireV2("ManagedUniversalResolverProxy"),
    ),
    topUrp: pick("topUrp", () => DEPLOYED_UNIVERSAL_RESOLVER_PROXY as Address),
    rentPriceOracle: v2("StandardRentPriceOracle"),
    ensV2Resolver: v2("ENSV2Resolver"),
    reverseRegistrarAdapter: v2("ReverseRegistrarAdapter"),
    defaultReverseRegistrarAdapter: v2("DefaultReverseRegistrarAdapter"),
    testnetV1PremigrationRegistrar: v2("TestnetV1PremigrationRegistrar"),
    dnsV1MirrorRootBatchRegistrar: v2("DNSV1MirrorRootBatchRegistrar"),
    v1BaseRegistrar: pick("v1BaseRegistrar", () =>
      requireV1("BaseRegistrarImplementation"),
    ),
    v1Registry: pick("v1Registry", () => requireV1("ENSRegistry")),
    v1NameWrapper: pick("v1NameWrapper", () => requireV1("NameWrapper")),
    v1ReverseRegistrar: pickOptional("v1ReverseRegistrar", () =>
      v1("ReverseRegistrar"),
    ),
    v1DefaultReverseRegistrar: pickOptional("v1DefaultReverseRegistrar", () =>
      v1("DefaultReverseRegistrar"),
    ),
    v1FrozenControllers: frozen,
  };
}

////////////////////////////////////////////////////////////////////////
// State persistence
////////////////////////////////////////////////////////////////////////

type MonitorState = {
  version: 1;
  network: string;
  chainId: number;
  lastProcessedBlock: string;
  firstSeen: {
    topUrpAdmin?: Address;
    managedUrpAdmin?: Address;
    renewerOwner?: Address;
  };
  renewalWatermarks: { v2?: number; v1Renewer?: number; v1?: number };
  probeLabels: { registered?: string; reserved?: string };
  graveyardPending: { label: string; node: Hex; firstSeen: number }[];
  alertHistory: Record<string, { lastFired: number; failing: boolean }>;
  lastTick?: {
    at: number;
    block: string;
    critical: number;
    warning: number;
    checks: number;
  };
};

function newState(network: string, chainId: number): MonitorState {
  return {
    version: 1,
    network,
    chainId,
    lastProcessedBlock: "0",
    firstSeen: {},
    renewalWatermarks: {},
    probeLabels: {},
    graveyardPending: [],
    alertHistory: {},
  };
}

function statePath(workDir: string): string {
  return resolve(workDir, "monitor-state.json");
}

function loadState(
  workDir: string,
  network: string,
  chainId: number,
): MonitorState {
  const path = statePath(workDir);
  if (!existsSync(path)) return newState(network, chainId);
  const state = JSON.parse(readFileSync(path, "utf8")) as MonitorState;
  if (state.network !== network || state.chainId !== chainId) {
    throw new Error(
      `State file ${path} belongs to ${state.network}/${state.chainId}, not ${network}/${chainId}; use a different --work-dir`,
    );
  }
  return state;
}

function saveState(workDir: string, state: MonitorState): void {
  mkdirSync(workDir, { recursive: true });
  writeFileSync(statePath(workDir), `${JSON.stringify(state, null, 2)}\n`);
}

////////////////////////////////////////////////////////////////////////
// Checks + alerting framework
////////////////////////////////////////////////////////////////////////

type Severity = "info" | "warning" | "critical";

type CheckOutcome = {
  id: string;
  ok: boolean;
  severity: Severity;
  summary: string;
  details?: string;
};

type MonitorConfig = {
  network: MonitorNetwork;
  chain: Chain;
  rpcUrls: string[];
  workDir: string;
  confirmations: bigint;
  maxLogSpan: bigint;
  names: string[];
  paymentTokens: Address[];
  renewalStaleHours: number;
  graveyardLagHours: number;
  graveyardPendingMax: number;
  webhookUrl?: string;
  heartbeatUrl?: string;
  alertCooldownHours: number;
  deploymentsDir: string;
  deploymentNetwork: string;
};

type Ctx = {
  config: MonitorConfig;
  addrs: AddressBook;
  clients: PublicClient[];
  state: MonitorState;
};

function ok(id: string, summary: string, details?: string): CheckOutcome {
  return { id, ok: true, severity: "info", summary, details };
}

function fail(
  id: string,
  severity: Severity,
  summary: string,
  details?: string,
): CheckOutcome {
  return { id, ok: false, severity, summary, details };
}

// Runs a read against each provider in order until one succeeds, so a single
// flaky RPC does not fail a whole tick.
async function withFailover<T>(
  ctx: Ctx,
  fn: (client: PublicClient) => Promise<T>,
): Promise<T> {
  let lastError: unknown;
  for (const client of ctx.clients) {
    try {
      return await fn(client);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}

function errorMessage(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  return message.split("\n").slice(0, 3).join(" | ").slice(0, 400);
}

// Wraps a check so an RPC/evaluation error degrades to a warning rather than
// masquerading as a confirmed invariant violation.
async function runCheck(
  id: string,
  fn: () => Promise<CheckOutcome | CheckOutcome[]>,
): Promise<CheckOutcome[]> {
  try {
    const outcome = await fn();
    return Array.isArray(outcome) ? outcome : [outcome];
  } catch (error) {
    return [
      fail(id, "warning", "check could not be evaluated", errorMessage(error)),
    ];
  }
}

function severityColor(severity: Severity, text: string): string {
  if (severity === "critical") return red(text);
  if (severity === "warning") return yellow(text);
  return gray(text);
}

async function postWebhook(
  ctx: Ctx,
  payload: Record<string, unknown>,
): Promise<void> {
  if (!ctx.config.webhookUrl) return;
  try {
    await fetch(ctx.config.webhookUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (error) {
    console.error(gray(`webhook delivery failed: ${errorMessage(error)}`));
  }
}

// Deduplicates alerts: fires on a pass→fail transition or after the cooldown,
// and emits a recovery notice on fail→pass.
async function dispatchOutcomes(
  ctx: Ctx,
  outcomes: CheckOutcome[],
): Promise<void> {
  const now = Date.now();
  const cooldownMs = ctx.config.alertCooldownHours * 3_600_000;
  for (const outcome of outcomes) {
    const history = ctx.state.alertHistory[outcome.id];
    if (!outcome.ok) {
      const shouldFire =
        !history || !history.failing || now - history.lastFired >= cooldownMs;
      ctx.state.alertHistory[outcome.id] = {
        lastFired: shouldFire ? now : (history?.lastFired ?? now),
        failing: true,
      };
      if (shouldFire) {
        console.error(
          severityColor(
            outcome.severity,
            `[${outcome.severity.toUpperCase()}] ${outcome.id}: ${outcome.summary}`,
          ) + (outcome.details ? `\n  ${outcome.details}` : ""),
        );
        await postWebhook(ctx, {
          source: "ens-v2-monitor",
          network: ctx.config.network,
          chainId: ctx.config.chain.id,
          severity: outcome.severity,
          id: outcome.id,
          summary: outcome.summary,
          details: outcome.details,
          timestamp: new Date(now).toISOString(),
        });
      }
    } else if (history?.failing) {
      ctx.state.alertHistory[outcome.id] = { lastFired: now, failing: false };
      console.error(green(`[RECOVERED] ${outcome.id}: ${outcome.summary}`));
      await postWebhook(ctx, {
        source: "ens-v2-monitor",
        network: ctx.config.network,
        chainId: ctx.config.chain.id,
        severity: "info",
        id: outcome.id,
        summary: `recovered: ${outcome.summary}`,
        timestamp: new Date(now).toISOString(),
      });
    }
  }
}

////////////////////////////////////////////////////////////////////////
// Invariant checks
////////////////////////////////////////////////////////////////////////

async function checkWiring(ctx: Ctx): Promise<CheckOutcome[]> {
  const { addrs } = ctx;
  const outcomes: CheckOutcome[] = [];

  const contracts = [
    {
      address: addrs.v1BaseRegistrar,
      abi: v1BaseRegistrarAbi,
      functionName: "owner",
    } as const,
    {
      address: addrs.ethRegistry,
      abi: v2RegistryAbi,
      functionName: "hasRootRoles",
      args: [REGISTRAR_ROLES, addrs.ethRegistrar],
    } as const,
    {
      address: addrs.ethRegistry,
      abi: v2RegistryAbi,
      functionName: "hasRootRoles",
      args: [REGISTRAR_ROLES, addrs.batchRegistrar],
    } as const,
    {
      address: addrs.ethRegistry,
      abi: v2RegistryAbi,
      functionName: "hasRootRoles",
      args: [ROLES.REGISTRY.RENEW, addrs.ethRenewerV1],
    } as const,
    {
      address: addrs.ethRegistry,
      abi: v2RegistryAbi,
      functionName: "hasRootRoles",
      args: [
        ROLES.REGISTRY.REGISTER_RESERVED,
        addrs.unlockedMigrationController,
      ],
    } as const,
    {
      address: addrs.ethRegistry,
      abi: v2RegistryAbi,
      functionName: "hasRootRoles",
      args: [ROLES.REGISTRY.REGISTER_RESERVED, addrs.lockedMigrationController],
    } as const,
    {
      address: addrs.rootRegistry,
      abi: v2RegistryAbi,
      functionName: "getSubregistry",
      args: ["eth"],
    } as const,
    {
      address: addrs.topUrp,
      abi: urpAbi,
      functionName: "implementation",
    } as const,
    {
      address: addrs.topUrp,
      abi: urpAbi,
      functionName: "admin",
    } as const,
    {
      address: addrs.managedUrp,
      abi: urpAbi,
      functionName: "implementation",
    } as const,
    {
      address: addrs.managedUrp,
      abi: urpAbi,
      functionName: "admin",
    } as const,
    {
      address: addrs.ethRegistrar,
      abi: registrarAbi,
      functionName: "rentPriceOracle",
    } as const,
    {
      address: addrs.ethRenewerV1,
      abi: registrarAbi,
      functionName: "rentPriceOracle",
    } as const,
    {
      address: addrs.ethRenewerV1,
      abi: registrarAbi,
      functionName: "owner",
    } as const,
  ];

  const results = await withFailover(ctx, (client) =>
    client.multicall({ contracts, allowFailure: false }),
  );
  let i = 0;
  const v1Owner = results[i++] as Address;
  const registrarEnabled = results[i++] as boolean;
  const batchEnabled = results[i++] as boolean;
  const renewerEnabled = results[i++] as boolean;
  const unlockedRole = results[i++] as boolean;
  const lockedRole = results[i++] as boolean;
  const rootEthSubregistry = results[i++] as Address;
  const topImpl = results[i++] as Address;
  const topAdmin = results[i++] as Address;
  const managedImpl = results[i++] as Address;
  const managedAdmin = results[i++] as Address;
  const registrarOracle = results[i++] as Address;
  const renewerOracle = results[i++] as Address;
  const renewerOwner = results[i++] as Address;

  const same = (a: Address, b: Address) => getAddress(a) === getAddress(b);

  outcomes.push(
    same(v1Owner, addrs.ethRenewerV1)
      ? ok("v1-base-registrar-owner", `v1 BaseRegistrar owned by ETHRenewerV1`)
      : fail(
          "v1-base-registrar-owner",
          "critical",
          `v1 BaseRegistrar owner is ${v1Owner}, expected ETHRenewerV1 ${addrs.ethRenewerV1}`,
        ),
  );
  outcomes.push(
    registrarEnabled
      ? ok("v2-eth-registrar-enabled", "ETHRegistrar holds REGISTRAR|RENEW")
      : fail(
          "v2-eth-registrar-enabled",
          "critical",
          "ETHRegistrar lost REGISTRAR|RENEW on ETHRegistry — registrations/renewals are down",
        ),
  );
  outcomes.push(
    batchEnabled
      ? fail(
          "v2-batch-registrar-disabled",
          "critical",
          "BatchRegistrar still holds REGISTRAR|RENEW — pre-migration seeding roles must be revoked",
        )
      : ok(
          "v2-batch-registrar-disabled",
          "BatchRegistrar has no registrar roles",
        ),
  );
  outcomes.push(
    renewerEnabled
      ? ok("v2-eth-renewer-role", "ETHRenewerV1 holds RENEW")
      : fail(
          "v2-eth-renewer-role",
          "critical",
          "ETHRenewerV1 lost RENEW on ETHRegistry — v1 renewals are down",
        ),
  );
  outcomes.push(
    unlockedRole && lockedRole
      ? ok(
          "v2-migration-controllers-role",
          "migration controllers hold REGISTER_RESERVED",
        )
      : fail(
          "v2-migration-controllers-role",
          "critical",
          `migration controllers missing REGISTER_RESERVED (unlocked=${unlockedRole}, locked=${lockedRole}) — v1→v2 migration is down`,
        ),
  );
  outcomes.push(
    same(rootEthSubregistry, addrs.ethRegistry)
      ? ok("v2-root-eth-wiring", "RootRegistry .eth → ETHRegistry")
      : fail(
          "v2-root-eth-wiring",
          "critical",
          `RootRegistry .eth subregistry is ${rootEthSubregistry}, expected ${addrs.ethRegistry}`,
        ),
  );

  const topOk =
    same(topImpl, addrs.managedUrp) || same(topImpl, addrs.universalResolverV2);
  outcomes.push(
    topOk && same(managedImpl, addrs.universalResolverV2)
      ? ok(
          "urp-proxy-chain",
          `URP chain intact (top → ${same(topImpl, addrs.managedUrp) ? "managed → " : ""}UniversalResolverV2)`,
        )
      : fail(
          "urp-proxy-chain",
          "critical",
          `URP chain broken: top.implementation=${topImpl}, managed.implementation=${managedImpl}, expected managed=${addrs.managedUrp} or impl=${addrs.universalResolverV2}`,
        ),
  );

  // Admin and owner addresses are ratcheted against their first observed
  // values; any later change alerts until the operator resets the state file.
  const ratchets: {
    id: string;
    key: keyof MonitorState["firstSeen"];
    current: Address;
    label: string;
  }[] = [
    {
      id: "urp-top-admin-stable",
      key: "topUrpAdmin",
      current: topAdmin,
      label: "top URP admin",
    },
    {
      id: "urp-managed-admin-stable",
      key: "managedUrpAdmin",
      current: managedAdmin,
      label: "managed URP admin",
    },
    {
      id: "renewer-owner-stable",
      key: "renewerOwner",
      current: renewerOwner,
      label: "ETHRenewerV1 owner (controls v1 registrar custody)",
    },
  ];
  for (const ratchet of ratchets) {
    const first = ctx.state.firstSeen[ratchet.key];
    if (!first) {
      ctx.state.firstSeen[ratchet.key] = getAddress(ratchet.current);
      outcomes.push(ok(ratchet.id, `${ratchet.label} = ${ratchet.current}`));
    } else if (same(first, ratchet.current)) {
      outcomes.push(ok(ratchet.id, `${ratchet.label} unchanged`));
    } else {
      outcomes.push(
        fail(
          ratchet.id,
          "critical",
          `${ratchet.label} changed from ${first} to ${ratchet.current}`,
          "If this change was intentional, delete the firstSeen entry in monitor-state.json to re-baseline.",
        ),
      );
    }
  }

  outcomes.push(
    same(registrarOracle, renewerOracle)
      ? ok("oracle-wiring", `both registrars price via ${registrarOracle}`)
      : fail(
          "oracle-wiring",
          "warning",
          `rent price oracle mismatch: ETHRegistrar=${registrarOracle}, ETHRenewerV1=${renewerOracle}`,
        ),
  );

  return outcomes;
}

async function checkV1Controllers(ctx: Ctx): Promise<CheckOutcome[]> {
  const { addrs } = ctx;
  const outcomes: CheckOutcome[] = [];

  const expectedEnabled: { name: string; address: Address }[] = [
    { name: "ETHRenewerV1", address: addrs.ethRenewerV1 },
    { name: "Graveyard", address: addrs.graveyard },
  ];
  if (addrs.testnetV1PremigrationRegistrar) {
    expectedEnabled.push({
      name: "TestnetV1PremigrationRegistrar",
      address: addrs.testnetV1PremigrationRegistrar,
    });
  }

  const contracts = [
    ...expectedEnabled.map(
      (entry) =>
        ({
          address: addrs.v1BaseRegistrar,
          abi: v1BaseRegistrarAbi,
          functionName: "controllers",
          args: [entry.address],
        }) as const,
    ),
    ...addrs.v1FrozenControllers.map(
      (entry) =>
        ({
          address: addrs.v1BaseRegistrar,
          abi: v1BaseRegistrarAbi,
          functionName: "controllers",
          args: [entry.address],
        }) as const,
    ),
  ];
  const results = (await withFailover(ctx, (client) =>
    client.multicall({ contracts, allowFailure: false }),
  )) as boolean[];

  const enabledFlags = results.slice(0, expectedEnabled.length);
  const frozenFlags = results.slice(expectedEnabled.length);

  const missing = expectedEnabled.filter((_, index) => !enabledFlags[index]);
  outcomes.push(
    missing.length === 0
      ? ok(
          "v1-handoff-controllers-enabled",
          `v1 controllers intact (${expectedEnabled.map((e) => e.name).join(", ")})`,
        )
      : fail(
          "v1-handoff-controllers-enabled",
          "critical",
          `v1 BaseRegistrar controllers missing: ${missing.map((e) => e.name).join(", ")}`,
        ),
  );

  const revived = addrs.v1FrozenControllers.filter(
    (_, index) => frozenFlags[index],
  );
  outcomes.push(
    revived.length === 0
      ? ok(
          "v1-frozen-registration-controllers",
          "v1 registration controllers remain disabled",
        )
      : fail(
          "v1-frozen-registration-controllers",
          "critical",
          `frozen v1 controllers re-enabled: ${revived.map((e) => e.name).join(", ")} — v1 registration freeze is broken`,
        ),
  );

  const adapters: { surface: string; registrar: Address; adapter: Address }[] =
    [];
  if (addrs.v1ReverseRegistrar && addrs.reverseRegistrarAdapter) {
    adapters.push({
      surface: "ReverseRegistrar",
      registrar: addrs.v1ReverseRegistrar,
      adapter: addrs.reverseRegistrarAdapter,
    });
  }
  if (addrs.v1DefaultReverseRegistrar && addrs.defaultReverseRegistrarAdapter) {
    adapters.push({
      surface: "DefaultReverseRegistrar",
      registrar: addrs.v1DefaultReverseRegistrar,
      adapter: addrs.defaultReverseRegistrarAdapter,
    });
  }
  if (adapters.length > 0) {
    const flags = (await withFailover(ctx, (client) =>
      client.multicall({
        contracts: adapters.map(
          (entry) =>
            ({
              address: entry.registrar,
              abi: v1ReverseRegistrarAbi,
              functionName: "controllers",
              args: [entry.adapter],
            }) as const,
        ),
        allowFailure: false,
      }),
    )) as boolean[];
    const disabled = adapters.filter((_, index) => !flags[index]);
    outcomes.push(
      disabled.length === 0
        ? ok(
            "v1-reverse-adapters-enabled",
            "reverse registrar adapters remain authorized",
          )
        : fail(
            "v1-reverse-adapters-enabled",
            "critical",
            `reverse adapters lost v1 authorization: ${disabled.map((e) => e.surface).join(", ")} — v2 reverse records stop syncing to v1`,
          ),
    );
  }

  if (addrs.ensV2Resolver) {
    const resolver = (await withFailover(ctx, (client) =>
      client.readContract({
        address: addrs.v1Registry,
        abi: v1RegistryAbi,
        functionName: "resolver",
        args: [namehash("eth")],
      }),
    )) as Address;
    outcomes.push(
      getAddress(resolver) === getAddress(addrs.ensV2Resolver)
        ? ok(
            "v1-eth-resolver-v2",
            ".eth resolver on v1 registry is ENSV2Resolver",
          )
        : fail(
            "v1-eth-resolver-v2",
            "warning",
            `.eth resolver on v1 registry is ${resolver}, expected ENSV2Resolver ${addrs.ensV2Resolver} — v1-path resolution of migrated names may be broken`,
          ),
    );
  }

  return outcomes;
}

////////////////////////////////////////////////////////////////////////
// Functional probes
////////////////////////////////////////////////////////////////////////

// The empty-labels syncWrapper call reduces to addController+removeController
// on the v1 BaseRegistrar, so a successful simulation proves ETHRenewerV1
// still holds v1 registrar custody and the wrapper sync path is functional.
async function probeSyncWrapper(ctx: Ctx): Promise<CheckOutcome> {
  await withFailover(ctx, (client) =>
    client.simulateContract({
      address: ctx.addrs.ethRenewerV1,
      abi: renewerAbi,
      functionName: "syncWrapper",
      args: [[]],
    }),
  );
  return ok("probe-sync-wrapper", "syncWrapper([]) simulation succeeded");
}

async function probeRentPrices(ctx: Ctx): Promise<CheckOutcome[]> {
  const { addrs, config, state } = ctx;
  const outcomes: CheckOutcome[] = [];

  if (addrs.rentPriceOracle) {
    const now = BigInt(Math.floor(Date.now() / 1000));
    let priced: { token: Address; price: bigint } | null = null;
    const failures: string[] = [];
    for (const token of config.paymentTokens) {
      try {
        const price = (await withFailover(ctx, (client) =>
          client.readContract({
            address: addrs.rentPriceOracle as Address,
            abi: oracleAbi,
            functionName: "getRenewPrice",
            args: [PRICE_PROBE_LABEL, now, SEC_PER_YEAR, token],
          }),
        )) as bigint;
        priced = { token, price };
        break;
      } catch (error) {
        failures.push(`${token}: ${errorMessage(error)}`);
      }
    }
    outcomes.push(
      priced && priced.price > 0n
        ? ok(
            "probe-rent-price",
            `oracle prices a 1y renewal at ${priced.price} (token ${priced.token})`,
          )
        : fail(
            "probe-rent-price",
            "critical",
            "rent price oracle failed to price a renewal for every configured payment token",
            failures.join("; "),
          ),
    );
  }

  // Live-path pricing reads exercise the registrar contracts end to end using
  // labels learned from recent renewal events; until one is learned the probe
  // reports informational status only.
  const liveProbes: {
    id: string;
    label: string | undefined;
    address: Address;
    what: string;
  }[] = [
    {
      id: "probe-registrar-renew-price",
      label: state.probeLabels.registered,
      address: addrs.ethRegistrar,
      what: "v2 renewal (ETHRegistrar)",
    },
    {
      id: "probe-renewer-renew-price",
      label: state.probeLabels.reserved,
      address: addrs.ethRenewerV1,
      what: "v1 renewal (ETHRenewerV1)",
    },
  ];
  for (const probe of liveProbes) {
    if (!probe.label) {
      outcomes.push(
        ok(probe.id, `${probe.what}: no probe label learned yet — skipped`),
      );
      continue;
    }
    const renewable = (await withFailover(ctx, (client) =>
      client.readContract({
        address: probe.address,
        abi: registrarAbi,
        functionName: "isRenewable",
        args: [probe.label as string],
      }),
    )) as boolean;
    if (!renewable) {
      // The learned label lapsed or was claimed; forget it and re-learn.
      if (probe.id === "probe-registrar-renew-price")
        state.probeLabels.registered = undefined;
      else state.probeLabels.reserved = undefined;
      outcomes.push(
        ok(
          probe.id,
          `${probe.what}: probe label no longer renewable — re-learning`,
        ),
      );
      continue;
    }
    let priced = false;
    const failures: string[] = [];
    for (const token of ctx.config.paymentTokens) {
      try {
        const price = (await withFailover(ctx, (client) =>
          client.readContract({
            address: probe.address,
            abi: registrarAbi,
            functionName: "getRenewPrice",
            args: [probe.label as string, SEC_PER_YEAR, token],
          }),
        )) as bigint;
        if (price >= 0n) {
          priced = true;
          break;
        }
      } catch (error) {
        failures.push(errorMessage(error));
      }
    }
    outcomes.push(
      priced
        ? ok(probe.id, `${probe.what}: getRenewPrice("${probe.label}") ok`)
        : fail(
            probe.id,
            "critical",
            `${probe.what}: getRenewPrice("${probe.label}") reverted for every payment token — renewals likely down`,
            failures.join("; "),
          ),
    );
  }

  return outcomes;
}

async function probeResolution(ctx: Ctx): Promise<CheckOutcome[]> {
  const { addrs, config } = ctx;
  const outcomes: CheckOutcome[] = [];

  const ethRegistry = (await withFailover(ctx, (client) =>
    client.readContract({
      address: addrs.topUrp,
      abi: urAbi,
      functionName: "findExactRegistry",
      args: [dnsEncodeName("eth")],
    }),
  )) as Address;
  outcomes.push(
    getAddress(ethRegistry) === getAddress(addrs.ethRegistry)
      ? ok("probe-ur-eth-registry", "top URP serves the v2 registry tree")
      : fail(
          "probe-ur-eth-registry",
          "critical",
          `top URP findExactRegistry(eth) = ${ethRegistry}, expected ETHRegistry ${addrs.ethRegistry} — resolution is not serving v2`,
        ),
  );

  for (const name of config.names) {
    const id = `probe-resolution:${name}`;
    try {
      const [answer, resolver] = (await withFailover(ctx, (client) =>
        client.readContract({
          address: addrs.topUrp,
          abi: urAbi,
          functionName: "resolve",
          args: [
            dnsEncodeName(name),
            encodeFunctionData({
              abi: addrAbi,
              functionName: "addr",
              args: [namehash(name)],
            }),
          ],
        }),
      )) as [Hex, Address];
      const resolved = decodeFunctionResult({
        abi: addrAbi,
        functionName: "addr",
        data: answer,
      }) as Address;
      outcomes.push(
        resolved && getAddress(resolved) !== zeroAddress
          ? ok(id, `${name} → ${resolved} (resolver ${resolver})`)
          : fail(
              id,
              "critical",
              `${name} resolved to the zero address via ${resolver}`,
            ),
      );
    } catch (error) {
      outcomes.push(
        fail(
          id,
          "critical",
          `resolution of ${name} reverted`,
          errorMessage(error),
        ),
      );
    }
  }

  return outcomes;
}

function dnsEncodeName(name: string): Hex {
  const bytes: number[] = [];
  for (const label of name.split(".")) {
    const labelBytes = Buffer.from(label, "utf8");
    if (labelBytes.length > 255) throw new Error(`label too long: ${label}`);
    bytes.push(labelBytes.length, ...labelBytes);
  }
  bytes.push(0);
  return `0x${Buffer.from(bytes).toString("hex")}`;
}

async function checkRpcConsistency(
  ctx: Ctx,
): Promise<{ outcome: CheckOutcome; head: bigint }> {
  const heads: { url: string; head: bigint | null }[] = [];
  for (let index = 0; index < ctx.clients.length; index++) {
    try {
      heads.push({
        url: ctx.config.rpcUrls[index],
        head: await ctx.clients[index].getBlockNumber(),
      });
    } catch {
      heads.push({ url: ctx.config.rpcUrls[index], head: null });
    }
  }
  const live = heads.filter((entry) => entry.head !== null);
  if (live.length === 0) {
    return {
      outcome: fail(
        "rpc-heads-consistent",
        "critical",
        "no RPC provider is reachable",
      ),
      head: 0n,
    };
  }
  const max = live.reduce(
    (acc, entry) =>
      (entry.head as bigint) > acc ? (entry.head as bigint) : acc,
    0n,
  );
  const laggards = live.filter((entry) => max - (entry.head as bigint) > 10n);
  const dead = heads.filter((entry) => entry.head === null);
  const problems = [
    ...dead.map((entry) => `${entry.url}: unreachable`),
    ...laggards.map(
      (entry) => `${entry.url}: ${max - (entry.head as bigint)} blocks behind`,
    ),
  ];
  return {
    outcome:
      problems.length === 0
        ? ok(
            "rpc-heads-consistent",
            `${live.length}/${heads.length} providers at block ${max}`,
          )
        : fail(
            "rpc-heads-consistent",
            "warning",
            `RPC providers degraded: ${problems.join("; ")}`,
          ),
    head: max,
  };
}

////////////////////////////////////////////////////////////////////////
// Event scanning
////////////////////////////////////////////////////////////////////////

// getLogs over [fromBlock, toBlock] in chunks, halving the span whenever a
// provider refuses a range, mirroring the migration CLI's scan behaviour.
async function scanLogs(
  client: PublicClient,
  params: { address: Address | Address[]; events: AbiEvent[] },
  fromBlock: bigint,
  toBlock: bigint,
  maxSpan: bigint,
): Promise<any[]> {
  const logs: any[] = [];
  let start = fromBlock;
  let span = maxSpan;
  while (start <= toBlock) {
    const end = start + span - 1n > toBlock ? toBlock : start + span - 1n;
    try {
      const chunk = await client.getLogs({
        address: params.address as any,
        events: params.events as any,
        fromBlock: start,
        toBlock: end,
      });
      logs.push(...chunk);
      start = end + 1n;
    } catch (error) {
      if (span > 100n) {
        span = span / 2n;
        continue;
      }
      throw error;
    }
  }
  return logs;
}

async function blockTimestamp(ctx: Ctx, blockNumber: bigint): Promise<number> {
  const block = await withFailover(ctx, (client) =>
    client.getBlock({ blockNumber }),
  );
  return Number(block.timestamp);
}

// Judges an organic v2 registration against the v1 registrar: a name whose v1
// registration (plus its 90-day grace) was still live must have been reserved
// by pre-migration, so an organic claim of it means the migration missed it.
async function judgeOrganicRegistration(
  ctx: Ctx,
  label: string,
  labelHash: Hex,
  owner: Address,
  blockNumber: bigint,
  txHash: string,
): Promise<CheckOutcome | null> {
  const v1TokenId = BigInt(labelHash);
  const reads = await withFailover(ctx, (client) =>
    client.multicall({
      contracts: [
        {
          address: ctx.addrs.v1BaseRegistrar,
          abi: v1BaseRegistrarAbi,
          functionName: "nameExpires",
          args: [v1TokenId],
        },
        {
          address: ctx.addrs.v1BaseRegistrar,
          abi: v1BaseRegistrarAbi,
          functionName: "ownerOf",
          args: [v1TokenId],
        },
      ],
      allowFailure: true,
    }),
  );
  const expires =
    reads[0].status === "success" ? (reads[0].result as bigint) : null;
  const v1Owner =
    reads[1].status === "success" ? (reads[1].result as Address) : null;

  if (expires === null || expires === 0n) return null;
  if (v1Owner && getAddress(v1Owner) === getAddress(ctx.addrs.graveyard)) {
    return null;
  }
  const registeredAt = BigInt(await blockTimestamp(ctx, blockNumber));
  if (registeredAt >= expires + GRACE_PERIOD_V1) return null;

  // Re-read on every other provider so one bad RPC cannot fire this alone.
  const confirmations: string[] = [];
  for (let index = 1; index < ctx.clients.length; index++) {
    try {
      const cross = (await ctx.clients[index].readContract({
        address: ctx.addrs.v1BaseRegistrar,
        abi: v1BaseRegistrarAbi,
        functionName: "nameExpires",
        args: [v1TokenId],
      })) as bigint;
      confirmations.push(`${ctx.config.rpcUrls[index]}: nameExpires=${cross}`);
    } catch {
      confirmations.push(`${ctx.config.rpcUrls[index]}: unavailable`);
    }
  }

  return fail(
    `missed-name:${label}`,
    "critical",
    `"${label}.eth" was organically registered on v2 by ${owner} while its v1 registration is still protected (v1 expiry ${expires}, +90d grace not elapsed at registration time ${registeredAt})`,
    [
      `This name appears to have been missed by pre-migration — the v1 owner may lose it.`,
      `tx ${txHash}`,
      ...confirmations,
    ].join("\n  "),
  );
}

async function scanEvents(
  ctx: Ctx,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<CheckOutcome[]> {
  const { addrs, state, config } = ctx;
  const outcomes: CheckOutcome[] = [];
  const client = ctx.clients[0];
  const span = config.maxLogSpan;

  const [registryLogs, rootLogs, renewalLogs, v1Logs, reverseLogs, urpLogs] =
    await Promise.all([
      scanLogs(
        client,
        {
          address: addrs.ethRegistry,
          events: [
            EV_LABEL_REGISTERED,
            EV_LABEL_RESERVED,
            EV_LABEL_UNREGISTERED,
            EV_EAC_ROLES_CHANGED,
          ],
        },
        fromBlock,
        toBlock,
        span,
      ),
      scanLogs(
        client,
        {
          address: addrs.rootRegistry,
          events: [
            EV_LABEL_REGISTERED,
            EV_LABEL_RESERVED,
            EV_EAC_ROLES_CHANGED,
            EV_SUBREGISTRY_UPDATED,
            EV_RESOLVER_UPDATED,
          ],
        },
        fromBlock,
        toBlock,
        span,
      ),
      scanLogs(
        client,
        {
          address: [addrs.ethRegistrar, addrs.ethRenewerV1],
          events: [EV_V2_NAME_RENEWED, EV_ORACLE_UPDATED],
        },
        fromBlock,
        toBlock,
        span,
      ),
      scanLogs(
        client,
        {
          address: addrs.v1BaseRegistrar,
          events: [
            EV_V1_CONTROLLER_ADDED,
            EV_V1_CONTROLLER_REMOVED,
            EV_V1_NAME_REGISTERED,
            EV_V1_NAME_RENEWED,
            EV_OWNERSHIP_TRANSFERRED,
          ],
        },
        fromBlock,
        toBlock,
        span,
      ),
      addrs.v1ReverseRegistrar || addrs.v1DefaultReverseRegistrar
        ? scanLogs(
            client,
            {
              address: [
                addrs.v1ReverseRegistrar,
                addrs.v1DefaultReverseRegistrar,
              ].filter(Boolean) as Address[],
              events: [EV_V1_CONTROLLER_CHANGED],
            },
            fromBlock,
            toBlock,
            span,
          )
        : Promise.resolve([]),
      scanLogs(
        client,
        {
          address: [addrs.topUrp, addrs.managedUrp],
          events: [EV_URP_UPGRADED, EV_URP_ADMIN_CHANGED, EV_URP_ADMIN_REMOVED],
        },
        fromBlock,
        toBlock,
        span,
      ),
    ]);

  const same = (a?: Address | null, b?: Address | null) =>
    !!a && !!b && getAddress(a) === getAddress(b);

  // ETHRegistry activity: classify each mint by its sender.
  for (const log of registryLogs) {
    if (log.eventName === "LabelRegistered") {
      const { label, labelHash, owner, sender } = log.args;
      if (same(sender, addrs.ethRegistrar)) {
        const verdict = await judgeOrganicRegistration(
          ctx,
          label,
          labelHash,
          owner,
          log.blockNumber,
          log.transactionHash,
        );
        if (verdict) outcomes.push(verdict);
      } else if (
        same(sender, addrs.unlockedMigrationController) ||
        same(sender, addrs.lockedMigrationController)
      ) {
        if (
          state.graveyardPending.length < config.graveyardPendingMax &&
          !state.graveyardPending.some((entry) => entry.label === label)
        ) {
          state.graveyardPending.push({
            label,
            node: namehash(`${label}.eth`),
            firstSeen: Date.now(),
          });
        }
      } else if (same(sender, addrs.batchRegistrar)) {
        outcomes.push(
          fail(
            `v2-batch-registrar-active:${label}`,
            "critical",
            `BatchRegistrar registered "${label}" after migration — its roles should be revoked`,
            `tx ${log.transactionHash}`,
          ),
        );
      } else {
        outcomes.push(
          fail(
            `v2-unknown-minter:${label}`,
            "critical",
            `unknown sender ${sender} registered "${label}" directly on ETHRegistry`,
            `tx ${log.transactionHash}`,
          ),
        );
      }
    } else if (log.eventName === "LabelReserved") {
      outcomes.push(
        fail(
          `v2-post-migration-reservation:${log.args.label}`,
          "critical",
          `"${log.args.label}" was reserved on ETHRegistry by ${log.args.sender} after migration — seeding is supposed to be over`,
          `tx ${log.transactionHash}`,
        ),
      );
    } else if (log.eventName === "LabelUnregistered") {
      outcomes.push(
        fail(
          `v2-unregistered:${log.args.tokenId}`,
          "warning",
          `token ${log.args.tokenId} was force-unregistered on ETHRegistry by ${log.args.sender}`,
          `tx ${log.transactionHash}`,
        ),
      );
    } else if (log.eventName === "EACRolesChanged") {
      if ((log.args.resource as bigint) === ROOT_RESOURCE) {
        outcomes.push(
          fail(
            `v2-root-role-change:${log.args.account}:${log.transactionHash}`,
            "critical",
            `root-resource roles changed on ETHRegistry for ${log.args.account}: ${log.args.oldRoleBitmap} → ${log.args.newRoleBitmap}`,
            `tx ${log.transactionHash} — verify this was an intended governance action`,
          ),
        );
      }
    }
  }

  // RootRegistry activity is rare and always significant; only the known DNS
  // mirror registrar produces routine traffic.
  for (const log of rootLogs) {
    if (log.eventName === "EACRolesChanged") {
      if ((log.args.resource as bigint) !== ROOT_RESOURCE) continue;
      outcomes.push(
        fail(
          `root-registry-role-change:${log.args.account}:${log.transactionHash}`,
          "critical",
          `root-resource roles changed on RootRegistry for ${log.args.account}`,
          `tx ${log.transactionHash}`,
        ),
      );
    } else {
      const sender = (log.args as { sender?: Address }).sender;
      if (same(sender, addrs.dnsV1MirrorRootBatchRegistrar)) continue;
      outcomes.push(
        fail(
          `root-registry-activity:${log.transactionHash}:${log.logIndex}`,
          "critical",
          `RootRegistry ${log.eventName} from ${sender ?? "unknown sender"} — TLD-level change`,
          `tx ${log.transactionHash}`,
        ),
      );
    }
  }

  // Renewal traffic feeds the liveness watermarks and probe-label learning.
  let latestV2Renewal: { block: bigint; label: string } | null = null;
  let latestV1RenewerRenewal: { block: bigint; label: string } | null = null;
  for (const log of renewalLogs) {
    if (log.eventName === "NameRenewed") {
      if (same(log.address, addrs.ethRegistrar)) {
        if (!latestV2Renewal || log.blockNumber > latestV2Renewal.block) {
          latestV2Renewal = { block: log.blockNumber, label: log.args.label };
        }
      } else if (
        !latestV1RenewerRenewal ||
        log.blockNumber > latestV1RenewerRenewal.block
      ) {
        latestV1RenewerRenewal = {
          block: log.blockNumber,
          label: log.args.label,
        };
      }
    } else if (log.eventName === "RentPriceOracleUpdated") {
      outcomes.push(
        fail(
          `oracle-updated:${log.address}:${log.transactionHash}`,
          "warning",
          `rent price oracle updated to ${log.args.oracle} on ${same(log.address, addrs.ethRegistrar) ? "ETHRegistrar" : "ETHRenewerV1"}`,
          `tx ${log.transactionHash} — verify this was an intended governance action`,
        ),
      );
    }
  }
  if (latestV2Renewal) {
    state.renewalWatermarks.v2 = await blockTimestamp(
      ctx,
      latestV2Renewal.block,
    );
    state.probeLabels.registered = latestV2Renewal.label;
  }
  if (latestV1RenewerRenewal) {
    state.renewalWatermarks.v1Renewer = await blockTimestamp(
      ctx,
      latestV1RenewerRenewal.block,
    );
    state.probeLabels.reserved = latestV1RenewerRenewal.label;
  }

  // v1 BaseRegistrar: registrations must only come from the Graveyard's
  // permanent claims; controller churn must only be syncWrapper's transient
  // NameWrapper add/remove pairs; ownership must never move.
  const controllerTxs = new Map<
    string,
    { added: Address[]; removed: Address[] }
  >();
  let latestV1Renewal: bigint | null = null;
  for (const log of v1Logs) {
    if (log.eventName === "NameRegistered") {
      if (!same(log.args.owner, addrs.graveyard)) {
        outcomes.push(
          fail(
            `v1-freeze-breach:${log.transactionHash}:${log.logIndex}`,
            "critical",
            `v1 registration minted to ${log.args.owner} (id ${log.args.id}) — the v1 registration freeze is broken`,
            `tx ${log.transactionHash}`,
          ),
        );
      }
    } else if (log.eventName === "NameRenewed") {
      if (!latestV1Renewal || log.blockNumber > latestV1Renewal) {
        latestV1Renewal = log.blockNumber;
      }
    } else if (log.eventName === "OwnershipTransferred") {
      outcomes.push(
        fail(
          `v1-ownership-transferred:${log.transactionHash}`,
          "critical",
          `v1 BaseRegistrar ownership transferred from ${log.args.previousOwner} to ${log.args.newOwner}`,
          `tx ${log.transactionHash}`,
        ),
      );
    } else if (
      log.eventName === "ControllerAdded" ||
      log.eventName === "ControllerRemoved"
    ) {
      const entry = controllerTxs.get(log.transactionHash) ?? {
        added: [],
        removed: [],
      };
      if (log.eventName === "ControllerAdded")
        entry.added.push(log.args.controller);
      else entry.removed.push(log.args.controller);
      controllerTxs.set(log.transactionHash, entry);
    }
  }
  for (const [txHash, entry] of controllerTxs) {
    const benign =
      entry.added.length === entry.removed.length &&
      entry.added.every((address) => same(address, addrs.v1NameWrapper)) &&
      entry.removed.every((address) => same(address, addrs.v1NameWrapper));
    if (!benign) {
      outcomes.push(
        fail(
          `v1-controller-change:${txHash}`,
          "critical",
          `v1 BaseRegistrar controller set changed outside syncWrapper (added: ${entry.added.join(", ") || "none"}; removed: ${entry.removed.join(", ") || "none"})`,
          `tx ${txHash}`,
        ),
      );
    }
  }
  if (latestV1Renewal) {
    state.renewalWatermarks.v1 = await blockTimestamp(ctx, latestV1Renewal);
  }

  for (const log of reverseLogs) {
    const { controller, enabled } = log.args;
    const isOurAdapter =
      same(controller, addrs.reverseRegistrarAdapter) ||
      same(controller, addrs.defaultReverseRegistrarAdapter) ||
      same(controller, addrs.testnetV1PremigrationRegistrar);
    if (isOurAdapter && !enabled) {
      outcomes.push(
        fail(
          `reverse-adapter-disabled:${controller}`,
          "critical",
          `v1 reverse registrar revoked migration adapter ${controller}`,
          `tx ${log.transactionHash}`,
        ),
      );
    } else if (!isOurAdapter) {
      outcomes.push(
        fail(
          `reverse-controller-change:${controller}:${log.transactionHash}`,
          "warning",
          `v1 reverse registrar ${log.address} controller ${controller} ${enabled ? "enabled" : "disabled"}`,
          `tx ${log.transactionHash}`,
        ),
      );
    }
  }

  for (const log of urpLogs) {
    outcomes.push(
      fail(
        `urp-${log.eventName.toLowerCase()}:${log.address}:${log.transactionHash}`,
        "critical",
        `${same(log.address, addrs.topUrp) ? "top" : "managed"} URP ${log.eventName}: ${JSON.stringify(log.args)}`,
        `tx ${log.transactionHash} — Universal Resolver proxy changed; verify this was an intended governance action`,
      ),
    );
  }

  return outcomes;
}

////////////////////////////////////////////////////////////////////////
// Graveyard lag + renewal liveness
////////////////////////////////////////////////////////////////////////

// Migrated names leave a v1 registry record behind until the (external)
// graveyard daemon clears it; some lag is expected, sustained lag is not.
async function checkGraveyardLag(ctx: Ctx): Promise<CheckOutcome> {
  const { addrs, state, config } = ctx;
  if (state.graveyardPending.length === 0) {
    return ok("graveyard-clear-lag", "no migrated names awaiting v1 cleanup");
  }
  const sample = state.graveyardPending.slice(0, 200);
  const owners = (await withFailover(ctx, (client) =>
    client.multicall({
      contracts: sample.map(
        (entry) =>
          ({
            address: addrs.v1Registry,
            abi: v1RegistryAbi,
            functionName: "owner",
            args: [entry.node],
          }) as const,
      ),
      allowFailure: true,
    }),
  )) as { status: string; result?: Address }[];
  const cleared = new Set<string>();
  sample.forEach((entry, index) => {
    const read = owners[index];
    if (
      read.status === "success" &&
      read.result &&
      getAddress(read.result) === getAddress(addrs.graveyard)
    ) {
      cleared.add(entry.label);
    }
  });
  state.graveyardPending = state.graveyardPending.filter(
    (entry) => !cleared.has(entry.label),
  );

  const now = Date.now();
  const lagMs = config.graveyardLagHours * 3_600_000;
  const overdue = state.graveyardPending.filter(
    (entry) => now - entry.firstSeen > lagMs,
  );
  if (overdue.length > 0) {
    return fail(
      "graveyard-clear-lag",
      "warning",
      `${overdue.length} migrated name(s) still have live v1 registry records after ${config.graveyardLagHours}h (oldest: "${overdue[0].label}") — graveyard daemon may be stalled`,
    );
  }
  return ok(
    "graveyard-clear-lag",
    `${state.graveyardPending.length} migrated name(s) awaiting v1 cleanup, all within the ${config.graveyardLagHours}h window`,
  );
}

// Renewals are all-or-nothing: if either path breaks, its traffic stops. A
// silent watermark for longer than the threshold is treated as an outage
// signal on networks with steady renewal volume.
function checkRenewalLiveness(ctx: Ctx): CheckOutcome[] {
  const { state, config } = ctx;
  if (config.renewalStaleHours <= 0) return [];
  const now = Math.floor(Date.now() / 1000);
  const staleSeconds = config.renewalStaleHours * 3600;
  const streams: { id: string; label: string; last?: number }[] = [
    {
      id: "renewal-liveness-v2",
      label: "v2 renewals (ETHRegistrar)",
      last: state.renewalWatermarks.v2,
    },
    {
      id: "renewal-liveness-v1",
      label: "v1 renewals (ETHRenewerV1)",
      last: state.renewalWatermarks.v1Renewer,
    },
  ];
  return streams.map((stream) => {
    if (!stream.last) {
      return ok(stream.id, `${stream.label}: no renewal observed yet`);
    }
    const age = now - stream.last;
    return age > staleSeconds
      ? fail(
          stream.id,
          "warning",
          `${stream.label}: none observed for ${Math.floor(age / 3600)}h (threshold ${config.renewalStaleHours}h) — renewal failures are all-or-nothing, investigate`,
        )
      : ok(
          stream.id,
          `${stream.label}: last observed ${Math.floor(age / 60)}m ago`,
        );
  });
}

////////////////////////////////////////////////////////////////////////
// Deep audits (shelling out to the migration CLI)
////////////////////////////////////////////////////////////////////////

function runDeepAudits(ctx: Ctx, csvFile?: string): CheckOutcome[] {
  const outcomes: CheckOutcome[] = [];
  const commands: { id: string; args: string[] }[] = [
    {
      id: "deep-v1-registrars-disabled",
      args: ["phase", "verify-v1-registrars-disabled"],
    },
    { id: "deep-v2-registrar", args: ["phase", "verify-v2-registrar"] },
    { id: "deep-urp", args: ["phase", "verify-urp"] },
  ];
  if (csvFile) {
    commands.push({
      id: "deep-premigration-verify",
      args: ["premigration", "verify", "--csv-file", csvFile],
    });
  }
  for (const command of commands) {
    console.log(
      gray(`running deep audit: migration ${command.args.join(" ")}`),
    );
    const result = spawnSync(
      "bun",
      [
        "run",
        "migration",
        "--",
        ...command.args,
        "--network",
        ctx.config.network,
        "--rpc-url",
        ctx.config.rpcUrls[0],
        "--deployments-dir",
        ctx.config.deploymentsDir,
        "--deployment-network",
        ctx.config.deploymentNetwork,
      ],
      { cwd: CONTRACTS_DIR, encoding: "utf8", timeout: 30 * 60_000 },
    );
    if (result.status === 0) {
      outcomes.push(
        ok(command.id, `migration ${command.args.join(" ")} passed`),
      );
    } else {
      const output = `${result.stdout ?? ""}\n${result.stderr ?? ""}`.trim();
      outcomes.push(
        fail(
          command.id,
          "critical",
          `migration ${command.args.join(" ")} failed (exit ${result.status})`,
          output.split("\n").slice(-15).join("\n"),
        ),
      );
    }
  }
  return outcomes;
}

////////////////////////////////////////////////////////////////////////
// Tick orchestration
////////////////////////////////////////////////////////////////////////

async function runTick(
  ctx: Ctx,
  opts: { scanFromBlock?: bigint },
): Promise<CheckOutcome[]> {
  const outcomes: CheckOutcome[] = [];

  const { outcome: rpcOutcome, head } = await checkRpcConsistency(ctx);
  outcomes.push(rpcOutcome);
  if (head === 0n) return outcomes;

  outcomes.push(...(await runCheck("wiring", () => checkWiring(ctx))));
  outcomes.push(
    ...(await runCheck("v1-controllers", () => checkV1Controllers(ctx))),
  );
  outcomes.push(
    ...(await runCheck("probe-sync-wrapper", () => probeSyncWrapper(ctx))),
  );
  outcomes.push(
    ...(await runCheck("probe-rent-price", () => probeRentPrices(ctx))),
  );
  outcomes.push(
    ...(await runCheck("probe-resolution", () => probeResolution(ctx))),
  );

  const safeHead = head - ctx.config.confirmations;
  const lastProcessed = BigInt(ctx.state.lastProcessedBlock);
  let scanStart: bigint | null = null;
  if (opts.scanFromBlock !== undefined) {
    scanStart = opts.scanFromBlock;
  } else if (lastProcessed > 0n) {
    scanStart = lastProcessed + 1n;
  }
  if (scanStart !== null && scanStart <= safeHead) {
    const eventOutcomes = await runCheck("event-scan", () =>
      scanEvents(ctx, scanStart as bigint, safeHead),
    );
    outcomes.push(...eventOutcomes);
    const scanFailed = eventOutcomes.some(
      (outcome) => outcome.id === "event-scan" && !outcome.ok,
    );
    if (!scanFailed) ctx.state.lastProcessedBlock = safeHead.toString();
  } else if (lastProcessed === 0n) {
    // First run: begin incremental scanning from the current safe head.
    ctx.state.lastProcessedBlock = safeHead.toString();
    outcomes.push(
      ok(
        "event-scan",
        `event scanning initialized at block ${safeHead}; use --from-block to backfill`,
      ),
    );
  }

  outcomes.push(
    ...(await runCheck("graveyard-clear-lag", () => checkGraveyardLag(ctx))),
  );
  outcomes.push(...checkRenewalLiveness(ctx));

  const critical = outcomes.filter(
    (outcome) => !outcome.ok && outcome.severity === "critical",
  ).length;
  const warning = outcomes.filter(
    (outcome) => !outcome.ok && outcome.severity === "warning",
  ).length;
  ctx.state.lastTick = {
    at: Date.now(),
    block: ctx.state.lastProcessedBlock,
    critical,
    warning,
    checks: outcomes.length,
  };

  await dispatchOutcomes(ctx, outcomes);
  saveState(ctx.config.workDir, ctx.state);

  if (critical === 0 && ctx.config.heartbeatUrl) {
    try {
      await fetch(ctx.config.heartbeatUrl, {
        signal: AbortSignal.timeout(10_000),
      });
    } catch (error) {
      console.error(gray(`heartbeat ping failed: ${errorMessage(error)}`));
    }
  }

  return outcomes;
}

function printReport(outcomes: CheckOutcome[]): void {
  console.log(bold("\n─── monitor report ───"));
  for (const outcome of outcomes) {
    const badge = outcome.ok
      ? green("ok  ")
      : severityColor(outcome.severity, outcome.severity.slice(0, 4));
    console.log(`${badge} ${outcome.id}: ${outcome.summary}`);
    if (!outcome.ok && outcome.details) {
      console.log(gray(`     ${outcome.details.split("\n").join("\n     ")}`));
    }
  }
  const critical = outcomes.filter(
    (outcome) => !outcome.ok && outcome.severity === "critical",
  ).length;
  const warning = outcomes.filter(
    (outcome) => !outcome.ok && outcome.severity === "warning",
  ).length;
  console.log(
    bold(
      `─── ${outcomes.length} checks: ${critical} critical, ${warning} warning ───\n`,
    ),
  );
}

function worstExitCode(outcomes: CheckOutcome[]): number {
  if (outcomes.some((o) => !o.ok && o.severity === "critical")) return 2;
  if (outcomes.some((o) => !o.ok && o.severity === "warning")) return 1;
  return 0;
}

////////////////////////////////////////////////////////////////////////
// Health endpoint
////////////////////////////////////////////////////////////////////////

function startHealthServer(ctx: Ctx, port: number): Server {
  const server = createServer((req, res) => {
    const path = new URL(req.url ?? "/", "http://monitor.local").pathname;
    if (path === "/health") {
      const tick = ctx.state.lastTick;
      const stale = !tick || Date.now() - tick.at > 10 * 60_000;
      const healthy = !stale && tick.critical === 0;
      res.writeHead(healthy ? 200 : 503, { "Content-Type": "text/plain" });
      res.end(
        healthy
          ? "healthy\n"
          : stale
            ? "stale: no recent tick\n"
            : `critical checks failing: ${tick?.critical}\n`,
      );
      return;
    }
    if (path === "/status") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify(
          {
            network: ctx.config.network,
            chainId: ctx.config.chain.id,
            lastTick: ctx.state.lastTick,
            lastProcessedBlock: ctx.state.lastProcessedBlock,
            renewalWatermarks: ctx.state.renewalWatermarks,
            graveyardPending: ctx.state.graveyardPending.length,
            failing: Object.entries(ctx.state.alertHistory)
              .filter(([, entry]) => entry.failing)
              .map(([id]) => id),
          },
          null,
          2,
        ),
      );
      return;
    }
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("not found\n");
  });
  server.listen(port, "0.0.0.0", () => {
    console.log(`health endpoint listening on :${port} (/health, /status)`);
  });
  return server;
}

////////////////////////////////////////////////////////////////////////
// CLI
////////////////////////////////////////////////////////////////////////

type CommonCliOptions = {
  network: string;
  rpcUrl?: string[];
  deploymentsDir: string;
  deploymentNetwork?: string;
  v1DeploymentsDir?: string;
  v1DeploymentNetwork?: string;
  workDir?: string;
  confirmations: string;
  maxLogSpan: string;
  names?: string;
  paymentToken?: string[];
  renewalStaleHours?: string;
  graveyardLagHours: string;
  webhookUrl?: string;
  heartbeatUrl?: string;
  alertCooldownHours: string;
  topUrp?: string;
  v1BaseRegistrar?: string;
  v1Registry?: string;
  v1NameWrapper?: string;
};

async function buildContext(options: CommonCliOptions): Promise<Ctx> {
  const network = options.network as MonitorNetwork;
  if (!NETWORKS[network]) {
    throw new Error(`Unsupported network: ${options.network}`);
  }
  const networkConfig = NETWORKS[network];

  const rpcUrls =
    options.rpcUrl && options.rpcUrl.length > 0
      ? options.rpcUrl
      : (process.env[networkConfig.rpcEnv] ?? "")
          .split(",")
          .map((url) => url.trim())
          .filter(Boolean);
  if (rpcUrls.length === 0) {
    throw new Error(
      `No RPC URL: pass --rpc-url or set ${networkConfig.rpcEnv} (comma-separate multiple providers)`,
    );
  }

  const overrides: Partial<Record<string, Address>> = {};
  if (options.topUrp) overrides.topUrp = getAddress(options.topUrp);
  if (options.v1BaseRegistrar)
    overrides.v1BaseRegistrar = getAddress(options.v1BaseRegistrar);
  if (options.v1Registry) overrides.v1Registry = getAddress(options.v1Registry);
  if (options.v1NameWrapper)
    overrides.v1NameWrapper = getAddress(options.v1NameWrapper);

  const deploymentNetwork = options.deploymentNetwork ?? network;
  const addrs = loadAddressBook(
    {
      network,
      deploymentsDir: options.deploymentsDir,
      deploymentNetwork,
      v1DeploymentsDir: options.v1DeploymentsDir,
      v1DeploymentNetwork: options.v1DeploymentNetwork,
    },
    overrides,
  );

  const config: MonitorConfig = {
    network,
    chain: networkConfig.chain,
    rpcUrls,
    workDir: resolve(options.workDir ?? `.dev/monitor-${network}`),
    confirmations: BigInt(options.confirmations),
    maxLogSpan: BigInt(options.maxLogSpan),
    names: options.names
      ? options.names
          .split(",")
          .map((name) => name.trim())
          .filter(Boolean)
      : networkConfig.defaultNames,
    paymentTokens:
      options.paymentToken && options.paymentToken.length > 0
        ? options.paymentToken.map((token) => getAddress(token))
        : networkConfig.defaultPaymentTokens,
    renewalStaleHours:
      options.renewalStaleHours !== undefined
        ? Number(options.renewalStaleHours)
        : networkConfig.defaultRenewalStaleHours,
    graveyardLagHours: Number(options.graveyardLagHours),
    graveyardPendingMax: 5000,
    webhookUrl: options.webhookUrl ?? process.env.MONITOR_WEBHOOK_URL,
    heartbeatUrl: options.heartbeatUrl ?? process.env.MONITOR_HEARTBEAT_URL,
    alertCooldownHours: Number(options.alertCooldownHours),
    deploymentsDir: options.deploymentsDir,
    deploymentNetwork,
  };

  const clients = rpcUrls.map((url) =>
    createPublicClient({
      chain: networkConfig.chain,
      transport: http(url, { retryCount: 2, timeout: 30_000 }),
    }),
  );

  const chainId = await clients[0].getChainId();
  if (chainId !== networkConfig.chain.id) {
    throw new Error(
      `RPC ${rpcUrls[0]} reports chain ${chainId}, expected ${networkConfig.chain.id} for ${network}`,
    );
  }

  const state = loadState(config.workDir, network, networkConfig.chain.id);
  return { config, addrs, clients, state };
}

function addCommonOptions(command: Command): Command {
  return command
    .requiredOption("--network <network>", "sepolia or mainnet")
    .option(
      "--rpc-url <url...>",
      "RPC endpoint(s); repeat for redundancy (falls back to SEPOLIA_RPC_URL / MAINNET_RPC_URL, comma-separated)",
    )
    .option(
      "--deployments-dir <path>",
      "v2 deployment artifacts root",
      DEFAULT_DEPLOYMENTS_DIR,
    )
    .option(
      "--deployment-network <name>",
      "v2 deployment namespace (defaults to --network)",
    )
    .option("--v1-deployments-dir <path>", "v1 deployment artifacts root")
    .option(
      "--v1-deployment-network <name>",
      "v1 deployment namespace (defaults to --network)",
    )
    .option(
      "--work-dir <path>",
      "state directory (default .dev/monitor-<network>)",
    )
    .option("--confirmations <n>", "blocks behind head to scan", "5")
    .option("--max-log-span <n>", "max blocks per eth_getLogs request", "2000")
    .option(
      "--names <names>",
      "comma-separated canary names for resolution probes",
    )
    .option(
      "--payment-token <address...>",
      "payment token candidates for pricing probes (default: network USDC)",
    )
    .option(
      "--renewal-stale-hours <n>",
      "alert when no renewal observed for this long; 0 disables (default: 6 mainnet, 0 sepolia)",
    )
    .option(
      "--graveyard-lag-hours <n>",
      "acceptable v1-cleanup lag for migrated names",
      "24",
    )
    .option(
      "--webhook-url <url>",
      "POST alerts as JSON to this URL (or MONITOR_WEBHOOK_URL)",
    )
    .option(
      "--heartbeat-url <url>",
      "GET this URL after each healthy tick — dead man's switch (or MONITOR_HEARTBEAT_URL)",
    )
    .option(
      "--alert-cooldown-hours <n>",
      "re-alert interval while failing",
      "6",
    )
    .option("--top-urp <address>", "top Universal Resolver proxy override")
    .option("--v1-base-registrar <address>", "v1 BaseRegistrar override")
    .option("--v1-registry <address>", "v1 ENS registry override")
    .option("--v1-name-wrapper <address>", "v1 NameWrapper override");
}

export async function main(argv = process.argv): Promise<void> {
  loadDotEnv(resolve(CONTRACTS_DIR, ".env"));

  const program = new Command()
    .name("monitor")
    .description("ENS v1→v2 post-migration monitor (read-only)");

  addCommonOptions(
    program
      .command("check")
      .description(
        "run every check once and exit (0 ok, 1 warning, 2 critical)",
      ),
  )
    .option("--from-block <n>", "backfill event scanning from this block")
    .option("--deep", "also run the heavy audits via the migration CLI")
    .option(
      "--csv-file <path>",
      "with --deep: re-verify pre-migration against this registration CSV",
    )
    .option("--json", "print results as JSON instead of a report")
    .action(async (options) => {
      const ctx = await buildContext(options);
      const outcomes = await runTick(ctx, {
        scanFromBlock:
          options.fromBlock !== undefined
            ? BigInt(options.fromBlock)
            : undefined,
      });
      if (options.deep) {
        const deepOutcomes = runDeepAudits(ctx, options.csvFile);
        outcomes.push(...deepOutcomes);
        await dispatchOutcomes(ctx, deepOutcomes);
        saveState(ctx.config.workDir, ctx.state);
      }
      if (options.json) {
        console.log(JSON.stringify(outcomes, null, 2));
      } else {
        printReport(outcomes);
      }
      process.exit(worstExitCode(outcomes));
    });

  addCommonOptions(
    program
      .command("watch")
      .description("run continuously: checks + event scanning + alerting"),
  )
    .option("--interval <seconds>", "seconds between ticks", "60")
    .option("--from-block <n>", "backfill event scanning from this block")
    .option("--port <port>", "serve /health and /status on this port")
    .action(async (options) => {
      const ctx = await buildContext(options);
      const interval = Number(options.interval) * 1000;
      let server: Server | null = null;
      if (options.port) server = startHealthServer(ctx, Number(options.port));
      const shutdown = () => {
        console.log("shutting down");
        server?.close();
        process.exit(0);
      };
      process.on("SIGINT", shutdown);
      process.on("SIGTERM", shutdown);

      console.log(
        bold(
          `monitoring ${ctx.config.network} every ${options.interval}s with ${ctx.config.rpcUrls.length} provider(s)`,
        ),
      );
      let firstTick = true;
      for (;;) {
        const startedAt = Date.now();
        try {
          const outcomes = await runTick(ctx, {
            scanFromBlock:
              firstTick && options.fromBlock !== undefined
                ? BigInt(options.fromBlock)
                : undefined,
          });
          const critical = outcomes.filter(
            (o) => !o.ok && o.severity === "critical",
          ).length;
          const warning = outcomes.filter(
            (o) => !o.ok && o.severity === "warning",
          ).length;
          const status =
            critical > 0
              ? red(`${critical} critical`)
              : warning > 0
                ? yellow(`${warning} warning`)
                : green("all ok");
          console.log(
            gray(
              `${new Date().toISOString()} tick: ${outcomes.length} checks, `,
            ) +
              status +
              gray(` (block ${ctx.state.lastProcessedBlock})`),
          );
        } catch (error) {
          console.error(red(`tick failed: ${errorMessage(error)}`));
        }
        firstTick = false;
        const elapsed = Date.now() - startedAt;
        await new Promise((resolveSleep) =>
          setTimeout(resolveSleep, Math.max(1000, interval - elapsed)),
        );
      }
    });

  program
    .command("status")
    .description("print the persisted monitor state")
    .option(
      "--work-dir <path>",
      "state directory (default .dev/monitor-<network>)",
    )
    .requiredOption("--network <network>", "sepolia or mainnet")
    .action((options) => {
      const workDir = resolve(
        options.workDir ?? `.dev/monitor-${options.network}`,
      );
      const path = statePath(workDir);
      if (!existsSync(path)) {
        console.log(`no state at ${path}`);
        return;
      }
      console.log(readFileSync(path, "utf8"));
    });

  await program.parseAsync(argv);
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
