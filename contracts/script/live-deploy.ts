import { program } from "commander";
import { executeDeployScripts, resolveConfig } from "rocketh";
import {
  createClient,
  hexToNumber,
  http,
  nonceManager,
  type Chain,
  type EIP1193RequestFn,
  type Hex,
  type WalletRpcSchema,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { prepareTransactionRequest, sendRawTransaction } from "viem/actions";
import { mainnet, sepolia } from "viem/chains";

const chains: Record<string, Chain> = {
  sepolia,
  mainnet,
};

program
  .option("--chain <name>", "chain name (sepolia, mainnet)", "sepolia")
  .option("--fresh-v1", "deploy V1 contracts from scratch", false)
  .option("--local", "local deployment (uses minimal TLD suffixes)", false)
  .parse();

const opts = program.opts<{ chain: string; freshV1: boolean; local: boolean }>();

const chain = chains[opts.chain];
if (!chain) throw new Error(`Unknown chain: ${opts.chain}. Supported: ${Object.keys(chains).join(", ")}`);

const rpcUrl = process.env.RPC_URL;
if (!rpcUrl) throw new Error("RPC_URL is required");

const deployerKey = process.env.DEPLOYER_KEY as Hex;
if (!deployerKey) throw new Error("DEPLOYER_KEY is required");

const client = createClient({
  chain,
  transport: http(rpcUrl),
});

process.env.BATCH_GATEWAY_URLS = '[\"x-batch-gateway:true\"]';

const getTransactionType = (params: unknown) => {
  const serializedType = (params as { type: Hex }).type;
  if (serializedType === "0x4") return "eip7702";
  if (serializedType === "0x3") return "eip4844";
  if (serializedType === "0x2") return "eip1559";
  if (serializedType === "0x1") return "eip2930";
  if (serializedType !== "0x" && hexToNumber(serializedType) >= 0xc0)
    return "legacy";
  throw new Error(`Unknown transaction type: ${serializedType}`);
};

const signer = (privKey: Hex) => {
  const acc = privateKeyToAccount(privKey, { nonceManager });
  return {
    account: acc,
    request: (async (request) => {
      if (request.method === "eth_sendTransaction") {
        for (const [key, value] of Object.entries(
          request.params[0] as Record<string, unknown>,
        )) {
          if (value === undefined) {
            delete (request.params[0] as Record<string, unknown>)[key];
          }
        }
        const prepared = await prepareTransactionRequest(client, {
          ...request.params[0],
          type: getTransactionType(request.params[0]),
          nonceManager,
          account: acc,
        });
        const signed = await acc.signTransaction(prepared);
        return sendRawTransaction(client, {
          serializedTransaction: signed,
        });
      }
      if (request.method === "eth_accounts") {
        return [acc.address];
      }
      throw new Error(`Unsupported method: ${request.method}`);
    }) as EIP1193RequestFn<WalletRpcSchema>,
  };
};

const privateKey = async (protocolString: string) => {
  const [, privateKeyString] = protocolString.split(":");
  if (!privateKeyString.startsWith("0x")) {
    throw new Error(`Private key must start with 0x`);
  }
  return {
    type: "wallet" as const,
    signer: signer(privateKeyString as Hex),
  };
};

const networkName = `${opts.chain}Fresh`;

const runDeploy = async (
  scripts: string[],
  tags: string[],
  deployments: string,
) => {
  return executeDeployScripts(
    resolveConfig({
      logLevel: 1,
      network: {
        nodeUrl: rpcUrl,
        name: networkName,
        fork: false,
        scripts,
        tags,
        publicInfo: {
          name: opts.chain,
          nativeCurrency: chain.nativeCurrency,
          rpcUrls: { default: { http: [...chain.rpcUrls.default.http] } },
        },
        provider: http(rpcUrl)({ chain }),
      },
      askBeforeProceeding: false,
      saveDeployments: true,
      accounts: {
        deployer: deployerKey,
        owner: deployerKey,
      },
      deployments,
      signerProtocols: {
        privateKey,
      },
    }),
  );
};

const runV1Deploy = async () => {
  console.log("Phase 1: Deploying V1 contracts...");
  await runDeploy(
    ["lib/ens-contracts/deploy"],
    ["use_root", "allow_unsafe", "legacy"],
    "deployments/v1",
  );
  console.log("Phase 1 complete: V1 contracts deployed");
};

const runV2Deploy = async () => {
  const v2Tags = ["l1", "l2"];
  if (opts.local) v2Tags.push("local");
  console.log(`Phase ${opts.freshV1 ? "2" : "1"}: Deploying V2 contracts...`);
  await runDeploy(
    ["deploy"],
    v2Tags,
    "deployments",
  );
  console.log("V2 contracts deployed");
};

console.log(`Deploying to ${chain.name} (chain ID: ${chain.id})`);
console.log(`RPC: ${rpcUrl}`);
console.log(`Fresh V1: ${opts.freshV1}`);
console.log(`Local: ${opts.local}`);

if (opts.freshV1) {
  await runV1Deploy();
}
await runV2Deploy();

console.log("Deployment complete!");
