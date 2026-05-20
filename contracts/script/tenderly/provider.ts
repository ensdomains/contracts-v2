import {
  type Account,
  type Address,
  type Chain,
  createPublicClient,
  custom,
  http,
} from "viem";

/**
 * EIP-1193 provider for Rocketh. Exposes `deployer` and impersonated addresses
 * via `eth_accounts`; all transactions are sent through the Tenderly RPC (remote
 * signers), so enable impersonation on the VNet before running.
 */
export function createTenderlyProvider({
  rpcUrl,
  chain,
  deployer,
  impersonate = [],
}: {
  rpcUrl: string;
  chain: Chain;
  deployer: Account;
  impersonate?: Address[];
}) {
  const publicClient = createPublicClient({
    chain,
    transport: http(rpcUrl, { retryCount: 2, timeout: 120_000 }),
  });

  const accounts = [
    deployer.address,
    ...impersonate.filter((a) => a !== deployer.address),
  ];

  return custom({
    request: async ({ method, params }) => {
      if (method === "eth_accounts") {
        return accounts;
      }
      return publicClient.request({ method, params });
    },
  });
}
