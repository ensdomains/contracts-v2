import { createServer } from "node:http";
import { parseArgs } from "node:util";
import { getAddress } from "viem";
import { setupDevnet } from "./setup.js";
import { testNames } from "./testNames.js";

const t0 = Date.now();

const args = parseArgs({
  args: process.argv.slice(2),
  options: {
    procLog: {
      type: "boolean",
    },
    testNames: {
      type: "boolean",
    },
    chainId: {
      type: "string",
    },
    forkUrl: {
      type: "string",
    },
    forkBlock: {
      type: "string",
    },
  },
  strict: true,
});

if (args.values.forkUrl && args.values.testNames) {
  console.error("--testNames is incompatible with --forkUrl");
  process.exit(2);
}

const env = await setupDevnet({
  port: 8545,
  chainId: args.values.forkUrl
    ? undefined
    : Number(args.values.chainId) || undefined,
  saveDeployments: true,
  procLog: args.values.procLog,
  extraTime: args.values.forkUrl
    ? 0
    : args.values.testNames
      ? 86_401
      : 60,
  forkUrl: args.values.forkUrl,
  forkBlockNumber: args.values.forkBlock
    ? BigInt(args.values.forkBlock)
    : undefined,
});

// handler for shell
process.once("SIGINT", async () => {
  console.log("\nShutting down...");
  await env.shutdown();
  process.exit();
});
// handler for docker
process.once("SIGTERM", async (code) => {
  await env.shutdown();
  process.exit(0);
});
// handler for bugs
process.once("uncaughtException", async (err) => {
  await env.shutdown();
  throw err;
});

console.log();
console.log("Available Named Accounts:");
console.table(
  Object.values(env.namedAccounts).map((x) => ({
    Name: x.name,
    Address: x.address,
    Resolver: x.resolver.address,
  })),
);

console.table(
  Object.entries(env.rocketh.deployments).map(([name, { address }]) => ({
    "Contract Name": name,
    "Contract Address": getAddress(address),
  })),
);

console.log({
  Chain: env.client.chain.id,
  Endpoint: `{http,ws}://${env.hostPort}`,
});

if (args.values.testNames) {
  await testNames(env);
}

await env.sync({ warpSec: "local" });

console.log(new Date(), `Ready! <${Date.now() - t0}ms>`);

const server = createServer((_req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("healthy\n");
});

server.listen(8000, () => {
  console.log(`Healthcheck endpoint listening on :8000/health`);
});

// ensure server shuts down with the env
process.once("exit", () => server.close());
