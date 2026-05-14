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
    forkUrl: {
      type: "string",
    },
    forkBlock: {
      type: "string",
    },
    quiet: {
      type: "boolean",
    },
  },
  strict: true,
});

// Env-var fallbacks: CLI wins, then FORK_URL / FORK_BLOCK / DEVNET_QUIET.
// Lets callers (e.g. morticia's mainnet-fork e2e runner) configure once via
// env and avoid duplicating the same flags across every script invocation.
const forkUrl = args.values.forkUrl ?? process.env.FORK_URL;
const forkBlock = args.values.forkBlock ?? process.env.FORK_BLOCK;
const quiet = args.values.quiet ?? process.env.DEVNET_QUIET === "1";

if (forkUrl && args.values.testNames) {
  console.error("--testNames is incompatible with --forkUrl");
  process.exit(2);
}

const env = await setupDevnet({
  port: 8545,
  chainId: forkUrl ? undefined : Number(args.values.chainId) || undefined,
  saveDeployments: true,
  procLog: args.values.procLog,
  extraTime: forkUrl ? 0 : args.values.testNames ? 86_401 : 60,
  forkUrl,
  forkBlockNumber: forkBlock ? BigInt(forkBlock) : undefined,
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

if (!quiet) {
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
      Object.entries(env.rocketh.deployments).map(
        async ([name, { address }]) => {
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
        },
      ),
    ),
  );

  console.log({
    Chain: env.client.chain.id,
    Endpoint: `{http,ws}://${env.hostPort}`,
  });
}

if (args.values.testNames) {
  await testNames(env);
}

await env.sync({ warpSec: "local" });

// Fork-mode finalisation: activateV2 grants the v2 Graveyard + ETHRenewerV1
// the RegistrarSecurityController controller role, retires the v1 ETH
// controllers, and transfers registrar ownership to ETHRenewerV1 — all via
// anvil autoImpersonate as the ENS DAO multisig. Without this every
// graveyard clear() reverts with ONLY_CONTROLLER on a fresh fork.
// Greenfield (non-fork) devnets retain the previous behaviour: callers are
// expected to grant controller roles themselves via test-side setup.
if (forkUrl) {
  await env.activateV2();
}

console.log(new Date(), `Ready! <${Date.now() - t0}ms>`);

const server = createServer((req, res) => {
  // Surface every rocketh-tracked deployment as JSON so consumers don't
  // have to know about the deployments/devnet-{chainId}/*.json layout.
  if (req.url === "/deployments") {
    const body: Record<string, string> = {
      chainId: String(env.client.chain.id),
    };
    for (const [name, dep] of Object.entries(env.rocketh.deployments)) {
      body[name] = getAddress(dep.address);
    }
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(body));
    return;
  }
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("healthy\n");
});

server.listen(8000, () => {
  console.log(`Healthcheck endpoint listening on :8000/health`);
});

// ensure server shuts down with the env
process.once("exit", () => server.close());
