import { artifacts } from "@rocketh";
import { readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { executeDeployScripts, resolveConfig } from "rocketh";
import {
  type Account,
  type Address,
  createPublicClient,
  createWalletClient,
  defineChain,
  getContract,
  http,
  publicActions,
  zeroAddress,
} from "viem";
import { mnemonicToAccount, privateKeyToAccount } from "viem/accounts";

import { LOCAL_BATCH_GATEWAY_URL } from "../deploy-constants.js";
import { patchArtifactsV1 } from "../patchArtifactsV1.js";
import {
  bootstrapForkDeployments,
  SEPOLIA_OPERATIONS_OWNER,
} from "../forkBootstrap.js";
import { createTenderlyProvider } from "./provider.js";
import {
  fundAddresses,
  getChainId,
  impersonateAddresses,
  tryMockP256Precompile,
} from "./rpc.js";

const SEPOLIA_CHAIN_ID = 11155111;
const DEFAULT_MNEMONIC =
  "test test test test test test test test test test test junk";

export type TenderlyDeployOptions = {
  /** Tenderly Virtual TestNet RPC URL (required). */
  rpcUrl: string;
  /** BIP-39 mnemonic for the `deployer` named account. */
  mnemonic?: string;
  /** Optional hex private key; overrides mnemonic for `deployer`. */
  deployerPrivateKey?: `0x${string}`;
  /** Sepolia operational owner to impersonate (default: ENS Sepolia ops EOA). */
  operationsOwner?: Address;
  /** Clear `deployments/tenderly-sepolia-*` before deploying. */
  resetDeployments?: boolean;
  /** Skip v1.7 RegistrarSecurityController upgrade (if already done). */
  skipV17Upgrade?: boolean;
  /** Skip post-deploy `activateV2` controller handoff. */
  skipActivate?: boolean;
};

export type TenderlyDeployResult = {
  chainId: number;
  deploymentName: string;
  deploymentsDir: string;
  rpcUrl: string;
  namedAccounts: {
    deployer: Address;
    owner: Address;
  };
  rocketh: Awaited<ReturnType<typeof executeDeployScripts>>;
};

/**
 * Deploy ENSv2 on a Tenderly Virtual TestNet that forks Sepolia.
 *
 * High-level pipeline:
 * 1. Connect to the VNet RPC and verify chain id 11155111.
 * 2. Fund + impersonate the deployer and Sepolia operational owner (admin RPC).
 * 3. Seed Rocketh with existing Sepolia v1 deployment addresses.
 * 4. Install missing v1.7 contracts (RegistrarSecurityController, WrappedETHRegistrarController).
 * 5. Run ENSv2 deploy scripts only.
 * 6. Run `activateV2` so v2 Graveyard / ETHRenewerV1 control .eth registration.
 */
export async function deployToTenderlySepoliaFork(
  options: TenderlyDeployOptions,
): Promise<TenderlyDeployResult> {
  const {
    rpcUrl,
    mnemonic = DEFAULT_MNEMONIC,
    deployerPrivateKey,
    operationsOwner = SEPOLIA_OPERATIONS_OWNER,
    resetDeployments = true,
    skipV17Upgrade = false,
    skipActivate = false,
  } = options;

  const deployerAccount: Account = deployerPrivateKey
    ? privateKeyToAccount(deployerPrivateKey)
    : mnemonicToAccount(mnemonic, { addressIndex: 0 });

  const transport = http(rpcUrl, { retryCount: 2, timeout: 120_000 });
  const publicClient = createPublicClient({ transport });

  const chainId = await getChainId(publicClient.request.bind(publicClient));
  if (chainId !== SEPOLIA_CHAIN_ID) {
    throw new Error(
      `expected Sepolia fork (chainId ${SEPOLIA_CHAIN_ID}), got ${chainId}`,
    );
  }

  const chain = defineChain({
    id: chainId,
    name: "Tenderly Sepolia Fork",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  });

  console.log("Preparing Tenderly Sepolia fork…");
  await patchArtifactsV1();

  await fundAddresses(publicClient.request.bind(publicClient), [
    deployerAccount.address,
    operationsOwner,
  ]);
  await impersonateAddresses(publicClient.request.bind(publicClient), [
    deployerAccount.address,
    operationsOwner,
  ]);
  await tryMockP256Precompile(publicClient.request.bind(publicClient));

  const deploymentName = `tenderly-sepolia-${chainId}`;
  const deploymentsRoot = fileURLToPath(
    new URL("../../deployments", import.meta.url),
  );
  const deploymentsDir = join(deploymentsRoot, deploymentName);
  const canonicalDir = fileURLToPath(
    new URL(
      "../../lib/ens-contracts/deployments/sepolia",
      import.meta.url,
    ),
  );

  if (resetDeployments) {
    await rm(deploymentsDir, { recursive: true, force: true });
  }

  const bootstrapClient = Object.assign(publicClient, {
    setBalance: async ({
      address,
      value,
    }: {
      address: Address;
      value: bigint;
    }) => {
      await fundAddresses(publicClient.request.bind(publicClient), [address]);
    },
  });

  console.log("Bootstrapping Sepolia v1 deployment records…");
  await bootstrapForkDeployments({
    client: bootstrapClient,
    deploymentsDir,
    canonicalDir,
    chainId,
    skipMissingArtifacts: true,
    extraFundAddresses: [operationsOwner],
  });

  const provider = createTenderlyProvider({
    rpcUrl,
    chain,
    deployer: deployerAccount,
    impersonate: [operationsOwner],
  });

  process.env.BATCH_GATEWAY_URLS = JSON.stringify([LOCAL_BATCH_GATEWAY_URL]);

  if (!skipV17Upgrade) {
    console.log("Installing Sepolia v1.7 registrar stack (if missing)…");
    await installSepoliaV17({
      provider,
      deploymentName,
      deploymentsRoot,
      deploymentsDir,
      deployer: deployerAccount.address,
      owner: operationsOwner,
      chain,
      rpcUrl,
    });
  }

  console.log("Deploying ENSv2 contracts…");
  const rocketh = await executeDeployScripts(
    resolveConfig({
      deployments: deploymentsRoot,
      network: {
        provider,
        name: deploymentName,
        tags: [
          "v2",
          "local",
          "test",
          "use_root",
          "allow_unsafe",
          "legacy",
          "tenderly",
        ],
        fork: false,
        scripts: ["deploy"],
        pollingInterval: 0.001,
      },
      askBeforeProceeding: false,
      saveDeployments: true,
      accounts: {
        deployer: deployerAccount.address,
        owner: operationsOwner,
      },
    }),
  );

  if (!skipActivate) {
    console.log("Activating ENSv2 on .eth (controller handoff)…");
    await activateV2({
      rocketh,
      rpcUrl,
      chain,
      operationsOwner,
      deployer: deployerAccount.address,
    });
  }

  return {
    chainId,
    deploymentName,
    deploymentsDir,
    rpcUrl,
    namedAccounts: {
      deployer: deployerAccount.address,
      owner: operationsOwner,
    },
    rocketh,
  };
}

/** Deploy RegistrarSecurityController + WrappedETHRegistrarController on Sepolia forks. */
async function installSepoliaV17({
  provider,
  deploymentName,
  deploymentsRoot,
  deploymentsDir,
  deployer,
  owner,
  chain,
  rpcUrl,
}: {
  provider: ReturnType<typeof createTenderlyProvider>;
  deploymentName: string;
  deploymentsRoot: string;
  deploymentsDir: string;
  deployer: Address;
  owner: Address;
  chain: ReturnType<typeof defineChain>;
  rpcUrl: string;
}) {
  await executeDeployScripts(
    resolveConfig({
      deployments: deploymentsRoot,
      network: {
        provider,
        name: deploymentName,
        tags: ["test", "legacy", "use_root", "tenderly"],
        fork: false,
        scripts: [
          "lib/ens-contracts/deploy/ethregistrar/00_deploy_registrar_security_controller.ts",
          "lib/ens-contracts/deploy/ethregistrar/03_deploy_wrapped_eth_registrar_controller.ts",
        ],
        pollingInterval: 0.001,
      },
      askBeforeProceeding: false,
      saveDeployments: true,
      accounts: { deployer, owner },
    }),
  );

  const publicClient = createPublicClient({
    chain,
    transport: http(rpcUrl),
  });
  const ownerClient = createWalletClient({
    chain,
    transport: http(rpcUrl),
    account: owner,
  }).extend(publicActions);

  const readDep = async (name: string) => {
    const raw = await readFile(join(deploymentsDir, `${name}.json`), "utf8");
    return JSON.parse(raw).address as Address;
  };

  const baseAddr = await readDep("BaseRegistrarImplementation");
  const scAddr = await readDep("RegistrarSecurityController");

  const liveOwner = await publicClient.readContract({
    address: baseAddr,
    abi: artifacts.BaseRegistrarImplementation.abi,
    functionName: "owner",
  });

  if (liveOwner.toLowerCase() !== scAddr.toLowerCase()) {
    console.log(
      `  - Transferring BaseRegistrar ownership to RegistrarSecurityController (from ${liveOwner})`,
    );
    await ownerClient.writeContract({
      chain,
      address: baseAddr,
      abi: artifacts.BaseRegistrarImplementation.abi,
      functionName: "transferOwnership",
      args: [scAddr],
    });
  } else {
    console.log("  - BaseRegistrar already owned by RegistrarSecurityController");
  }
}

/** Mirror of devnet `activateV2` for Sepolia-fork operational owner. */
async function activateV2({
  rocketh,
  rpcUrl,
  chain,
  operationsOwner,
  deployer,
}: {
  rocketh: Awaited<ReturnType<typeof executeDeployScripts>>;
  rpcUrl: string;
  chain: ReturnType<typeof defineChain>;
  operationsOwner: Address;
  deployer: Address;
}) {
  const client = createWalletClient({
    chain,
    transport: http(rpcUrl),
    account: operationsOwner,
  }).extend(publicActions);

  const v1ControllerNames = [
    "ETHRegistrarController",
    "WrappedETHRegistrarController",
    "LegacyETHRegistrarController",
    "NameWrapper",
  ] as const;

  const registrarSecurityController = getContract({
    abi: artifacts.RegistrarSecurityController.abi,
    address: rocketh.get("RegistrarSecurityController").address,
    client,
  });

  const nameWrapper = getContract({
    abi: artifacts.NameWrapper.abi,
    address: rocketh.get("NameWrapper").address,
    client,
  });

  const txOpts = { chain } as const;

  if ((await nameWrapper.read.owner()) !== zeroAddress) {
    await nameWrapper.write.renounceOwnership(txOpts);
  }

  for (const name of v1ControllerNames) {
    try {
      await registrarSecurityController.write.removeRegistrarController(
        [rocketh.get(name).address],
        txOpts,
      );
    } catch (err) {
      console.warn(`  - skip removeRegistrarController(${name}): ${err}`);
    }
  }

  await registrarSecurityController.write.addRegistrarController(
    [rocketh.get("Graveyard").address],
    txOpts,
  );
  await registrarSecurityController.write.addRegistrarController(
    [rocketh.get("ETHRenewerV1").address],
    txOpts,
  );
  await registrarSecurityController.write.addRegistrarController(
    [deployer],
    txOpts,
  );
  await registrarSecurityController.write.transferRegistrarOwnership(
    [rocketh.get("ETHRenewerV1").address],
    txOpts,
  );
}
