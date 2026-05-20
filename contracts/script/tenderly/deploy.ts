import { artifacts } from "@rocketh";
import { readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { executeDeployScripts, resolveConfig } from "rocketh";
import {
  type Address,
  createPublicClient,
  createWalletClient,
  defineChain,
  getContract,
  http,
  publicActions,
  zeroAddress,
} from "viem";

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

/** On-chain owner of Sepolia ENS v1 contracts (Root, BaseRegistrar, NameWrapper). */
const SEPOLIA_V1_OWNER = SEPOLIA_OPERATIONS_OWNER;

export type TenderlyDeployOptions = {
  /** Tenderly Virtual TestNet RPC URL (required). */
  rpcUrl: string;
  /**
   * Your test wallet address. Impersonated on the VNet for all deploy txs.
   * Used as Rocketh `deployer` and `owner` for ENSv2 (no private key needed).
   */
  wallet: Address;
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
    sepoliaV1Owner: Address;
  };
  rocketh: Awaited<ReturnType<typeof executeDeployScripts>>;
};

/**
 * Deploy ENSv2 on a Tenderly Virtual TestNet that forks Sepolia.
 *
 * Signing is entirely via Tenderly impersonation — pass your wallet address,
 * not a private key. The Sepolia v1 operational owner (`0x0F32…`) is also
 * impersonated automatically for the few fork steps that must run as that address.
 */
export async function deployToTenderlySepoliaFork(
  options: TenderlyDeployOptions,
): Promise<TenderlyDeployResult> {
  const {
    rpcUrl,
    wallet,
    resetDeployments = true,
    skipV17Upgrade = false,
    skipActivate = false,
  } = options;

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

  const request = publicClient.request.bind(publicClient);

  console.log("Preparing Tenderly Sepolia fork…");
  console.log(`  Wallet (deployer + owner): ${wallet}`);
  console.log(`  Sepolia v1 owner (fork only): ${SEPOLIA_V1_OWNER}`);

  await patchArtifactsV1();

  await fundAddresses(request, [wallet, SEPOLIA_V1_OWNER]);
  await impersonateAddresses(request, [wallet, SEPOLIA_V1_OWNER]);
  await tryMockP256Precompile(request);

  const deploymentName = `tenderly-sepolia-${chainId}`;
  const deploymentsRoot = fileURLToPath(
    new URL("../../deployments", import.meta.url),
  );
  const deploymentsDir = join(deploymentsRoot, deploymentName);
  const canonicalDir = fileURLToPath(
    new URL("../../lib/ens-contracts/deployments/sepolia", import.meta.url),
  );

  if (resetDeployments) {
    await rm(deploymentsDir, { recursive: true, force: true });
  }

  const bootstrapClient = Object.assign(publicClient, {
    setBalance: async ({ address }: { address: Address; value: bigint }) => {
      await fundAddresses(request, [address]);
    },
  });

  console.log("Bootstrapping Sepolia v1 deployment records…");
  await bootstrapForkDeployments({
    client: bootstrapClient,
    deploymentsDir,
    canonicalDir,
    chainId,
    skipMissingArtifacts: true,
    extraFundAddresses: [wallet, SEPOLIA_V1_OWNER],
  });

  const rockethAccounts = [wallet, SEPOLIA_V1_OWNER].filter(
    (a, i, arr) => arr.indexOf(a) === i,
  );

  process.env.BATCH_GATEWAY_URLS = JSON.stringify([LOCAL_BATCH_GATEWAY_URL]);

  if (!skipV17Upgrade) {
    console.log("Installing Sepolia v1.7 registrar stack (if missing)…");
    const v17Provider = createTenderlyProvider({
      rpcUrl,
      chain,
      accounts: rockethAccounts,
    });
    await installSepoliaV17({
      provider: v17Provider,
      deploymentName,
      deploymentsRoot,
      deploymentsDir,
      deployer: wallet,
      v1Owner: SEPOLIA_V1_OWNER,
      wallet,
      chain,
      rpcUrl,
    });
  }

  const v2Provider = createTenderlyProvider({
    rpcUrl,
    chain,
    accounts: [wallet],
  });

  console.log("Deploying ENSv2 contracts…");
  const rocketh = await executeDeployScripts(
    resolveConfig({
      deployments: deploymentsRoot,
      network: {
        provider: v2Provider,
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
        deployer: wallet,
        owner: wallet,
      },
    }),
  );

  if (!skipActivate) {
    console.log("Activating ENSv2 on .eth (controller handoff)…");
    await activateV2({
      rocketh,
      rpcUrl,
      chain,
      wallet,
      v1Owner: SEPOLIA_V1_OWNER,
    });
  }

  return {
    chainId,
    deploymentName,
    deploymentsDir,
    rpcUrl,
    namedAccounts: {
      deployer: wallet,
      owner: wallet,
      sepoliaV1Owner: SEPOLIA_V1_OWNER,
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
  v1Owner,
  wallet,
  chain,
  rpcUrl,
}: {
  provider: ReturnType<typeof createTenderlyProvider>;
  deploymentName: string;
  deploymentsRoot: string;
  deploymentsDir: string;
  deployer: Address;
  v1Owner: Address;
  wallet: Address;
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
      accounts: {
        deployer,
        // Wrapped controller wiring touches NameWrapper, which on Sepolia is
        // owned by the historical ops EOA — not your wallet.
        owner: v1Owner,
      },
    }),
  );

  const publicClient = createPublicClient({
    chain,
    transport: http(rpcUrl),
  });
  const v1OwnerClient = createWalletClient({
    chain,
    transport: http(rpcUrl),
    account: v1Owner,
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
    await v1OwnerClient.writeContract({
      chain,
      address: baseAddr,
      abi: artifacts.BaseRegistrarImplementation.abi,
      functionName: "transferOwnership",
      args: [scAddr],
    });
  } else {
    console.log(
      "  - BaseRegistrar already owned by RegistrarSecurityController",
    );
  }

  const scOwner = await publicClient.readContract({
    address: scAddr,
    abi: artifacts.RegistrarSecurityController.abi,
    functionName: "owner",
  });

  if (scOwner.toLowerCase() !== wallet.toLowerCase()) {
    console.log(
      `  - Transferring RegistrarSecurityController ownership to your wallet (from ${scOwner})`,
    );
    const transferFrom =
      scOwner.toLowerCase() === v1Owner.toLowerCase() ? v1Owner : wallet;
    const transferClient = createWalletClient({
      chain,
      transport: http(rpcUrl),
      account: transferFrom,
    }).extend(publicActions);
    await transferClient.writeContract({
      chain,
      address: scAddr,
      abi: artifacts.RegistrarSecurityController.abi,
      functionName: "transferOwnership",
      args: [wallet],
    });
  }
}

/** Post-deploy controller handoff (Sepolia v1 owner + your wallet on the SC). */
async function activateV2({
  rocketh,
  rpcUrl,
  chain,
  wallet,
  v1Owner,
}: {
  rocketh: Awaited<ReturnType<typeof executeDeployScripts>>;
  rpcUrl: string;
  chain: ReturnType<typeof defineChain>;
  wallet: Address;
  v1Owner: Address;
}) {
  const v1Client = createWalletClient({
    chain,
    transport: http(rpcUrl),
    account: v1Owner,
  }).extend(publicActions);

  const walletClient = createWalletClient({
    chain,
    transport: http(rpcUrl),
    account: wallet,
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
    client: walletClient,
  });

  const nameWrapper = getContract({
    abi: artifacts.NameWrapper.abi,
    address: rocketh.get("NameWrapper").address,
    client: v1Client,
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
  await registrarSecurityController.write.addRegistrarController([wallet], txOpts);
  await registrarSecurityController.write.transferRegistrarOwnership(
    [rocketh.get("ETHRenewerV1").address],
    txOpts,
  );
}
