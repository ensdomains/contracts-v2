import { createServer } from "node:http";
import { parseArgs } from "node:util";
import { getAddress } from "viem";
import { setupDevnet } from "./setup.js";
import { testNames } from "./testNames.js";
import { COIN_TYPE_ETH } from "../test/utils/utils.js";

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
  },
  strict: true,
});

const env = await setupDevnet({
  port: 8545,
  chainId: Number(args.values.chainId) || undefined,
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
console.table(
  Object.values(env.namedAccounts).map((x) => ({
    Name: x.name,
    Address: x.address,
    Resolver: x.resolver.address,
  })),
);

const tags = ["v2", "shared", "erc20"] as const;
console.table(
  await Promise.all(
    Object.entries(env.rocketh.deployments).map(async ([name, { address }]) => {
      const [primary] = await env.v2.UniversalResolver.read.reverse([
        address,
        COIN_TYPE_ETH,
      ]);
      return {
        "Contract Name": name,
        "Contract Address": getAddress(address),
        "Primary Name":
          !primary && (name in env.v2 || name in env.shared)
            ? undefined
            : primary,
      };
    }),
  ),
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
