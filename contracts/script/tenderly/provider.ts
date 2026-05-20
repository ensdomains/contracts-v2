import {
  type Address,
  type Chain,
  createPublicClient,
  custom,
  http,
} from "viem";

/**
 * EIP-1193 provider for Rocketh on Tenderly. All named accounts are remote:
 * transactions are sent via `eth_sendTransaction` on the VNet after the
 * addresses have been impersonated (no local private keys).
 */
export function createTenderlyProvider({
  rpcUrl,
  chain,
  accounts,
}: {
  rpcUrl: string;
  chain: Chain;
  /** Addresses exposed via `eth_accounts` (must be impersonated on the VNet). */
  accounts: Address[];
}) {
  const publicClient = createPublicClient({
    chain,
    transport: http(rpcUrl, { retryCount: 2, timeout: 120_000 }),
  });

  return custom({
    request: async ({ method, params }) => {
      if (method === "eth_accounts") {
        return accounts;
      }
      return publicClient.request({ method, params });
    },
  });
}
