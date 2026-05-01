import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type Address, type Hex, parseUnits, zeroAddress } from "viem";

import type { DevnetEnvironment } from "../../script/setup.js";

const MOCKESTRATOR_IMAGE =
  process.env.MOCKESTRATOR_IMAGE ?? "ghcr.io/ensdomains/mockestrator:latest";
const MOCKESTRATOR_RELAYER_ADDRESS =
  "0x1aF50037fFD325FBC96A2BEFCf4b0d13c94Df0e8";
const MOCKESTRATOR_RELAYER_KEY =
  "0x6666e779ddc6eb78f59372f7d4d2ea2179f9d28eeb7071405e3c874653fbc335";
const MOCKESTRATOR_ROUTER_ADDRESS =
  "0x8a525dc484f893ca64fef507746ebd5036eec256";
const MOCKESTRATOR_SIGNATURE = `0x${"11".repeat(65)}` as Hex;
const MOCKESTRATOR_API_KEY = "test-api-key";
const MOCKESTRATOR_READY_TIMEOUT_MS = 30_000;
const MOCKESTRATOR_OPERATION_TIMEOUT_MS = 45_000;
const MOCKESTRATOR_POLL_INTERVAL_MS = 250;
const MOCKESTRATOR_FAILURE_STATUSES = new Set([
  "FAILED",
  "REVERTED",
  "EXPIRED",
  "CANCELLED",
  "ERROR",
]);

export type Mockestrator = {
  url: string;
  stop(): Promise<void>;
};

export type MockestratorExecution = {
  to: Address;
  data: Hex;
  value?: bigint;
};

export type MockestratorStatus = {
  status: string;
  fillTransactionHash: Hex;
};

type MockestratorOperationStatus = {
  status: string;
  fillTransactionHash?: unknown;
};

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isTransactionHash(value: unknown): value is Hex {
  return typeof value === "string" && /^0x[0-9a-fA-F]{64}$/.test(value);
}

async function getFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close();
        reject(new Error("Unable to allocate mockestrator port"));
        return;
      }
      const { port } = address;
      server.close((error) => {
        if (error) reject(error);
        else resolve(port);
      });
    });
  });
}

async function waitForMockestrator(
  url: string,
  mockestratorProcess: ChildProcessWithoutNullStreams,
): Promise<void> {
  const startedAt = Date.now();
  let lastError: unknown;
  while (Date.now() - startedAt < MOCKESTRATOR_READY_TIMEOUT_MS) {
    if (mockestratorProcess.exitCode !== null) {
      throw new Error(
        `mockestrator exited with code ${mockestratorProcess.exitCode}`,
      );
    }
    try {
      const response = await fetch(`${url}/chains`, {
        headers: { "x-api-key": MOCKESTRATOR_API_KEY },
      });
      if (response.ok) return;
      lastError = new Error(await response.text());
    } catch (error) {
      lastError = error;
    }
    await sleep(MOCKESTRATOR_POLL_INTERVAL_MS);
  }
  throw new Error(`mockestrator did not become ready: ${lastError}`);
}

async function mockestratorCall<T>({
  mockestrator,
  method,
  path,
  body,
}: {
  mockestrator: Mockestrator;
  method: "GET" | "POST";
  path: string;
  body?: unknown;
}): Promise<T> {
  const response = await fetch(`${mockestrator.url}${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      "x-api-key": MOCKESTRATOR_API_KEY,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) {
    throw new Error(`mockestrator ${path} failed: ${await response.text()}`);
  }
  return response.json() as Promise<T>;
}

async function waitForMockestratorOperation({
  mockestrator,
  id,
}: {
  mockestrator: Mockestrator;
  id: string | number | bigint;
}): Promise<MockestratorStatus> {
  const startedAt = Date.now();
  let lastStatus: MockestratorOperationStatus | undefined;
  while (Date.now() - startedAt < MOCKESTRATOR_OPERATION_TIMEOUT_MS) {
    lastStatus = await mockestratorCall<MockestratorOperationStatus>({
      mockestrator,
      method: "GET",
      path: `/intent-operation/${id}`,
    });

    if (lastStatus.status === "COMPLETED") {
      if (!isTransactionHash(lastStatus.fillTransactionHash)) {
        throw new Error(
          `mockestrator operation ${id} completed without a fill transaction hash`,
        );
      }
      return {
        status: lastStatus.status,
        fillTransactionHash: lastStatus.fillTransactionHash,
      };
    }

    if (MOCKESTRATOR_FAILURE_STATUSES.has(lastStatus.status)) {
      throw new Error(
        `mockestrator operation ${id} failed with status ${lastStatus.status}`,
      );
    }

    await sleep(MOCKESTRATOR_POLL_INTERVAL_MS);
  }

  throw new Error(
    `mockestrator operation ${id} did not complete within ${MOCKESTRATOR_OPERATION_TIMEOUT_MS}ms; last status: ${
      lastStatus?.status ?? "unknown"
    }`,
  );
}

export function createMockestratorUtils(env: DevnetEnvironment) {
  function anvilRpcUrlForContainer(): string {
    const hostPort = new URL(`http://${env.hostPort}`);
    return `http://host.docker.internal:${hostPort.port}`;
  }

  async function startMockestrator(): Promise<Mockestrator> {
    const port = await getFreePort();
    const configDir = await mkdtemp(join(tmpdir(), "hca-mockestrator-"));
    const chainId = env.client.chain.id;
    const files = {
      "rpcs.json": {
        [chainId]: { rpc: anvilRpcUrlForContainer() },
      },
      "chains.json": {
        [chainId]: {
          tokens: {
            ETH: { address: zeroAddress, decimals: 18 },
            MockUSDC: {
              address: env.erc20.MockUSDC.address,
              decimals: 6,
              balanceSlot: 0,
              approvalSlot: 1,
            },
          },
        },
      },
      "config.json": {
        relayerKey: MOCKESTRATOR_RELAYER_KEY,
        relayerAddress: MOCKESTRATOR_RELAYER_ADDRESS,
        routerAddress: MOCKESTRATOR_ROUTER_ADDRESS,
        funding: {
          [MOCKESTRATOR_RELAYER_ADDRESS]: {
            ETH: parseUnits("100", 18).toString(),
          },
        },
      },
      "code.json": {},
    };

    await Promise.all(
      Object.entries(files).map(([name, value]) =>
        writeFile(join(configDir, name), JSON.stringify(value, null, 2)),
      ),
    );

    const mockestratorProcess = spawn("docker", [
      "run",
      "--rm",
      "--add-host=host.docker.internal:host-gateway",
      "-p",
      `127.0.0.1:${port}:3000`,
      "-v",
      `${join(configDir, "rpcs.json")}:/app/rpcs.json:ro`,
      "-v",
      `${join(configDir, "chains.json")}:/app/chains.json:ro`,
      "-v",
      `${join(configDir, "config.json")}:/app/config.json:ro`,
      "-v",
      `${join(configDir, "code.json")}:/app/code.json:ro`,
      MOCKESTRATOR_IMAGE,
    ]);

    let logs = "";
    mockestratorProcess.stdout.on("data", (chunk) => {
      logs += chunk.toString();
    });
    mockestratorProcess.stderr.on("data", (chunk) => {
      logs += chunk.toString();
    });

    const url = `http://127.0.0.1:${port}`;
    try {
      await waitForMockestrator(url, mockestratorProcess);
    } catch (error) {
      mockestratorProcess.kill("SIGTERM");
      await rm(configDir, { recursive: true, force: true });
      throw new Error(`${error}\nmockestrator logs:\n${logs}`);
    }

    return {
      url,
      async stop() {
        mockestratorProcess.kill("SIGTERM");
        await new Promise<void>((resolve) => {
          mockestratorProcess.once("close", () => resolve());
          setTimeout(resolve, 2_000);
        });
        await rm(configDir, { recursive: true, force: true });
      },
    };
  }

  async function executeThroughMockestrator({
    mockestrator,
    hca,
    executions,
  }: {
    mockestrator: Mockestrator;
    hca: Address;
    executions: MockestratorExecution[];
  }): Promise<MockestratorStatus> {
    const route = await mockestratorCall<{
      intentOp: Record<string, unknown>;
    }>({
      mockestrator,
      method: "POST",
      path: "/intents/route",
      body: {
        destinationChainId: env.client.chain.id,
        tokenRequests: [],
        account: { address: hca },
        accountAccessList: { chainIds: [env.client.chain.id] },
        destinationExecutions: executions.map((execution) => ({
          to: execution.to,
          value: (execution.value ?? 0n).toString(),
          data: execution.data,
        })),
      },
    });
    const signedIntentOp = {
      ...route.intentOp,
      destinationSignature: MOCKESTRATOR_SIGNATURE,
      originSignatures: [MOCKESTRATOR_SIGNATURE],
    };
    const submit = await mockestratorCall<{
      result: { id: string | number | bigint; status: string };
    }>({
      mockestrator,
      method: "POST",
      path: "/intent-operations",
      body: { signedIntentOp },
    });
    return waitForMockestratorOperation({
      mockestrator,
      id: submit.result.id,
    });
  }

  return { executeThroughMockestrator, startMockestrator };
}
