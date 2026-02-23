import { createServer } from "node:http";
import { parseArgs } from "node:util";
import { getAddress, toHex } from "viem";
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
  },
  strict: true,
});

const env = await setupDevnet({
  port: 8545,
  saveDeployments: true,
  procLog: args.values.procLog,
  extraTime: args.values.testNames ? 86_401 : 60,
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
console.table(env.accounts.map((x) => ({ Name: x.name, Address: x.address })));

console.table({
  [env.deployment.client.chain.name]: {
    Chain: `${env.deployment.client.chain.id} (${toHex(env.deployment.client.chain.id)})`,
    Endpoint: `{http,ws}://${env.deployment.hostPort}`,
  },
});

console.table(
  Object.entries(env.deployment.env.deployments).map(([name, { address }]) => ({
    [env.deployment.client.chain.name]: name,
    "Contract Address": getAddress(address),
  })),
);

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
