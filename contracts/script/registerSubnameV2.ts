/**
 * Register a subname on ENS V2 (Sepolia).
 *
 * Usage:
 *   DEPLOYER_KEY=0x... RPC_URL=https://... bun run script/registerSubnameV2.ts sub.parent.eth [durationDays]
 *
 * Examples:
 *   DEPLOYER_KEY=0xabc... RPC_URL=https://sepolia... bun run script/registerSubnameV2.ts sub.makototest2.eth
 *   DEPLOYER_KEY=0xabc... RPC_URL=https://sepolia... bun run script/registerSubnameV2.ts sub.makototest2.eth 365
 *
 * Environment variables:
 *   DEPLOYER_KEY  - Private key of the account (must own the parent name)
 *   RPC_URL       - Sepolia RPC URL
 *
 * This script will:
 *   1. Verify the parent name exists and is owned by the deployer
 *   2. Read the parent's existing resolver
 *   3. Deploy a UserRegistry (subregistry) for the parent if needed
 *   4. Set the subregistry on the parent if needed
 *   5. Set canonical parent on the UserRegistry
 *   6. Register the subname on the UserRegistry
 *   7. Set ETH addr + text records on the parent's resolver for the subname
 */

import {
  createWalletClient,
  createPublicClient,
  getContract,
  http,
  namehash,
  parseAbi,
  parseEventLogs,
  encodeFunctionData,
  type Address,
  type Hex,
  keccak256,
  stringToBytes,
  zeroAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { readFileSync } from "fs";
import { resolve } from "path";

// ── Config ──────────────────────────────────────────────────────────────────

const DEPLOYER_KEY = process.env.DEPLOYER_KEY as Hex;
const RPC_URL = process.env.RPC_URL;

if (!DEPLOYER_KEY) throw new Error("DEPLOYER_KEY env var required");
if (!RPC_URL) throw new Error("RPC_URL env var required");

const fullName = process.argv[2];
if (!fullName) {
  console.error(
    "Usage: bun run script/registerSubnameV2.ts sub.parent.eth [durationDays]",
  );
  process.exit(1);
}
const durationDays = Number(process.argv[3] || 28);

// ── Parse name ──────────────────────────────────────────────────────────────

const parts = fullName.split(".");
if (parts.length !== 3 || parts[2] !== "eth") {
  console.error(
    'Expected format: sub.parent.eth (one level deep under .eth only)',
  );
  process.exit(1);
}
const [sublabel, parentLabel] = parts;
const parentName = `${parentLabel}.eth`;

// ── V2 contract addresses on Sepolia (from ens_v2_02042026 deployment) ──────

const V2_ADDRESSES = {
  ETHRegistrar: "0x68586418353b771cf2425ed14a07512aa880c532" as Address,
  ETHRegistry: "0x796fff2e907449be8d5921bcc215b1b76d89d080" as Address,
  VerifiableFactory: "0x9240c5f31d747d60b3d9aed2f57995094342b1ed" as Address,
  PermissionedResolverImpl:
    "0xe566a1fbaf30ff7c39828fe99f955fc55544cb9c" as Address,
  UserRegistryImpl: "0xea93aff7375e8176053ab6ab36b57cab53cbf702" as Address,
  MockUSDC: "0x302edecc2b8d1f3f4625b8a825a42f9adc102e65" as Address,
};

// ── Load ABIs from deployment artifacts ─────────────────────────────────────

function loadAbi(name: string) {
  const path = resolve(
    import.meta.dir,
    `../deployments/sepoliaFresh/${name}.json`,
  );
  return JSON.parse(readFileSync(path, "utf-8")).abi;
}

const ETHRegistryAbi = loadAbi("ETHRegistry");
const PermissionedResolverAbi = loadAbi("PermissionedResolverImpl");
const UserRegistryAbi = loadAbi("UserRegistryImpl");

const VerifiableFactoryAbi = parseAbi([
  "function deployProxy(address implementation, uint256 salt, bytes data)",
  "event ProxyDeployed(address indexed sender, address indexed proxyAddress, uint256 salt, address implementation)",
]);

// ── Constants ───────────────────────────────────────────────────────────────

const ROLES_ALL =
  0x1111111111111111111111111111111111111111111111111111111111111111n;
const MAX_EXPIRY = (1n << 64n) - 1n;

// ── Helpers ─────────────────────────────────────────────────────────────────

function idFromLabel(label: string): bigint {
  return BigInt(keccak256(stringToBytes(label)));
}

// ── Setup clients ───────────────────────────────────────────────────────────

const account = privateKeyToAccount(DEPLOYER_KEY);

const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(RPC_URL),
});

const walletClient = createWalletClient({
  account,
  chain: sepolia,
  transport: http(RPC_URL),
});

// ── Contract instances ──────────────────────────────────────────────────────

const ethRegistry = getContract({
  address: V2_ADDRESSES.ETHRegistry,
  abi: ETHRegistryAbi,
  client: { public: publicClient, wallet: walletClient },
});

// ── Helpers ─────────────────────────────────────────────────────────────────

async function waitForTx(hash: Hex) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    throw new Error(`Transaction failed: ${hash}`);
  }
  return receipt;
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const txHashes: Record<string, Hex> = {};

  console.log(`\n=== ENSv2 Subname Registration ===`);
  console.log(`Subname:  ${fullName}`);
  console.log(`Parent:   ${parentName}`);
  console.log(`Sublabel: ${sublabel}`);
  console.log(`Owner:    ${account.address}`);

  // ── Step 1: Verify parent exists and is owned by deployer ───────────────

  console.log(`\n--- Step 1: Verify parent "${parentName}" ---`);

  const parentTokenId = idFromLabel(parentLabel);
  const parentState = (await ethRegistry.read.getState([
    parentTokenId,
  ])) as { status: number; latestOwner: Address };

  // status: 0 = AVAILABLE, 1 = RESERVED, 2 = REGISTERED
  if (parentState.status !== 2) {
    throw new Error(
      `"${parentName}" is not registered (status: ${parentState.status}). Register it first with registerV2.ts`,
    );
  }

  if (parentState.latestOwner.toLowerCase() !== account.address.toLowerCase()) {
    throw new Error(
      `"${parentName}" is owned by ${parentState.latestOwner}, not by deployer ${account.address}`,
    );
  }

  console.log(`✓ "${parentName}" is registered and owned by deployer`);

  // ── Step 2: Read parent's resolver ──────────────────────────────────────

  console.log(`\n--- Step 2: Read parent's resolver ---`);

  const resolverAddress = (await ethRegistry.read.getResolver([
    parentLabel,
  ])) as Address;

  if (resolverAddress === zeroAddress) {
    throw new Error(
      `"${parentName}" has no resolver set. Register it with registerV2.ts first.`,
    );
  }

  console.log(`✓ Parent resolver: ${resolverAddress}`);

  const resolver = getContract({
    address: resolverAddress,
    abi: PermissionedResolverAbi,
    client: { public: publicClient, wallet: walletClient },
  });

  // ── Step 3: Deploy UserRegistry if parent has no subregistry ────────────

  console.log(`\n--- Step 3: Check/deploy UserRegistry (subregistry) ---`);

  let subregistryAddress = (await ethRegistry.read.getSubregistry([
    parentLabel,
  ])) as Address;

  if (subregistryAddress === zeroAddress) {
    console.log(`No subregistry set. Deploying UserRegistry...`);

    const salt = BigInt(
      keccak256(stringToBytes(`userregistry-${parentName}-${Date.now()}`)),
    );

    const initData = encodeFunctionData({
      abi: UserRegistryAbi,
      functionName: "initialize",
      args: [account.address, ROLES_ALL],
    });

    const deployHash = await walletClient.writeContract({
      address: V2_ADDRESSES.VerifiableFactory,
      abi: VerifiableFactoryAbi,
      functionName: "deployProxy",
      args: [V2_ADDRESSES.UserRegistryImpl, salt, initData],
    });

    const deployReceipt = await waitForTx(deployHash);
    const [deployLog] = parseEventLogs({
      abi: VerifiableFactoryAbi,
      eventName: "ProxyDeployed",
      logs: deployReceipt.logs,
    });

    subregistryAddress = deployLog.args.proxyAddress;
    txHashes["Deploy UserRegistry"] = deployHash;
    console.log(`✓ UserRegistry deployed: ${subregistryAddress}`);

    // ── Step 4: Set subregistry on parent ─────────────────────────────────

    console.log(`\n--- Step 4: Set subregistry on parent ---`);

    const setSubregHash = await ethRegistry.write.setSubregistry([
      parentTokenId,
      subregistryAddress,
    ]);
    await waitForTx(setSubregHash);
    txHashes["Set subregistry"] = setSubregHash;
    console.log(`✓ Subregistry set on "${parentName}"`);
  } else {
    console.log(`✓ Subregistry already exists: ${subregistryAddress}`);
  }

  const userRegistry = getContract({
    address: subregistryAddress,
    abi: UserRegistryAbi,
    client: { public: publicClient, wallet: walletClient },
  });

  // ── Step 5: Set canonical parent ────────────────────────────────────────

  console.log(`\n--- Step 5: Set canonical parent ---`);

  try {
    const setParentHash = await userRegistry.write.setParent([
      V2_ADDRESSES.ETHRegistry,
      parentLabel,
    ]);
    await waitForTx(setParentHash);
    txHashes["Set parent"] = setParentHash;
    console.log(`✓ Canonical parent set`);
  } catch (e: any) {
    // May already be set — that's fine
    if (e.message?.includes("already") || e.message?.includes("revert")) {
      console.log(`✓ Canonical parent already set (skipped)`);
    } else {
      throw e;
    }
  }

  // ── Step 6: Register subname ────────────────────────────────────────────

  console.log(`\n--- Step 6: Register "${fullName}" ---`);

  const expiry =
    durationDays === 0
      ? MAX_EXPIRY
      : BigInt(Math.floor(Date.now() / 1000) + durationDays * 86400);

  const registerHash = await userRegistry.write.register([
    sublabel,
    account.address,
    zeroAddress, // no subregistry for the subname
    resolverAddress, // reuse parent's resolver
    ROLES_ALL,
    expiry,
  ]);
  await waitForTx(registerHash);
  txHashes["Register subname"] = registerHash;
  console.log(`✓ "${fullName}" registered`);

  // ── Step 7: Set records on resolver ─────────────────────────────────────

  console.log(`\n--- Step 7: Set records on resolver ---`);

  const node = namehash(fullName);

  // Set ETH address (coinType 60)
  const setAddrHash = await resolver.write.setAddr([
    node,
    60n,
    account.address,
  ]);
  await waitForTx(setAddrHash);
  txHashes["Set addr"] = setAddrHash;
  console.log(`✓ ETH addr set to ${account.address}`);

  // Set description text record
  const setTextHash = await resolver.write.setText([
    node,
    "description",
    fullName,
  ]);
  await waitForTx(setTextHash);
  txHashes["Set text"] = setTextHash;
  console.log(`✓ Text "description" set to "${fullName}"`);

  // ── Summary ─────────────────────────────────────────────────────────────

  console.log(`\n=== Subname Registration Complete ===`);
  console.log(`Name:         ${fullName}`);
  console.log(`Owner:        ${account.address}`);
  console.log(`Resolver:     ${resolverAddress} (reused from parent)`);
  console.log(`Subregistry:  ${subregistryAddress}`);
  console.log(`ETH Addr:     ${account.address}`);
  console.log(`Description:  ${fullName}`);
  console.log(`\nTransactions:`);
  for (const [label, hash] of Object.entries(txHashes)) {
    console.log(`  ${label}: ${hash}`);
  }
}

main().catch((err) => {
  console.error("\nError:", err.message || err);
  process.exit(1);
});
