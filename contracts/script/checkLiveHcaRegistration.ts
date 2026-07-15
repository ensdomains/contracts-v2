import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { zeroAddress } from "viem";

const LIVE_RUN_TIMEOUT_MS = 180_000;

const contractsRoot = fileURLToPath(new URL("..", import.meta.url));

type LiveRegistrationSummary = {
  name: string;
  owner: string;
  ownerKeySource: string;
  sessionKeySource: string;
  transactions: {
    deployHca?: string;
    commit: string;
    executeSinglechainOps: string;
  };
  verified: {
    defaultPrimary: string;
    exactV1ReverseResolver: string;
    ownerHasResolverRoles: boolean;
    urForward: {
      address: string;
    };
    urReverse: {
      primary: string;
    };
  };
};

function requireEnv(env: NodeJS.ProcessEnv, name: string) {
  if (!env[name]) {
    throw new Error(`${name} is required for the live HCA check`);
  }
}

function liveEnv() {
  const env = { ...process.env };

  env.HCA_DEPLOYMENT_NETWORK ??= env.DEPLOYMENT_NETWORK;
  env.V1_DEPLOYMENT_NETWORK ??= "sepolia";
  env.HCA_GENERATE_OWNER = "1";
  env.HCA_MINT_PAYMENT_TOKEN = "1";
  env.HCA_EXPECT_DEFAULT_REVERSE_FALLBACK = "1";
  delete env.HCA_OWNER_KEY;
  delete env.HCA_SESSION_KEY;

  requireEnv(env, "SEPOLIA_RPC_URL");
  requireEnv(env, "DEPLOYER_KEY");
  requireEnv(env, "DEPLOYMENT_NETWORK");
  requireEnv(env, "RHINESTONE_SDK_SINGLE_CHAIN_OPS");

  return env;
}

function parseSummary(stdout: string): LiveRegistrationSummary {
  const trimmed = stdout.trim();
  const start = trimmed.lastIndexOf("\n{");
  const json = start === -1 ? trimmed : trimmed.slice(start + 1);
  return JSON.parse(json) as LiveRegistrationSummary;
}

const proc = Bun.spawn(["bun", "script/liveHcaRhinestoneRegistration.ts"], {
  cwd: contractsRoot,
  env: liveEnv(),
  stdout: "pipe",
  stderr: "pipe",
});

const timeout = setTimeout(() => {
  proc.kill();
}, LIVE_RUN_TIMEOUT_MS);

const [stdout, stderr, exitCode] = await Promise.all([
  new Response(proc.stdout).text(),
  new Response(proc.stderr).text(),
  proc.exited,
]);
clearTimeout(timeout);

if (exitCode !== 0) {
  throw new Error(
    `live HCA registration failed with exit code ${exitCode}\n${stdout}\n${stderr}`,
  );
}

const summary = parseSummary(stdout);

assert.ok(summary.name.endsWith(".eth"), "registered name must end in .eth");
assert.equal(summary.ownerKeySource, "generated");
assert.equal(summary.sessionKeySource, "generated");
assert.equal(summary.verified.defaultPrimary, summary.name);
assert.equal(summary.verified.exactV1ReverseResolver, zeroAddress);
assert.equal(summary.verified.ownerHasResolverRoles, true);
assert.equal(summary.verified.urReverse.primary, summary.name);
assert.equal(
  summary.verified.urForward.address.toLowerCase(),
  summary.owner.toLowerCase(),
);
assert.match(summary.transactions.deployHca ?? "", /^0x[0-9a-fA-F]{64}$/);
assert.match(summary.transactions.commit, /^0x[0-9a-fA-F]{64}$/);
assert.match(summary.transactions.executeSinglechainOps, /^0x[0-9a-fA-F]{64}$/);

console.log(`live HCA check passed for ${summary.name}`);
