/**
 * Register a name directly on ENS V2 (Sepolia) with a PermissionedResolver.
 *
 * Usage:
 *   DEPLOYER_KEY=0x... RPC_URL=https://... bun run script/registerV2.ts <label> [durationDays]
 *
 * Examples:
 *   DEPLOYER_KEY=0xabc... RPC_URL=https://sepolia... bun run script/registerV2.ts makototest2
 *   DEPLOYER_KEY=0xabc... RPC_URL=https://sepolia... bun run script/registerV2.ts makototest2 365
 *
 * Environment variables:
 *   DEPLOYER_KEY  - Private key of the account registering the name
 *   RPC_URL       - Sepolia RPC URL
 *
 * This script will:
 *   1. Deploy a PermissionedResolver for you (via VerifiableFactory)
 *   2. Commit the name (tx 1)
 *   3. Wait for MIN_COMMITMENT_AGE
 *   4. Approve MockUSDC payment
 *   5. Register the name (tx 2)
 *   6. Set ETH addr record on the resolver (tx 3)
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

const label = process.argv[2];
if (!label) {
  console.error("Usage: bun run script/registerV2.ts <label> [durationDays]");
  process.exit(1);
}
const durationDays = Number(process.argv[3] || 28);

// ── V2 contract addresses on Sepolia (from ens_v2_02042026 deployment) ──────

const V2_ADDRESSES = {
  ETHRegistrar: "0x68586418353b771cf2425ed14a07512aa880c532" as Address,
  ETHRegistry: "0x796fff2e907449be8d5921bcc215b1b76d89d080" as Address,
  VerifiableFactory: "0x9240c5f31d747d60b3d9aed2f57995094342b1ed" as Address,
  PermissionedResolverImpl:
    "0xe566a1fbaf30ff7c39828fe99f955fc55544cb9c" as Address,
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

const ETHRegistrarAbi = loadAbi("ETHRegistrar");
const ETHRegistryAbi = loadAbi("ETHRegistry");
const PermissionedResolverAbi = loadAbi("PermissionedResolverImpl");
const MockUSDCAbi = loadAbi("MockUSDC");

const VerifiableFactoryAbi = parseAbi([
  "function deployProxy(address implementation, uint256 salt, bytes data)",
  "event ProxyDeployed(address indexed sender, address indexed proxyAddress, uint256 salt, address implementation)",
]);

// ── Roles (from deploy-constants.ts) ────────────────────────────────────────

const ROLES_ALL =
  0x1111111111111111111111111111111111111111111111111111111111111111n;

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

const ethRegistrar = getContract({
  address: V2_ADDRESSES.ETHRegistrar,
  abi: ETHRegistrarAbi,
  client: { public: publicClient, wallet: walletClient },
});

const ethRegistry = getContract({
  address: V2_ADDRESSES.ETHRegistry,
  abi: ETHRegistryAbi,
  client: { public: publicClient, wallet: walletClient },
});

const mockUSDC = getContract({
  address: V2_ADDRESSES.MockUSDC,
  abi: MockUSDCAbi,
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

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const duration = BigInt(durationDays * 86400);
  const secret: Hex = keccak256(
    stringToBytes(`${label}-${Date.now()}-secret`),
  );
  const referrer =
    "0x0000000000000000000000000000000000000000000000000000000000000000" as Hex;
  const paymentToken = V2_ADDRESSES.MockUSDC;

  console.log(`\n=== ENSv2 Direct Registration ===`);
  console.log(`Label:    ${label}`);
  console.log(`Full:     ${label}.eth`);
  console.log(`Owner:    ${account.address}`);
  console.log(`Duration: ${durationDays} days`);
  console.log(`Payment:  MockUSDC (${paymentToken})`);

  // ── Step 1: Deploy PermissionedResolver ─────────────────────────────────

  console.log(`\n--- Step 1: Deploy PermissionedResolver ---`);
  const salt = BigInt(keccak256(stringToBytes(`resolver-${Date.now()}`)));

  const initData = encodeFunctionData({
    abi: PermissionedResolverAbi,
    functionName: "initialize",
    args: [account.address, ROLES_ALL],
  });

  const deployHash = await walletClient.writeContract({
    address: V2_ADDRESSES.VerifiableFactory,
    abi: VerifiableFactoryAbi,
    functionName: "deployProxy",
    args: [V2_ADDRESSES.PermissionedResolverImpl, salt, initData],
  });

  const deployReceipt = await waitForTx(deployHash);
  const [deployLog] = parseEventLogs({
    abi: VerifiableFactoryAbi,
    eventName: "ProxyDeployed",
    logs: deployReceipt.logs,
  });

  const resolverAddress = deployLog.args.proxyAddress;
  console.log(`Resolver deployed: ${resolverAddress}`);
  console.log(`Tx: ${deployHash}`);

  // ── Step 2: Check availability ──────────────────────────────────────────

  console.log(`\n--- Step 2: Check availability ---`);
  const isAvailable = await ethRegistrar.read.isAvailable([label]);
  if (!isAvailable) {
    throw new Error(`"${label}" is not available for registration`);
  }
  console.log(`"${label}" is available`);

  // ── Step 3: Commit ──────────────────────────────────────────────────────

  console.log(`\n--- Step 3: Commit ---`);
  const commitment = await ethRegistrar.read.makeCommitment([
    label,
    account.address,
    secret,
    zeroAddress, // subregistry
    resolverAddress,
    duration,
    referrer,
  ]);

  const commitHash = await ethRegistrar.write.commit([commitment]);
  await waitForTx(commitHash);
  console.log(`Commitment submitted: ${commitHash}`);

  // ── Step 4: Wait for MIN_COMMITMENT_AGE ─────────────────────────────────

  const minAge = await ethRegistrar.read.MIN_COMMITMENT_AGE();
  const waitSeconds = Number(minAge) + 5; // add buffer
  console.log(
    `\n--- Step 4: Waiting ${waitSeconds}s for MIN_COMMITMENT_AGE ---`,
  );

  for (let elapsed = 0; elapsed < waitSeconds; elapsed += 10) {
    const remaining = waitSeconds - elapsed;
    process.stdout.write(`\r  Waiting... ${remaining}s remaining  `);
    await sleep(Math.min(10000, remaining * 1000));
  }
  console.log(`\n  Done waiting.`);

  // ── Step 5: Approve payment ─────────────────────────────────────────────

  console.log(`\n--- Step 5: Approve MockUSDC payment ---`);
  const [base, premium] = (await ethRegistrar.read.rentPrice([
    label,
    account.address,
    duration,
    paymentToken,
  ])) as [bigint, bigint];

  const totalPrice = base + premium;
  console.log(`Price: ${base} (base) + ${premium} (premium) = ${totalPrice}`);

  // Mint if needed
  const balance = (await mockUSDC.read.balanceOf([
    account.address,
  ])) as bigint;
  if (balance < totalPrice) {
    console.log(
      `Balance ${balance} < price ${totalPrice}, minting...`,
    );
    const mintHash = await mockUSDC.write.mint([
      account.address,
      totalPrice - balance + 1000000n,
    ]);
    await waitForTx(mintHash);
    console.log(`Minted. Tx: ${mintHash}`);
  }

  const approveHash = await mockUSDC.write.approve([
    V2_ADDRESSES.ETHRegistrar,
    totalPrice,
  ]);
  await waitForTx(approveHash);
  console.log(`Approved. Tx: ${approveHash}`);

  // ── Step 6: Register ────────────────────────────────────────────────────

  console.log(`\n--- Step 6: Register ---`);
  const registerHash = await ethRegistrar.write.register([
    label,
    account.address,
    secret,
    zeroAddress, // subregistry
    resolverAddress,
    duration,
    paymentToken,
    referrer,
  ]);
  const registerReceipt = await waitForTx(registerHash);
  console.log(`Registered! Tx: ${registerHash}`);

  // ── Step 7: Set ETH address on resolver ─────────────────────────────────

  console.log(`\n--- Step 7: Set ETH addr record ---`);
  const node = namehash(`${label}.eth`);

  const resolver = getContract({
    address: resolverAddress,
    abi: PermissionedResolverAbi,
    client: { public: publicClient, wallet: walletClient },
  });

  const setAddrHash = await resolver.write.setAddr([
    node,
    60n,
    account.address,
  ]);
  await waitForTx(setAddrHash);
  console.log(`ETH addr set to ${account.address}`);
  console.log(`Tx: ${setAddrHash}`);

  // ── Summary ─────────────────────────────────────────────────────────────

  console.log(`\n=== Registration Complete ===`);
  console.log(`Name:     ${label}.eth`);
  console.log(`Owner:    ${account.address}`);
  console.log(`Resolver: ${resolverAddress}`);
  console.log(`ETH Addr: ${account.address}`);
  console.log(`\nTransactions:`);
  console.log(`  Deploy resolver: ${deployHash}`);
  console.log(`  Commit:          ${commitHash}`);
  console.log(`  Register:        ${registerHash}`);
  console.log(`  Set addr:        ${setAddrHash}`);
}

main().catch((err) => {
  console.error("\nError:", err.message || err);
  process.exit(1);
});
