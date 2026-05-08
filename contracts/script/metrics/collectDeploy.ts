import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { artifacts } from "@rocketh";
import {
  type Abi,
  type Address,
  type Hex,
  parseAbi,
  parseEventLogs,
  toFunctionSelector,
} from "viem";
import { setupDevnet } from "../setup.js";
import {
  DEFAULT_METRICS_DIR,
  normalizeSourcePath,
  projectOnly,
  writeMetricReport,
} from "./collect.js";
import { byteLength, decimal, type GasMetricSample } from "./schema.js";

type Deployment = {
  name: string;
  address: Address;
  artifact?: string;
  sourceName?: string;
};

const OUT_FILE =
  process.env.METRICS_OUTPUT ?? `${DEFAULT_METRICS_DIR}/deploy.json`;
const verifiableFactoryAbi = parseAbi([
  "event ProxyDeployed(address indexed sender, address indexed proxyAddress, uint256 salt, address implementation)",
]);

async function main() {
  delete process.env.COVERAGE;
  process.env.GAS_METRICS ??= "1";
  process.env.METRICS_SUITE ??= "deploy";

  const env = await setupDevnet({
    saveDeployments: true,
    quiet: true,
    procLog: false,
  });

  try {
    const deployments = await collectDeployments(env.rocketh);
    const addressToDeployment = new Map(
      deployments.map((deployment) => [
        deployment.address.toLowerCase(),
        deployment,
      ]),
    );
    const selectorMap = buildSelectorMap();
    const samples: GasMetricSample[] = [];

    samples.push(
      ...(await collectRuntimeSizes(env.client, deployments)),
      ...(await collectTransactions(
        env.client,
        addressToDeployment,
        selectorMap,
      )),
    );

    await writeMetricReport({
      path: OUT_FILE,
      samples,
      suite: "deploy",
    });
    console.log(`Wrote ${OUT_FILE}`);
  } finally {
    await env.shutdown();
  }
}

async function collectRuntimeSizes(
  client: { getCode(args: { address: Address }): Promise<Hex | undefined> },
  deployments: Deployment[],
): Promise<GasMetricSample[]> {
  const samples: GasMetricSample[] = [];
  for (const deployment of deployments) {
    const code = await client.getCode({ address: deployment.address });
    const runtimeBytes = byteLength(code);
    if (runtimeBytes === undefined) continue;
    samples.push({
      kind: "contract-size",
      suite: "deploy",
      phase: "deploy-script-runtime",
      metric: "runtime-bytes",
      unit: "bytes",
      value: decimal(runtimeBytes),
      runtimeBytes: decimal(runtimeBytes),
      contractName: deployment.name,
      address: deployment.address,
      artifact: deployment.artifact,
      project: projectOnly(deployment.sourceName ?? deployment.artifact),
    });
  }
  return samples;
}

async function collectTransactions(
  client: any,
  addressToDeployment: Map<string, Deployment>,
  selectorMap: Map<string, { contractName: string; functionName: string }>,
): Promise<GasMetricSample[]> {
  const samples: GasMetricSample[] = [];
  const latest = await client.getBlockNumber();

  for (let blockNumber = 0n; blockNumber <= latest; blockNumber++) {
    const block = await client.getBlock({
      blockNumber,
      includeTransactions: true,
    });
    for (const tx of block.transactions) {
      const receipt = await client.getTransactionReceipt({ hash: tx.hash });
      if (receipt.status !== "success") continue;
      const deployment = receipt.contractAddress
        ? addressToDeployment.get(receipt.contractAddress.toLowerCase())
        : undefined;
      const calledDeployment = tx.to
        ? addressToDeployment.get(tx.to.toLowerCase())
        : undefined;
      const selector = selectorFromInput(tx.input);
      const decoded = selector ? selectorMap.get(selector) : undefined;

      if (receipt.contractAddress) {
        samples.push({
          kind: "deployment",
          suite: "deploy",
          phase: "deploy-script",
          metric: "deployment-gas",
          unit: "gas",
          gasUsed: decimal(receipt.gasUsed),
          contractName: deployment?.name ?? decoded?.contractName,
          address: receipt.contractAddress,
          artifact: deployment?.artifact,
          transactionHash: receipt.transactionHash,
          project: projectOnly(deployment?.sourceName ?? deployment?.artifact),
          raw: rawTransaction(blockNumber, tx, receipt),
        });
      } else {
        const proxySamples = await collectVerifiableProxySamples({
          client,
          blockNumber,
          tx,
          receipt,
          calledDeployment,
          addressToDeployment,
        });
        if (proxySamples.length) {
          samples.push(...proxySamples);
          continue;
        }

        samples.push({
          kind: "function",
          suite: "deploy",
          phase: "deploy-script-call",
          metric: "function-gas",
          unit: "gas",
          gasUsed: decimal(receipt.gasUsed),
          contractName:
            calledDeployment?.name ??
            decoded?.contractName ??
            tx.to ??
            "unknown",
          address: tx.to ?? undefined,
          artifact: calledDeployment?.artifact,
          transactionHash: receipt.transactionHash,
          functionName: decoded?.functionName,
          selector,
          project: projectOnly(
            calledDeployment?.sourceName ??
              calledDeployment?.artifact ??
              decoded?.contractName,
          ),
          raw: rawTransaction(blockNumber, tx, receipt),
        });
      }
    }
  }

  return samples;
}

async function collectVerifiableProxySamples({
  client,
  blockNumber,
  tx,
  receipt,
  calledDeployment,
  addressToDeployment,
}: {
  client: any;
  blockNumber: bigint;
  tx: any;
  receipt: any;
  calledDeployment?: Deployment;
  addressToDeployment: Map<string, Deployment>;
}): Promise<GasMetricSample[]> {
  if (calledDeployment?.name !== "VerifiableFactory") return [];
  const [log] = parseEventLogs({
    abi: verifiableFactoryAbi,
    eventName: "ProxyDeployed",
    logs: receipt.logs,
  });
  if (!log) return [];

  const proxyAddress = log.args.proxyAddress;
  const implementation = log.args.implementation;
  const implementationDeployment = addressToDeployment.get(
    implementation.toLowerCase(),
  );
  const contractName = proxyContractName(implementationDeployment);
  const raw = {
    ...rawTransaction(blockNumber, tx, receipt),
    factoryAddress: tx.to,
    implementation,
    implementationName: implementationDeployment?.name,
    proxyAddress,
    salt: decimal(log.args.salt),
  };

  const samples: GasMetricSample[] = [
    {
      kind: "deployment",
      suite: "deploy",
      phase: "deploy-script",
      metric: "proxy-deployment-gas",
      unit: "gas",
      gasUsed: decimal(receipt.gasUsed),
      contractName,
      address: proxyAddress,
      transactionHash: receipt.transactionHash,
      functionName: "deployProxy",
      project: projectOnly(
        implementationDeployment?.sourceName ??
          implementationDeployment?.artifact,
      ),
      raw,
    },
  ];

  const code = await client.getCode({ address: proxyAddress });
  const runtimeBytes = byteLength(code);
  if (runtimeBytes !== undefined) {
    samples.push({
      kind: "contract-size",
      suite: "deploy",
      phase: "deploy-script-runtime",
      metric: "runtime-bytes",
      unit: "bytes",
      value: decimal(runtimeBytes),
      runtimeBytes: decimal(runtimeBytes),
      contractName,
      address: proxyAddress,
      project: projectOnly(
        implementationDeployment?.sourceName ??
          implementationDeployment?.artifact,
      ),
      raw,
    });
  }

  return samples;
}

function proxyContractName(implementation?: Deployment): string {
  if (!implementation?.name) return "VerifiableProxy";
  return `${implementation.name.replace(/Impl$/, "")}Proxy`;
}

async function collectDeployments(rocketh: any): Promise<Deployment[]> {
  const byAddress = new Map<string, Deployment>();

  for (const [name, deployment] of deploymentEntries(rocketh)) {
    if (!deployment?.address) continue;
    byAddress.set(deployment.address.toLowerCase(), {
      name,
      address: deployment.address,
      artifact: deployment.artifact ?? deployment.linkedData?.artifact,
      sourceName: normalizeOptionalSourceName(
        deployment.sourceName ??
          deployment.inputSourceName ??
          deployment.linkedData?.sourceName,
      ),
    });
  }

  for (const deployment of await deploymentFileEntries("deployments")) {
    byAddress.set(deployment.address.toLowerCase(), deployment);
  }

  return Array.from(byAddress.values()).sort((a, b) =>
    a.name.localeCompare(b.name),
  );
}

function deploymentEntries(rocketh: any): [string, any][] {
  const deployments = rocketh?.deployments;
  if (!deployments) return [];
  if (deployments instanceof Map) return Array.from(deployments.entries());
  return Object.entries(deployments);
}

async function deploymentFileEntries(root: string): Promise<Deployment[]> {
  try {
    const files = await findJsonFiles(root);
    const deployments: Deployment[] = [];
    for (const file of files) {
      const value = JSON.parse(await readFile(file, "utf8")) as {
        address?: Address;
        artifact?: string;
        name?: string;
        sourceName?: string;
        inputSourceName?: string;
      };
      if (!value.address) continue;
      deployments.push({
        name:
          value.name ??
          file.replace(/^deployments\/[^/]+\//, "").replace(/\.json$/, ""),
        address: value.address,
        artifact: value.artifact,
        sourceName: normalizeOptionalSourceName(
          value.sourceName ?? value.inputSourceName,
        ),
      });
    }
    return deployments;
  } catch {
    return [];
  }
}

function normalizeOptionalSourceName(sourceName: string | undefined) {
  return sourceName ? normalizeSourcePath(sourceName) : undefined;
}

async function findJsonFiles(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true });
  const nested = await Promise.all(
    entries.map(async (entry) => {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) return findJsonFiles(path);
      if (entry.isFile() && entry.name.endsWith(".json")) return [path];
      return [];
    }),
  );
  return nested.flat();
}

function buildSelectorMap() {
  const selectors = new Map<
    string,
    { contractName: string; functionName: string }
  >();
  for (const [artifactName, artifact] of Object.entries(artifacts) as [
    string,
    { abi?: Abi },
  ][]) {
    const contractName = artifactName.split("/").pop() ?? artifactName;
    for (const item of artifact.abi ?? []) {
      if (item.type !== "function") continue;
      selectors.set(toFunctionSelector(item), {
        contractName,
        functionName: item.name,
      });
    }
  }
  return selectors;
}

function selectorFromInput(input: Hex | undefined): Hex | undefined {
  if (!input || input.length < 10) return undefined;
  return input.slice(0, 10) as Hex;
}

function rawTransaction(blockNumber: bigint, tx: any, receipt: any) {
  return {
    blockNumber: decimal(blockNumber),
    transactionIndex: Number(receipt.transactionIndex),
    from: tx.from,
    to: tx.to,
    input: tx.input,
  };
}

if (import.meta.main) {
  await main();
}
