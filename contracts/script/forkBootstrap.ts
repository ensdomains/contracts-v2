import { readFile, writeFile, mkdir, copyFile } from "node:fs/promises";
import { join } from "node:path";
import { type Address, parseEther } from "viem";

// v1 contracts on canonical mainnet that v2 deploys and `setup.ts` reference
// by name through rocketh's `get()`. Pre-populated into the devnet deployments
// dir so `get(name)` resolves to the canonical address without redeploying.
const V1_DEPLOYMENT_NAMES = [
  "ENSRegistry",
  "Root",
  "BaseRegistrarImplementation",
  "NameWrapper",
  "RegistrarSecurityController",
  "ETHRegistrarController",
  "WrappedETHRegistrarController",
  "PublicResolver",
  "UniversalResolver",
  "OffchainDNSResolver",
  "SimplePublicSuffixList",
  "DNSSECImpl",
  "ReverseRegistrar",
  "DefaultReverseRegistrar",
  "DefaultReverseResolver",
  "BatchGatewayProvider",
] as const;

// Canonical contracts whose `.owner()` issues writes during the v2 deploy or
// activation flow. Read live so that future ownership changes on mainnet are
// picked up without code changes.
const V1_OWNABLE_NAMES = [
  "BaseRegistrarImplementation",
  "NameWrapper",
  "ReverseRegistrar",
  "DefaultReverseRegistrar",
  "RegistrarSecurityController",
] as const;

// ENS DAO multisig — mapped to the `owner` named account on chainId 1 via
// `rocketh.ts`. Included unconditionally so that even if a future ownership
// transfer hasn't fully propagated, the DAO address is still funded.
export const ENS_DAO_MULTISIG: Address =
  "0xFe89cc7aBB2C4183683ab71653C4cdc9B02D44b7";

const OWNER_ABI = [
  {
    type: "function",
    name: "owner",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
] as const;

type ClientLike = {
  readContract: (args: {
    address: Address;
    abi: typeof OWNER_ABI;
    functionName: "owner";
  }) => Promise<unknown>;
  setBalance: (args: { address: Address; value: bigint }) => Promise<void>;
};

export async function bootstrapForkDeployments({
  client,
  deploymentsDir,
  canonicalDir,
  chainId,
}: {
  client: ClientLike;
  deploymentsDir: string;
  canonicalDir: string;
  chainId: number;
}) {
  await mkdir(deploymentsDir, { recursive: true });

  for (const name of V1_DEPLOYMENT_NAMES) {
    const src = JSON.parse(
      await readFile(join(canonicalDir, `${name}.json`), "utf8"),
    );
    const dst = { address: src.address, abi: src.abi };
    await writeFile(
      join(deploymentsDir, `${name}.json`),
      JSON.stringify(dst, null, 2),
    );
  }

  // Mirror the canonical `.chain` so rocketh's chainId/genesisHash checks pass
  // against the live forked node (which exposes the upstream genesis at block
  // 0). rocketh stores chainId as a string and compares it strictly.
  await copyFile(
    join(canonicalDir, ".chain"),
    join(deploymentsDir, ".chain"),
  );

  // sanity: bail loudly if the canonical chainId disagrees with the live one
  const liveChainHeader = JSON.parse(
    await readFile(join(deploymentsDir, ".chain"), "utf8"),
  );
  if (String(liveChainHeader.chainId) !== String(chainId)) {
    throw new Error(
      `canonical .chain chainId=${liveChainHeader.chainId} does not match live chainId=${chainId}`,
    );
  }

  const ownerAddrs = new Set<Address>([ENS_DAO_MULTISIG]);
  for (const name of V1_OWNABLE_NAMES) {
    const src = JSON.parse(
      await readFile(join(canonicalDir, `${name}.json`), "utf8"),
    );
    try {
      const addr = (await client.readContract({
        address: src.address as Address,
        abi: OWNER_ABI,
        functionName: "owner",
      })) as Address;
      ownerAddrs.add(addr);
    } catch {
      // contract doesn't expose owner(); skip
    }
  }

  const fundWei = parseEther("10000");
  for (const addr of ownerAddrs) {
    await client.setBalance({ address: addr, value: fundWei });
  }
}
