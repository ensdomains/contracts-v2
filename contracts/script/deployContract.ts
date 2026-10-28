#!/usr/bin/env bun
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";
import { Command } from "commander";
import {
  encodeDeployData,
  formatEther,
  getAddress,
  type Abi,
  type AbiParameter,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { AccountDefinition, UserConfig } from "rocketh/types";
import { loadEnvironmentFromFilesWithConfig } from "../rocketh/environment.js";
import { envPrivateKey } from "./migrations/plumbing.js";
import {
  httpRpcProvider,
  isLocalRpcUrl,
  privateKeySignerProtocol,
} from "./migrations/rpc.js";
import { createV2Clients } from "./scriptUtils.js";

// Deploys one contract from the Hardhat build to any chain, outside the migration
// flow. The contract is recorded in the deploy tool's format, build info included,
// so the verify script can submit it like any other deployment.

const contractsDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const typedArtifactsDir = join(contractsDir, "generated", "artifacts");
const buildArtifactsDir = join(contractsDir, "artifacts");
export const DEFAULT_DEPLOYMENTS_DIR = join(contractsDir, "deployments");

type DeployableArtifact = { abi: Abi; bytecode: Hex; sourceName?: string };

/// Splits `path/File.sol:Name` into its source path and contract name; a bare
/// name has no source path.
function splitContract(contract: string) {
  const separator = contract.lastIndexOf(":");
  return separator === -1
    ? { name: contract }
    : {
        sourceName: contract.slice(0, separator),
        name: contract.slice(separator + 1),
      };
}

/// Relative paths of the files named `fileName` anywhere under `dir`.
function findFiles(dir: string, fileName: string): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { recursive: true, encoding: "utf8" }).filter(
    (path) => basename(path) === fileName,
  );
}

async function loadTypedArtifact(
  artifactPath: string,
  name: string,
): Promise<DeployableArtifact | undefined> {
  const modulePath = join(typedArtifactsDir, `${artifactPath}.ts`);
  if (!existsSync(modulePath)) return undefined;
  return (await import(modulePath))[`Artifact_${name}`];
}

/// Loads the typed build artifact of a contract named by its bare name, or by
/// `path/File.sol:Name` when the name is not unique. The artifact generator writes
/// a contract with a unique name at the top level and any other under its source
/// path, and writes none for a contract without bytecode.
export async function resolveArtifact(
  contract: string,
): Promise<DeployableArtifact> {
  const { sourceName, name } = splitContract(contract);
  const artifact = sourceName
    ? ((await loadTypedArtifact(`${sourceName}/${name}`, name)) ??
      (await loadTypedArtifact(name, name).then((unique) =>
        unique?.sourceName === sourceName ? unique : undefined,
      )))
    : await loadTypedArtifact(name, name);
  if (artifact) return artifact;

  const candidates = findFiles(typedArtifactsDir, `${name}.ts`).map((path) =>
    path.slice(0, -".ts".length).replace(/\/(?=[^/]+$)/, ":"),
  );
  if (candidates.length > 0) {
    throw new Error(
      `no contract at "${contract}"; name one of: ${candidates.join(", ")}`,
    );
  }
  if (findFiles(buildArtifactsDir, `${name}.json`).length > 0) {
    throw new Error(
      `"${contract}" has no bytecode to deploy: it is an interface or an abstract contract`,
    );
  }
  throw new Error(
    `no contract named "${contract}" in the build; run \`bun run compile\` first`,
  );
}

function describeParam(param: AbiParameter): string {
  return param.name ? `${param.type} ${param.name}` : param.type;
}

/// Converts one JSON value to the form the ABI encoder takes for `param`: integers
/// to bigints, and arrays and tuples element by element. Address, bytes and string
/// values pass through for the encoder to check.
function coerceValue(param: AbiParameter, value: unknown): unknown {
  const fail = (expected: string): never => {
    throw new Error(
      `${describeParam(param)}: expected ${expected}, got ${JSON.stringify(value)}`,
    );
  };
  const array = /^(.*)\[\d*\]$/.exec(param.type);
  if (array) {
    if (!Array.isArray(value)) return fail("an array");
    const element = { ...param, type: array[1] } as AbiParameter;
    return value.map((item) => coerceValue(element, item));
  }
  if (param.type === "tuple") {
    const { components } = param as { components: readonly AbiParameter[] };
    if (Array.isArray(value)) {
      if (value.length !== components.length) {
        return fail(`${components.length} tuple fields`);
      }
      return components.map((component, i) => coerceValue(component, value[i]));
    }
    if (value === null || typeof value !== "object") {
      return fail("an array or an object of tuple fields");
    }
    const fields = value as Record<string, unknown>;
    return Object.fromEntries(
      components.map((component) => [
        component.name,
        coerceValue(component, fields[component.name ?? ""]),
      ]),
    );
  }
  if (/^u?int\d*$/.test(param.type)) {
    if (typeof value === "number" && !Number.isSafeInteger(value)) {
      return fail("an integer; pass large integers as strings");
    }
    if (typeof value !== "number" && typeof value !== "string") {
      return fail("an integer");
    }
    try {
      return BigInt(value);
    } catch {
      return fail("an integer");
    }
  }
  if (param.type === "bool") {
    if (value === true || value === "true") return true;
    if (value === false || value === "false") return false;
    return fail("a boolean");
  }
  return value;
}

/// Converts JSON constructor arguments to the types the constructor takes.
export function coerceConstructorArgs(
  abi: Abi,
  values: readonly unknown[],
): unknown[] {
  const constructor = abi.find((item) => item.type === "constructor");
  const inputs = constructor?.inputs ?? [];
  if (values.length !== inputs.length) {
    throw new Error(
      `the constructor takes ${inputs.length} argument(s) (${inputs.map(describeParam).join(", ")}), got ${values.length}`,
    );
  }
  return inputs.map((param, i) => coerceValue(param, values[i]));
}

/// Refuses records made on a chain with another genesis block. The deploy tool
/// deletes such a namespace when it loads it, so a wrong RPC would otherwise
/// erase the records.
async function assertRecordsMatchChain(
  namespaceDir: string,
  publicClient: PublicClient,
) {
  const chainFile = join(namespaceDir, ".chain");
  if (!existsSync(chainFile)) return;
  const { genesisHash } = JSON.parse(readFileSync(chainFile, "utf8")) as {
    genesisHash?: string;
  };
  if (!genesisHash) return;
  const genesis = await publicClient.getBlock({ blockNumber: 0n });
  if (genesis.hash?.toLowerCase() !== genesisHash.toLowerCase()) {
    throw new Error(
      `the records in ${namespaceDir} belong to a chain with genesis block ${genesisHash}, but the RPC's genesis block is ${genesis.hash}; use another --deployment-network`,
    );
  }
}

export type DeploySummary = {
  chainId: number;
  contract: string;
  args: readonly unknown[];
  deployer: Address;
  balance: bigint;
  estimatedCost: bigint;
  record?: string;
  existingAddress?: Address;
};

export type DeployContractOptions = {
  contract: string;
  args?: readonly unknown[];
  rpcUrl: string;
  privateKey: Hex;
  namespace: string;
  deploymentsDir?: string;
  /// Record name; the contract name when absent.
  name?: string;
  /// Writes no record and always deploys a new copy when false.
  save?: boolean;
  /// Called before anything is sent; the deploy stops unless it resolves true.
  confirm?: (summary: DeploySummary) => Promise<boolean>;
};

export type DeployContractResult = {
  address: Address;
  transactionHash?: Hex;
  newlyDeployed: boolean;
  /// The address the record named before a deploy replaced it.
  replacedAddress?: Address;
  recordFile?: string;
};

export async function deployContract(
  opts: DeployContractOptions,
): Promise<DeployContractResult | undefined> {
  const artifact = await resolveArtifact(opts.contract);
  const args = coerceConstructorArgs(artifact.abi, opts.args ?? []);
  const save = opts.save ?? true;
  const record = save
    ? (opts.name ?? splitContract(opts.contract).name)
    : undefined;
  const deploymentsDir = resolve(
    opts.deploymentsDir ?? DEFAULT_DEPLOYMENTS_DIR,
  );
  const namespaceDir = join(deploymentsDir, opts.namespace);
  const recordFile = record ? join(namespaceDir, `${record}.json`) : undefined;
  const existingAddress =
    recordFile && existsSync(recordFile)
      ? getAddress(JSON.parse(readFileSync(recordFile, "utf8")).address)
      : undefined;

  const { chain, publicClient } = await createV2Clients({
    rpcUrl: opts.rpcUrl,
  });
  await assertRecordsMatchChain(namespaceDir, publicClient);

  const deployer = privateKeyToAccount(opts.privateKey).address;
  if (opts.confirm) {
    const [balance, gas, fees] = await Promise.all([
      publicClient.getBalance({ address: deployer }),
      publicClient.estimateGas({
        account: deployer,
        data: encodeDeployData({
          abi: artifact.abi,
          bytecode: artifact.bytecode,
          args,
        }),
      }),
      publicClient.estimateFeesPerGas(),
    ]);
    const proceed = await opts.confirm({
      chainId: chain.id,
      contract: opts.contract,
      args,
      deployer,
      balance,
      estimatedCost: gas * (fees.maxFeePerGas ?? fees.gasPrice ?? 0n),
      record,
      existingAddress,
    });
    if (!proceed) return undefined;
  }

  const config: UserConfig<any, any> = {
    deployments: deploymentsDir,
    accounts: {
      deployer: {
        default: `privateKey:${opts.privateKey}` as AccountDefinition,
      },
    },
    signerProtocols: {
      privateKey: privateKeySignerProtocol(opts.rpcUrl, chain),
    },
    chains: { [chain.id]: { info: chain, rpcUrl: opts.rpcUrl } },
    environments: { [opts.namespace]: { chain: chain.id, scripts: [] } },
  };
  const env = await loadEnvironmentFromFilesWithConfig(
    {
      environment: opts.namespace,
      askBeforeProceeding: false,
      saveDeployments: save,
      provider: httpRpcProvider(opts.rpcUrl) as any,
    },
    config,
  );
  // An empty name keeps the deploy tool from looking up or writing a record.
  const deployment = await env.deploy(record ?? "", {
    account: env.namedAccounts.deployer,
    artifact,
    args,
  } as any);

  const address = getAddress(deployment.address);
  return {
    address,
    transactionHash: deployment.transaction?.hash,
    newlyDeployed: deployment.newlyDeployed,
    replacedAddress:
      deployment.newlyDeployed && existingAddress !== address
        ? existingAddress
        : undefined,
    recordFile,
  };
}

function jsonWithBigints(value: unknown): string {
  return JSON.stringify(value, (_, v) =>
    typeof v === "bigint" ? v.toString() : v,
  );
}

async function askToProceed(summary: DeploySummary): Promise<boolean> {
  console.log(`chain:          ${summary.chainId}`);
  console.log(`contract:       ${summary.contract}`);
  console.log(`arguments:      ${jsonWithBigints(summary.args)}`);
  console.log(
    `deployer:       ${summary.deployer} (balance ${formatEther(summary.balance)} ETH)`,
  );
  console.log(
    `estimated cost: up to ${formatEther(summary.estimatedCost)} ETH`,
  );
  if (summary.existingAddress) {
    console.log(
      `record:         "${summary.record}" already names ${summary.existingAddress}; it is reused if the code and arguments match, and replaced otherwise`,
    );
  }
  const prompt = createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  try {
    const answer = await prompt.question("Deploy? [y/N] ");
    return /^y(es)?$/i.test(answer.trim());
  } finally {
    prompt.close();
  }
}

type CliOptions = {
  network: string;
  rpcUrl?: string;
  args: string;
  privateKey?: Hex;
  name?: string;
  deploymentsDir: string;
  deploymentNetwork?: string;
  save: boolean;
  yes: boolean;
};

async function main() {
  const program = new Command()
    .name("deploy:contract")
    .description(
      "Deploy one contract from the Hardhat build to any chain, outside the migration flow",
    )
    .argument(
      "<contract>",
      "contract name, or path/File.sol:Name when the name is not unique",
    )
    .requiredOption(
      "--network <name>",
      "network label; names the RPC env var and the default namespace",
    )
    .option("--rpc-url <url>", "RPC endpoint (default: <NETWORK>_RPC_URL)")
    .option("--args <json>", "constructor arguments as a JSON array", "[]")
    .option(
      "--private-key <hex>",
      "deployer private key (default: DEPLOYER_KEY)",
    )
    .option(
      "--name <record>",
      "deployment record name (default: the contract name)",
    )
    .option(
      "--deployments-dir <path>",
      "root of the deployment records",
      DEFAULT_DEPLOYMENTS_DIR,
    )
    .option(
      "--deployment-network <namespace>",
      "namespace for the record (default: <network>-adhoc)",
    )
    .option("--no-save", "deploy a new copy without writing a record")
    .option("-y, --yes", "skip the confirmation prompt", false);
  program.parse();
  const contract = program.args[0];
  const opts = program.opts<CliOptions>();

  const rpcEnvVar = `${opts.network.toUpperCase().replace(/[^A-Z0-9]/g, "_")}_RPC_URL`;
  const rpcUrl = opts.rpcUrl ?? process.env[rpcEnvVar];
  if (!rpcUrl) throw new Error(`pass --rpc-url or set ${rpcEnvVar}`);
  const privateKey = opts.privateKey ?? envPrivateKey("DEPLOYER_KEY");
  if (!privateKey) throw new Error("pass --private-key or set DEPLOYER_KEY");
  const args = JSON.parse(opts.args);
  if (!Array.isArray(args)) throw new Error("--args must be a JSON array");
  const namespace = opts.deploymentNetwork ?? `${opts.network}-adhoc`;

  // The deploy tool copies build info from the build folder relative to the
  // working directory.
  process.chdir(contractsDir);
  const result = await deployContract({
    contract,
    args,
    rpcUrl,
    privateKey,
    namespace,
    deploymentsDir: opts.deploymentsDir,
    name: opts.name,
    save: opts.save,
    confirm: opts.yes || isLocalRpcUrl(rpcUrl) ? undefined : askToProceed,
  });
  if (!result) {
    console.log("Nothing sent.");
    return;
  }

  if (result.newlyDeployed) {
    console.log(
      `Deployed ${contract} at ${result.address} (tx ${result.transactionHash})`,
    );
    if (result.replacedAddress) {
      console.log(`The record named ${result.replacedAddress} before.`);
    }
  } else {
    console.log(
      `${contract} is already deployed at ${result.address} with this code and these arguments; nothing sent. Pass --name to deploy another copy.`,
    );
  }
  if (result.recordFile) {
    console.log(`record: ${result.recordFile}`);
    if (resolve(opts.deploymentsDir) === DEFAULT_DEPLOYMENTS_DIR) {
      console.log(`verify with: bun run verify --network ${namespace}`);
    }
  }
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
