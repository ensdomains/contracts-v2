import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  publicActions,
  type Chain,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { mainnet, sepolia } from "viem/chains";

export const DEFAULT_RPC_TIMEOUT_MS = 30_000;

/// How long one request may take, its reply included.
export const RPC_REPLY_DEADLINE_MS = 120_000;

/// A fetch whose deadline covers the whole reply.
///
/// viem's timeout ends once the headers arrive and the body is read after it, so a
/// provider that stops sending a reply midway holds the read open for good. The
/// deadline turns that into a failed request, which viem and the callers retry.
export function fetchWithDeadline(ms: number) {
  return (
    input: string | URL | Request,
    init?: RequestInit,
  ): Promise<Response> => {
    const deadline = AbortSignal.timeout(ms);
    return fetch(input, {
      ...init,
      signal: init?.signal
        ? AbortSignal.any([init.signal, deadline])
        : deadline,
    });
  };
}

/// How often a client polls a node on this machine, such as for a receipt.
const LOCAL_POLLING_INTERVAL_MS = 50;

/// Host names that reach a node on this machine.
const LOCAL_HOSTNAMES = new Set(["localhost", "127.0.0.1", "[::1]", "0.0.0.0"]);

/// The polling interval for a client of the node at `rpcUrl`.
///
/// A local node mines each transaction as it arrives, so it is polled at a short
/// interval rather than at viem's default, which suits a public chain's block time
/// and adds seconds to every wait. Any other node keeps viem's default.
export function pollingIntervalFor(rpcUrl: string): number | undefined {
  if (!URL.canParse(rpcUrl)) return undefined;
  return LOCAL_HOSTNAMES.has(new URL(rpcUrl).hostname)
    ? LOCAL_POLLING_INTERVAL_MS
    : undefined;
}

/// Canonical CREATE2 Multicall3 deployment address, identical across EVM chains.
const MULTICALL3_ADDRESS =
  "0xcA11bde05977b3631167028862bE2a173976CA11" as const;

/// Load an ABI from the forge compilation artifact under `contracts/out/`.
export function loadArtifact(contractName: string): { abi: any[] } {
  const artifactPath = join(
    import.meta.dirname,
    `../out/${contractName}.sol/${contractName}.json`,
  );
  const artifact = JSON.parse(readFileSync(artifactPath, "utf-8"));
  return { abi: artifact.abi };
}

/// Resolve the viem Chain for a given RPC endpoint: mainnet if chainId===1,
/// otherwise a synthesized custom chain wrapping the provided RPC URL.
export async function resolveChain(
  rpcUrl: string,
  timeoutMs = DEFAULT_RPC_TIMEOUT_MS,
): Promise<Chain> {
  const probe = createPublicClient({
    transport: http(rpcUrl, {
      retryCount: 0,
      timeout: timeoutMs,
      fetchFn: fetchWithDeadline(RPC_REPLY_DEADLINE_MS),
    }),
  });
  const chainId = await probe.getChainId();
  if (chainId === 1) return mainnet;
  if (chainId === sepolia.id) return sepolia;
  return defineChain({
    id: chainId,
    name: "Custom",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
    contracts: { multicall3: { address: MULTICALL3_ADDRESS } },
  });
}

export interface V2ClientBundle {
  chain: Chain;
  account: PrivateKeyAccount | null;
  publicClient: PublicClient;
  // When `privateKey` is supplied this is a wallet client extended with
  // public actions (so it can be used for reads as well as writes).
  walletClient: ReturnType<typeof createWalletClient> | null;
}

/// Build viem clients for the target v2 chain. When `privateKey` is absent,
/// only a read-only `publicClient` is returned — suitable for dry-run flows.
export async function createV2Clients(opts: {
  rpcUrl: string;
  privateKey?: Hex | null;
  timeoutMs?: number;
}): Promise<V2ClientBundle> {
  const timeout = opts.timeoutMs ?? DEFAULT_RPC_TIMEOUT_MS;
  const chain = await resolveChain(opts.rpcUrl, timeout);
  const transport = http(opts.rpcUrl, {
    retryCount: 0,
    timeout,
    fetchFn: fetchWithDeadline(RPC_REPLY_DEADLINE_MS),
  });

  const pollingInterval = pollingIntervalFor(opts.rpcUrl);

  const publicClient = createPublicClient({
    chain,
    transport,
    pollingInterval,
  });

  if (!opts.privateKey) {
    return { chain, account: null, publicClient, walletClient: null };
  }

  const account = privateKeyToAccount(opts.privateKey);
  const walletClient = createWalletClient({
    account,
    chain,
    transport,
    pollingInterval,
  }).extend(publicActions);

  return { chain, account, publicClient, walletClient };
}
