import {
  type Abi,
  type Hex,
  toFunctionSelector,
  type TransactionReceipt,
} from "viem";
import { writeMetricReport } from "../../script/metrics/collect.js";
import {
  decimal,
  type GasMetricSample,
  type MetricKind,
} from "../../script/metrics/schema.js";

type TestContext = {
  suite: string;
  phase: string;
  testName: string;
  gasUsed: bigint;
};

type ReceiptLike = Pick<
  TransactionReceipt,
  "contractAddress" | "gasUsed" | "status" | "to" | "transactionHash"
>;

type RecordReceiptOptions = {
  receipt: ReceiptLike;
  suite?: string;
  phase?: string;
  kind?: MetricKind;
  metric?: string;
  replace?: boolean;
  testName?: string;
  contractName?: string;
  address?: Hex;
  artifact?: string;
  functionName?: string;
  selector?: Hex;
  input?: Hex;
  project?: boolean;
  raw?: Record<string, unknown>;
};

type ContractWritePromise = Promise<Hex> & {
  __call_metadata?: unknown;
};

const samples: GasMetricSample[] = [];
const sampleByTransaction = new Map<string, number>();
let current: TestContext | undefined;
let selectorCache:
  | Promise<Map<string, { contractName: string; name: string }>>
  | undefined;

export function gasMetricsEnabled(): boolean {
  return process.env.GAS_METRICS === "1";
}

export function startTest(
  testName: string,
  {
    suite = process.env.METRICS_SUITE ?? "hardhat",
    phase = `${suite}-test`,
  }: { suite?: string; phase?: string } = {},
) {
  if (!gasMetricsEnabled()) return;
  current = { suite, phase, testName, gasUsed: 0n };
}

export function endTest() {
  if (!gasMetricsEnabled() || !current) return;
  if (current.gasUsed > 0n) {
    samples.push({
      kind: "test-total",
      suite: current.suite,
      phase: current.phase,
      metric: "test-total-gas",
      unit: "gas",
      gasUsed: decimal(current.gasUsed),
      testName: current.testName,
      project: true,
    });
  }
  current = undefined;
}

export async function recordReceipt({
  receipt,
  suite = current?.suite ?? process.env.METRICS_SUITE ?? "hardhat",
  phase = current?.phase ?? `${suite}-call`,
  kind,
  metric,
  replace = false,
  testName = current?.testName,
  contractName,
  address,
  artifact,
  functionName,
  selector,
  input,
  project = true,
  raw,
}: RecordReceiptOptions) {
  if (!gasMetricsEnabled()) return;
  if (receipt.status !== "success") return;

  const transactionHash = receipt.transactionHash;
  const existingSampleIndex = sampleByTransaction.get(transactionHash);
  if (existingSampleIndex !== undefined && !replace) return;

  const gasUsed = BigInt(receipt.gasUsed);
  if (current && existingSampleIndex === undefined) current.gasUsed += gasUsed;

  const decoded =
    functionName || selector ? undefined : await decodeFunctionSelector(input);
  const resolvedFunctionName = functionName ?? decoded?.name;
  const resolvedSelector = selector ?? selectorFromInput(input);
  const resolvedContractName = contractName ?? decoded?.contractName;
  const resolvedAddress =
    address ?? receipt.contractAddress ?? receipt.to ?? undefined;
  const resolvedKind =
    kind ?? (receipt.contractAddress ? "deployment" : "function");

  const sample: GasMetricSample = {
    kind: resolvedKind,
    suite,
    phase,
    metric:
      metric ??
      (resolvedKind === "deployment" ? "deployment-gas" : "function-gas"),
    unit: "gas",
    gasUsed: decimal(gasUsed),
    contractName: resolvedContractName,
    address: resolvedAddress ?? undefined,
    artifact,
    transactionHash,
    functionName: resolvedFunctionName,
    selector: resolvedSelector,
    testName,
    project,
    raw,
  };

  if (existingSampleIndex !== undefined) {
    samples[existingSampleIndex] = sample;
    return;
  }

  sampleByTransaction.set(transactionHash, samples.length);
  samples.push(sample);
}

export async function writeMetrics(
  path = process.env.METRICS_OUTPUT ??
    `metrics/${process.env.METRICS_SUITE ?? "hardhat"}.json`,
) {
  if (!gasMetricsEnabled()) return;
  endTest();
  await writeMetricReport({ path, samples });
}

export function injectHardhatGasMetrics(hre: any) {
  if (!gasMetricsEnabled()) return;
  const connect0 = hre.network.connect.bind(hre.network);
  hre.network.connect = async (...parameters: unknown[]) => {
    const connection = await connect0(...parameters);
    return patchHardhatConnection(connection);
  };
}

export function patchContractWrite<T extends object>(
  contract: T,
  {
    suite = current?.suite ?? process.env.METRICS_SUITE ?? "e2e",
    phase,
    contractName,
    project = true,
    waitForReceipt,
  }: {
    suite?: string;
    phase?: string;
    contractName?: string;
    project?: boolean;
    waitForReceipt(hash: Hex): Promise<ReceiptLike>;
  },
): T {
  if (!gasMetricsEnabled() || !("write" in contract)) return contract;
  const write0 = contract.write as Record<
    string,
    (...parameters: unknown[]) => Promise<Hex>
  >;
  contract.write = new Proxy(
    {},
    {
      get(_, functionName: string) {
        return (...parameters: unknown[]) => {
          const result = write0[functionName](
            ...parameters,
          ) as ContractWritePromise;
          const callPhase = phase ?? current?.phase ?? `${suite}-call`;
          const testName = current?.testName;
          const tracked = result.then(async (hash) => {
            await recordReceipt({
              receipt: await waitForReceipt(hash),
              suite,
              phase: callPhase,
              testName,
              contractName,
              address: (contract as { address?: Hex }).address,
              functionName,
              project,
            });
            return hash;
          }) as ContractWritePromise;
          tracked.__call_metadata = result.__call_metadata;
          return tracked;
        };
      },
    },
  );
  return contract;
}

async function patchHardhatConnection(connection: any) {
  if (connection.__gasMetricsPatched) return connection;
  connection.__gasMetricsPatched = true;

  const viem = connection.viem;
  const getPublicClient0 = viem.getPublicClient.bind(viem);
  let publicClientPromise: Promise<any> | undefined;
  const getPublicClient = () => (publicClientPromise ??= getPublicClient0());

  if (typeof viem.getWalletClient === "function") {
    const getWalletClient0 = viem.getWalletClient.bind(viem);
    viem.getWalletClient = async (...parameters: unknown[]) =>
      patchWalletClient(await getWalletClient0(...parameters), getPublicClient);
  }

  if (typeof viem.getWalletClients === "function") {
    const getWalletClients0 = viem.getWalletClients.bind(viem);
    viem.getWalletClients = async (...parameters: unknown[]) =>
      (await getWalletClients0(...parameters)).map((client: any) =>
        patchWalletClient(client, getPublicClient),
      );
  }

  if (typeof viem.getContractAt === "function") {
    const getContractAt0 = viem.getContractAt.bind(viem);
    viem.getContractAt = async (name: string, ...parameters: unknown[]) =>
      patchHardhatContract(
        await getContractAt0(name, ...parameters),
        name,
        getPublicClient,
      );
  }

  if (typeof viem.deployContract === "function") {
    const deployContract0 = viem.deployContract.bind(viem);
    viem.deployContract = async (name: string, ...parameters: unknown[]) => {
      const contract = await deployContract0(name, ...parameters);
      await recordDeploymentFromContract(contract, name, getPublicClient);
      return patchHardhatContract(contract, name, getPublicClient);
    };
  }

  return connection;
}

function patchWalletClient(client: any, getPublicClient: () => Promise<any>) {
  if (client.__gasMetricsPatched) return client;
  client.__gasMetricsPatched = true;

  if (typeof client.writeContract === "function") {
    const writeContract0 = client.writeContract.bind(client);
    client.writeContract = async (parameters: {
      address?: Hex;
      functionName?: string;
      data?: Hex;
      [key: string]: unknown;
    }) => {
      const hash = await writeContract0(parameters);
      await recordReceipt({
        receipt: await waitForReceipt(getPublicClient, hash),
        phase: current?.phase ?? "hardhat-call",
        address: parameters.address,
        functionName: parameters.functionName,
        input: parameters.data,
      });
      return hash;
    };
  }

  if (typeof client.deployContract === "function") {
    const deployContract0 = client.deployContract.bind(client);
    client.deployContract = async (parameters: {
      abi?: Abi;
      bytecode?: Hex;
      [key: string]: unknown;
    }) => {
      const hash = await deployContract0(parameters);
      await recordReceipt({
        receipt: await waitForReceipt(getPublicClient, hash),
        phase: current?.phase ?? "hardhat-deploy",
      });
      return hash;
    };
  }

  return client;
}

function patchHardhatContract(
  contract: any,
  contractName: string,
  getPublicClient: () => Promise<any>,
) {
  return patchContractWrite(contract, {
    suite: process.env.METRICS_SUITE ?? "hardhat",
    phase: current?.phase ?? "hardhat-call",
    contractName,
    waitForReceipt: (hash) => waitForReceipt(getPublicClient, hash),
  });
}

async function recordDeploymentFromContract(
  contract: any,
  contractName: string,
  getPublicClient: () => Promise<any>,
) {
  const hash =
    contract.deploymentTransactionHash ??
    contract.deploymentTransaction?.hash ??
    contract.deploymentHash;
  const receipt = hash
    ? await waitForReceipt(getPublicClient, hash)
    : await findDeploymentReceipt(getPublicClient, contract.address);
  if (!receipt) return;
  await recordReceipt({
    receipt,
    phase: current?.phase ?? "hardhat-deploy",
    contractName,
    address: contract.address,
  });
}

async function waitForReceipt(
  getPublicClient: () => Promise<any>,
  hash: Hex,
): Promise<ReceiptLike> {
  const publicClient = await getPublicClient();
  return publicClient.waitForTransactionReceipt({ hash });
}

async function findDeploymentReceipt(
  getPublicClient: () => Promise<any>,
  address: Hex | undefined,
): Promise<ReceiptLike | undefined> {
  if (!address) return undefined;
  const publicClient = await getPublicClient();
  const latest = await publicClient.getBlockNumber();
  const lowerBound = latest > 20n ? latest - 20n : 0n;
  for (let blockNumber = latest; blockNumber >= lowerBound; blockNumber--) {
    const block = await publicClient.getBlock({
      blockNumber,
      includeTransactions: true,
    });
    for (const tx of block.transactions) {
      const receipt = await publicClient.getTransactionReceipt({
        hash: tx.hash,
      });
      if (receipt.contractAddress?.toLowerCase() === address.toLowerCase()) {
        return receipt;
      }
    }
    if (blockNumber === 0n) break;
  }
  return undefined;
}

function selectorFromInput(input: Hex | undefined): Hex | undefined {
  if (!input || input.length < 10) return undefined;
  return input.slice(0, 10) as Hex;
}

async function decodeFunctionSelector(input: Hex | undefined) {
  const selector = selectorFromInput(input);
  if (!selector) return undefined;
  const selectors = await loadFunctionSelectors();
  return selectors.get(selector);
}

async function loadFunctionSelectors() {
  if (selectorCache) return selectorCache;
  selectorCache = (async () => {
    const selectors = new Map<string, { contractName: string; name: string }>();
    try {
      const generated = (await import("../../generated/artifacts.ts")) as {
        default: Record<string, { abi?: Abi }>;
      };
      for (const [artifactName, artifact] of Object.entries(
        generated.default,
      )) {
        const contractName = artifactName.split("/").pop() ?? artifactName;
        for (const item of artifact.abi ?? []) {
          if (item.type !== "function") continue;
          selectors.set(toFunctionSelector(item), {
            contractName,
            name: item.name,
          });
        }
      }
    } catch {
      return selectors;
    }
    return selectors;
  })();
  return selectorCache;
}
