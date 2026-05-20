import {
  type Address,
  type EIP1193Parameters,
  type EIP1193RequestFn,
  type Hex,
  parseEther,
} from "viem";

const FUND_WEI = parseEther("10000");

/**
 * Best-effort balance top-up for fork testing on Tenderly / Anvil / Hardhat nodes.
 */
export async function trySetBalance(
  request: EIP1193RequestFn,
  address: Address,
  wei: bigint = FUND_WEI,
) {
  const quantity = `0x${wei.toString(16)}`;
  const methods = [
    "tenderly_setBalance",
    "anvil_setBalance",
    "hardhat_setBalance",
  ] as const;
  for (const method of methods) {
    try {
      await request({
        method,
        params: [address, quantity],
      } as EIP1193Parameters);
      return;
    } catch {
      // try next RPC flavour
    }
  }
  console.warn(
    `  - could not fund ${address} via admin RPC; ensure the account has ETH on the VNet`,
  );
}

/**
 * Enable unsigned sends as `address` on simulation nodes (Tenderly / Anvil / Hardhat).
 */
export async function tryImpersonate(
  request: EIP1193RequestFn,
  address: Address,
) {
  const methods = [
    "tenderly_impersonateAccount",
    "anvil_impersonateAccount",
    "hardhat_impersonateAccount",
  ] as const;
  for (const method of methods) {
    try {
      await request({
        method,
        params: [address],
      } as EIP1193Parameters);
      return;
    } catch {
      // try next RPC flavour
    }
  }
  throw new Error(
    `could not impersonate ${address}; enable Admin RPC / state overrides on the Tenderly Virtual TestNet`,
  );
}

/** Mock EIP-7951 P-256 precompile used by ens-contracts DNSSEC (Anvil lacks it). */
export async function tryMockP256Precompile(request: EIP1193RequestFn) {
  const methods = ["anvil_setCode", "tenderly_setCode"] as const;
  for (const method of methods) {
    try {
      await request({
        method,
        params: [
          "0x0000000000000000000000000000000000000100",
          "0x60015f5260205ff3",
        ],
      } as EIP1193Parameters);
      return;
    } catch {
      // optional on nodes that already expose the precompile
    }
  }
}

export async function fundAddresses(
  request: EIP1193RequestFn,
  addresses: Iterable<Address>,
) {
  for (const address of addresses) {
    await trySetBalance(request, address);
  }
}

export async function impersonateAddresses(
  request: EIP1193RequestFn,
  addresses: Iterable<Address>,
) {
  for (const address of addresses) {
    await tryImpersonate(request, address);
  }
}

export async function getChainId(request: EIP1193RequestFn) {
  const hex = await request({ method: "eth_chainId" });
  return Number(hex as Hex);
}
