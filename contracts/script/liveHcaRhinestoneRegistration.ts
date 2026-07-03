import { createRequire } from "node:module";
import { readFileSync } from "node:fs";

import {
  type Address,
  concat,
  createPublicClient,
  createWalletClient,
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  getContractAddress,
  hashTypedData,
  http,
  keccak256,
  namehash,
  parseAbiParameters,
  stringToBytes,
  stringToHex,
  type Hex,
  zeroAddress,
  zeroHash,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

import {
  DefaultReverseRegistrar,
  DefaultReverseRegistrarAdapter,
  ENSRegistry,
  ETHRegistrar,
  PermissionedRegistry,
  PermissionedResolver,
  RegistrationBootstrapper,
  StandaloneSingleOwnerHCA,
  UniversalResolverV2,
  VerifiableFactory,
} from "../generated/artifacts/index.ts";
import {
  PERMIT2_ADDRESS,
  permit2SessionDigest,
} from "../test/utils/hcaSessions.ts";
import { dnsEncodeName } from "../test/utils/utils.ts";

const DEPLOYMENT_NETWORK = process.env.DEPLOYMENT_NETWORK ?? "sepolia";
const HCA_DEPLOYMENT_NETWORK =
  process.env.HCA_DEPLOYMENT_NETWORK ?? DEPLOYMENT_NETWORK;
const V1_DEPLOYMENT_NETWORK = process.env.V1_DEPLOYMENT_NETWORK ?? "sepolia";
const RPC_URL = process.env.SEPOLIA_RPC_URL;
const DEPLOYER_KEY = process.env.DEPLOYER_KEY;
const HCA_OWNER_KEY = process.env.HCA_OWNER_KEY;
const HCA_SESSION_KEY = process.env.HCA_SESSION_KEY;
const HCA_GENERATE_OWNER = process.env.HCA_GENERATE_OWNER === "1";
const HCA_MINT_PAYMENT_TOKEN = process.env.HCA_MINT_PAYMENT_TOKEN === "1";
const HCA_EXPECT_DEFAULT_REVERSE_FALLBACK =
  process.env.HCA_EXPECT_DEFAULT_REVERSE_FALLBACK === "1";
const HCA_FUND_OWNER_WEI = process.env.HCA_FUND_OWNER_WEI
  ? BigInt(process.env.HCA_FUND_OWNER_WEI)
  : 0n;
const RHINESTONE_SDK_SINGLE_CHAIN_OPS =
  process.env.RHINESTONE_SDK_SINGLE_CHAIN_OPS;

const REGISTRATION_DURATION = 28n * 86400n;
const COIN_TYPE_ETH = 60n;
const STATUS_REGISTERED = 2;
const ROLES_ALL =
  0x1111111111111111111111111111111111111111111111111111111111111111n;
const ENTRYPOINT_ERC7579_SIGMODE_ERC1271 =
  `0x0201${"00".repeat(30)}` as Hex;
const PERMIT2_SOURCE_CHAIN_ID = 8453n;

const intentExecutorAbi = [
  {
    type: "function",
    name: "executeSinglechainOps",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "signedOps",
        type: "tuple",
        components: [
          { name: "account", type: "address" },
          { name: "nonce", type: "uint256" },
          {
            name: "ops",
            type: "tuple",
            components: [{ name: "data", type: "bytes" }],
          },
          { name: "signature", type: "bytes" },
        ],
      },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "isStandaloneIntentNonceConsumed",
    stateMutability: "view",
    inputs: [
      { name: "nonce", type: "uint256" },
      { name: "account", type: "address" },
    ],
    outputs: [{ name: "used", type: "bool" }],
  },
] as const;

const erc20Abi = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "success", type: "bool" }],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "balance", type: "uint256" }],
  },
] as const;

const mintablePaymentTokenAbi = [
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
] as const;

type Deployment = { address: Address };
type HCAExecution = {
  target: Address;
  value: bigint;
  callData: Hex;
};

if (!RPC_URL) throw new Error("SEPOLIA_RPC_URL is required");
if (!DEPLOYER_KEY) throw new Error("DEPLOYER_KEY is required");

function asPrivateKey(value: string): Hex {
  return value.startsWith("0x") ? (value as Hex) : (`0x${value}` as Hex);
}

const generatedOwnerKey = HCA_GENERATE_OWNER ? generatePrivateKey() : undefined;
const generatedSessionKey = HCA_SESSION_KEY ? undefined : generatePrivateKey();
const relayer = privateKeyToAccount(asPrivateKey(DEPLOYER_KEY));
const owner = privateKeyToAccount(
  asPrivateKey(HCA_OWNER_KEY ?? generatedOwnerKey ?? DEPLOYER_KEY),
);
const ownerKeySource = generatedOwnerKey
  ? "generated"
  : HCA_OWNER_KEY
    ? "HCA_OWNER_KEY"
    : "DEPLOYER_KEY";
const sessionKey = privateKeyToAccount(
  asPrivateKey(HCA_SESSION_KEY ?? generatedSessionKey!),
);
const sessionKeySource = HCA_SESSION_KEY ? "HCA_SESSION_KEY" : "generated";

const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(RPC_URL),
});
const walletClient = createWalletClient({
  account: relayer,
  chain: sepolia,
  transport: http(RPC_URL),
});

function deployment(name: string, network = DEPLOYMENT_NETWORK): Address {
  const raw = readFileSync(
    new URL(`../deployments/${network}/${name}.json`, import.meta.url),
    "utf8",
  );
  return (JSON.parse(raw) as Deployment).address;
}

function deploymentFromEnv(
  envName: string,
  fallbackNames: string[],
  network = DEPLOYMENT_NETWORK,
): Address {
  const envValue = process.env[envName];
  if (envValue) return envValue as Address;

  let lastError: unknown;
  for (const name of fallbackNames) {
    try {
      return deployment(name, network);
    } catch (error) {
      lastError = error;
    }
  }
  throw new Error(
    `${envName} is not set and no fallback deployment (${fallbackNames.join(", ")}) was found in deployments/${network}`,
    { cause: lastError },
  );
}

function v1Deployment(name: string): Address {
  const raw = readFileSync(
    new URL(
      `../lib/ens-contracts/deployments/${V1_DEPLOYMENT_NETWORK}/${name}.json`,
      import.meta.url,
    ),
    "utf8",
  );
  return (JSON.parse(raw) as Deployment).address;
}

function jsonReplacer(_key: string, value: unknown) {
  return typeof value === "bigint" ? value.toString() : value;
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function assertAddressEqual(name: string, actual: Address, expected: Address) {
  if (actual.toLowerCase() !== expected.toLowerCase()) {
    throw new Error(`${name}: expected ${expected}, got ${actual}`);
  }
}

function getEthReverseName(address: Address) {
  return `${address.slice(2).toLowerCase()}.addr.reverse`;
}

async function assertCode(name: string, address: Address) {
  const code = await publicClient.getCode({ address });
  if (!code || code === "0x") {
    throw new Error(`${name} has no code at ${address}`);
  }
}

function computeStandaloneHcaSalt(label: string): bigint {
  return BigInt(keccak256(stringToHex(`StandaloneHCA:${label}`)));
}

function computeOwnedResolverSalt(ownerAddress: Address, version = 0n): bigint {
  return BigInt(
    keccak256(
      encodeAbiParameters(
        [
          { name: "id", type: "bytes32" },
          { name: "owner", type: "address" },
          { name: "version", type: "uint256" },
        ],
        [keccak256(stringToHex("OwnedResolver")), ownerAddress, version],
      ),
    ),
  );
}

function computeVerifiableProxyAddress({
  factoryAddress,
  proxyLogic,
  deployer,
  salt,
}: {
  factoryAddress: Address;
  proxyLogic: Address;
  deployer: Address;
  salt: bigint;
}) {
  const outerSalt = keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }],
      [deployer, salt],
    ),
  );
  const bytecode = concat([
    "0x3d604d80600a3d3981f3363d3d373d3d3d363d73",
    proxyLogic,
    "0x5af43d82803e903d91602b57fd5bf3",
    outerSalt,
  ]);
  return getContractAddress({
    bytecode,
    from: factoryAddress,
    opcode: "CREATE2",
    salt: outerSalt,
  });
}

function encodeHCAInitializeCall(ownerAddress: Address): Hex {
  return encodeFunctionData({
    abi: StandaloneSingleOwnerHCA.abi,
    functionName: "initializeAccount",
    args: [encodeAbiParameters(parseAbiParameters("address"), [ownerAddress])],
  });
}

function buildOperationData(executions: HCAExecution[]): Hex {
  const encodedExecutions = encodeAbiParameters(
    [
      {
        type: "tuple[]",
        components: [
          { name: "target", type: "address" },
          { name: "value", type: "uint256" },
          { name: "callData", type: "bytes" },
        ],
      },
    ],
    [executions],
  );
  return concat(["0x02", "0x01", encodedExecutions]);
}

function getRhinestoneSingleChainOpsTypedData(
  intentExecutor: Address,
  hca: Address,
  element: unknown,
  nonce: bigint,
) {
  if (!RHINESTONE_SDK_SINGLE_CHAIN_OPS) {
    throw new Error("RHINESTONE_SDK_SINGLE_CHAIN_OPS is required");
  }
  const require = createRequire(import.meta.url);
  const { getTypedData } = require(RHINESTONE_SDK_SINGLE_CHAIN_OPS) as {
    getTypedData: (
      account: Address,
      intentExecutorAddress: Address,
      element: unknown,
      nonce: bigint,
    ) => ReturnType<typeof hashTypedData> extends never ? never : unknown;
  };
  return getTypedData(hca, intentExecutor, element, nonce) as Parameters<
    typeof hashTypedData
  >[0];
}

async function main() {
  const chainId = await publicClient.getChainId();
  if (chainId !== sepolia.id) {
    throw new Error(`expected Sepolia chain id ${sepolia.id}, got ${chainId}`);
  }

  let ownerFunding:
    | { transactionHash: Hex; value: bigint; gasUsed: bigint }
    | { skipped: true; targetBalance: bigint; currentBalance: bigint }
    | undefined;
  if (
    HCA_FUND_OWNER_WEI > 0n &&
    relayer.address.toLowerCase() !== owner.address.toLowerCase()
  ) {
    const ownerBalance = await publicClient.getBalance({ address: owner.address });
    if (ownerBalance < HCA_FUND_OWNER_WEI) {
      const value = HCA_FUND_OWNER_WEI - ownerBalance;
      const fundingHash = await walletClient.sendTransaction({
        account: relayer,
        to: owner.address,
        value,
      });
      const fundingReceipt = await publicClient.waitForTransactionReceipt({
        hash: fundingHash,
      });
      if (fundingReceipt.status !== "success") {
        throw new Error(`owner funding failed: ${fundingHash}`);
      }
      ownerFunding = {
        transactionHash: fundingHash,
        value,
        gasUsed: fundingReceipt.gasUsed,
      };
    } else {
      ownerFunding = {
        skipped: true,
        targetBalance: HCA_FUND_OWNER_WEI,
        currentBalance: ownerBalance,
      };
    }
  }

  const deployments = {
    verifiableFactory: deploymentFromEnv(
      "HCA_VERIFIABLE_FACTORY",
      ["VerifiableFactory"],
      HCA_DEPLOYMENT_NETWORK,
    ),
    permissionedResolverImpl: deploymentFromEnv(
      "HCA_PERMISSIONED_RESOLVER_IMPL",
      ["PermissionedResolverImpl"],
      HCA_DEPLOYMENT_NETWORK,
    ),
    ethRegistrar: deployment("ETHRegistrar"),
    ethRegistry: deployment("ETHRegistry"),
    paymentToken: deploymentFromEnv(
      "HCA_PAYMENT_TOKEN",
      ["USDC", "MockUSDC"],
      HCA_DEPLOYMENT_NETWORK,
    ),
    registrationBootstrapper: deploymentFromEnv(
      "HCA_REGISTRATION_BOOTSTRAPPER",
      ["RegistrationBootstrapper"],
      HCA_DEPLOYMENT_NETWORK,
    ),
    standaloneHcaImplementation: deploymentFromEnv(
      "HCA_STANDALONE_HCA_IMPLEMENTATION",
      ["StandaloneHCAImplementation_DefaultReverse", "StandaloneHCAImplementation"],
      HCA_DEPLOYMENT_NETWORK,
    ),
    v1Registry: v1Deployment("ENSRegistry"),
    defaultReverseRegistrar: v1Deployment("DefaultReverseRegistrar"),
    defaultReverseRegistrarAdapter: deploymentFromEnv(
      "HCA_DEFAULT_REVERSE_REGISTRAR_ADAPTER",
      ["DefaultReverseRegistrarHCAAdapter"],
      HCA_DEPLOYMENT_NETWORK,
    ),
    intentExecutor: deploymentFromEnv(
      "HCA_INTENT_EXECUTOR",
      ["IntentExecutor"],
      HCA_DEPLOYMENT_NETWORK,
    ),
    universalResolver: deploymentFromEnv(
      "UNIVERSAL_RESOLVER",
      ["UniversalResolverV2", "UniversalResolver"],
      DEPLOYMENT_NETWORK,
    ),
  };

  await Promise.all([
    assertCode("VerifiableFactory", deployments.verifiableFactory),
    assertCode("PermissionedResolverImpl", deployments.permissionedResolverImpl),
    assertCode("ETHRegistrar", deployments.ethRegistrar),
    assertCode("ETHRegistry", deployments.ethRegistry),
    assertCode("PaymentToken", deployments.paymentToken),
    assertCode("RegistrationBootstrapper", deployments.registrationBootstrapper),
    assertCode("StandaloneHCAImplementation", deployments.standaloneHcaImplementation),
    assertCode("ENSRegistry", deployments.v1Registry),
    assertCode("DefaultReverseRegistrar", deployments.defaultReverseRegistrar),
    assertCode(
      "DefaultReverseRegistrarAdapter",
      deployments.defaultReverseRegistrarAdapter,
    ),
    assertCode("IntentExecutor", deployments.intentExecutor),
    assertCode("UniversalResolver", deployments.universalResolver),
  ]);

  const defaultAdapterController = await publicClient.readContract({
    address: deployments.defaultReverseRegistrar,
    abi: DefaultReverseRegistrar.abi,
    functionName: "controllers",
    args: [deployments.defaultReverseRegistrarAdapter],
  });
  if (!defaultAdapterController) {
    throw new Error(
      `DefaultReverseRegistrarAdapter ${deployments.defaultReverseRegistrarAdapter} is not a default.reverse controller`,
    );
  }
  let defaultAdapterTrustsHcaImplementation: boolean;
  try {
    defaultAdapterTrustsHcaImplementation = (await publicClient.readContract({
      address: deployments.defaultReverseRegistrarAdapter,
      abi: DefaultReverseRegistrarAdapter.abi,
      functionName: "trustedHCAImplementations",
      args: [deployments.standaloneHcaImplementation],
    })) as boolean;
  } catch (error) {
    throw new Error(
      `DefaultReverseRegistrarAdapter ${deployments.defaultReverseRegistrarAdapter} is not HCA-aware; set HCA_DEFAULT_REVERSE_REGISTRAR_ADAPTER or provide DefaultReverseRegistrarHCAAdapter deployment`,
      { cause: error },
    );
  }
  if (!defaultAdapterTrustsHcaImplementation) {
    throw new Error(
      `DefaultReverseRegistrarAdapter ${deployments.defaultReverseRegistrarAdapter} does not trust HCA implementation ${deployments.standaloneHcaImplementation}`,
    );
  }

  const label =
    process.env.HCA_LABEL ??
    `hca${Math.floor(Date.now() / 1000)
      .toString(36)
      .toLowerCase()}`;
  if (!/^[a-z0-9-]+$/.test(label)) {
    throw new Error(`label must be lower-case DNS-safe: ${label}`);
  }

  const proxyLogic = (await publicClient.readContract({
    address: deployments.verifiableFactory,
    abi: VerifiableFactory.abi,
    functionName: "proxyLogic",
  })) as Address;

  const hcaSalt = computeStandaloneHcaSalt(label);
  const hca = computeVerifiableProxyAddress({
    factoryAddress: deployments.verifiableFactory,
    proxyLogic,
    deployer: deployments.registrationBootstrapper,
    salt: hcaSalt,
  });
  const resolverSalt = computeOwnedResolverSalt(hca);
  const resolver = computeVerifiableProxyAddress({
    factoryAddress: deployments.verifiableFactory,
    proxyLogic,
    deployer: hca,
    salt: resolverSalt,
  });
  const labelId = BigInt(keccak256(stringToBytes(label)));
  const node = namehash(`${label}.eth`);
  const reverseName = getEthReverseName(owner.address);
  const reverseNode = namehash(reverseName);

  const stateBefore = (await publicClient.readContract({
    address: deployments.ethRegistry,
    abi: PermissionedRegistry.abi,
    functionName: "getState",
    args: [labelId],
  })) as { status: number | bigint };
  if (Number(stateBefore.status) !== 0) {
    throw new Error(`${label}.eth is not available; status=${stateBefore.status}`);
  }

  const commitment = (await publicClient.readContract({
    address: deployments.ethRegistrar,
    abi: ETHRegistrar.abi,
    functionName: "makeCommitment",
    args: [
      label,
      owner.address,
      zeroHash,
      zeroAddress,
      resolver,
      REGISTRATION_DURATION,
      zeroHash,
    ],
  })) as Hex;

  const deployAndCommitArgs = [
    deployments.verifiableFactory,
    deployments.standaloneHcaImplementation,
    hcaSalt,
    encodeHCAInitializeCall(owner.address),
    deployments.ethRegistrar,
    commitment,
  ] as const;

  const deployAndCommitSimulation = await publicClient.simulateContract({
    account: relayer,
    address: deployments.registrationBootstrapper,
    abi: RegistrationBootstrapper.abi,
    functionName: "deployAndCommit",
    args: deployAndCommitArgs,
  });
  const deployAndCommitHash = await walletClient.writeContract(
    deployAndCommitSimulation.request,
  );
  const deployAndCommitReceipt = await publicClient.waitForTransactionReceipt({
    hash: deployAndCommitHash,
  });
  if (deployAndCommitReceipt.status !== "success") {
    throw new Error(`deployAndCommit failed: ${deployAndCommitHash}`);
  }

  const hcaOwner = (await publicClient.readContract({
    address: hca,
    abi: StandaloneSingleOwnerHCA.abi,
    functionName: "owner",
  })) as Address;
  assertAddressEqual("HCA owner", hcaOwner, owner.address);
  const hcaImplementation = (await publicClient.readContract({
    address: deployments.verifiableFactory,
    abi: VerifiableFactory.abi,
    functionName: "verifyContract",
    args: [hca],
  })) as Address;
  assertAddressEqual(
    "HCA implementation",
    hcaImplementation,
    deployments.standaloneHcaImplementation,
  );

  const [basePrice, premiumPrice] = (await publicClient.readContract({
    address: deployments.ethRegistrar,
    abi: ETHRegistrar.abi,
    functionName: "getRegisterPrice",
    args: [label, REGISTRATION_DURATION, deployments.paymentToken],
  })) as [bigint, bigint];
  const price = basePrice + premiumPrice;

  const hcaPaymentTokenBalanceBefore = (await publicClient.readContract({
    address: deployments.paymentToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [hca],
  })) as bigint;

  let paymentTokenFunding:
    | { transactionHash: Hex; amount: bigint; gasUsed: bigint; mode: "mint" }
    | { skipped: true; currentBalance: bigint; requiredBalance: bigint }
    | undefined;
  let paymentTokenFundingGasUsed = 0n;
  if (hcaPaymentTokenBalanceBefore < price) {
    const shortfall = price - hcaPaymentTokenBalanceBefore;
    if (!HCA_MINT_PAYMENT_TOKEN) {
      throw new Error(
        `HCA ${hca} needs ${shortfall} more payment-token units; pre-fund it or set HCA_MINT_PAYMENT_TOKEN=1 for mintable test tokens`,
      );
    }
    const mintSimulation = await publicClient.simulateContract({
      account: relayer,
      address: deployments.paymentToken,
      abi: mintablePaymentTokenAbi,
      functionName: "mint",
      args: [hca, shortfall],
    });
    const mintHash = await walletClient.writeContract(mintSimulation.request);
    const mintReceipt = await publicClient.waitForTransactionReceipt({
      hash: mintHash,
    });
    if (mintReceipt.status !== "success") {
      throw new Error(`mint failed: ${mintHash}`);
    }
    paymentTokenFunding = {
      transactionHash: mintHash,
      amount: shortfall,
      gasUsed: mintReceipt.gasUsed,
      mode: "mint",
    };
    paymentTokenFundingGasUsed = mintReceipt.gasUsed;
  } else {
    paymentTokenFunding = {
      skipped: true,
      currentBalance: hcaPaymentTokenBalanceBefore,
      requiredBalance: price,
    };
  }

  const commitTime = (await publicClient.readContract({
    address: deployments.ethRegistrar,
    abi: ETHRegistrar.abi,
    functionName: "commitmentAt",
    args: [commitment],
  })) as bigint;
  const minCommitmentAge = (await publicClient.readContract({
    address: deployments.ethRegistrar,
    abi: ETHRegistrar.abi,
    functionName: "MIN_COMMITMENT_AGE",
  })) as bigint;
  const latestBlock = await publicClient.getBlock();
  const validFrom = commitTime + minCommitmentAge;
  if (latestBlock.timestamp <= validFrom) {
    const waitSeconds = Number(validFrom - latestBlock.timestamp + 3n);
    console.log(`waiting ${waitSeconds}s for commitment age`);
    await sleep(waitSeconds * 1000);
  }

  const executions: HCAExecution[] = [
    {
      target: deployments.verifiableFactory,
      value: 0n,
      callData: encodeFunctionData({
        abi: VerifiableFactory.abi,
        functionName: "deployProxy",
        args: [
          deployments.permissionedResolverImpl,
          resolverSalt,
          encodeFunctionData({
            abi: PermissionedResolver.abi,
            functionName: "initialize",
            args: [hca, ROLES_ALL, []],
          }),
        ],
      }),
    },
    {
      target: deployments.paymentToken,
      value: 0n,
      callData: encodeFunctionData({
        abi: erc20Abi,
        functionName: "approve",
        args: [deployments.ethRegistrar, price],
      }),
    },
    {
      target: deployments.ethRegistrar,
      value: 0n,
      callData: encodeFunctionData({
        abi: ETHRegistrar.abi,
        functionName: "register",
        args: [
          label,
          owner.address,
          zeroHash,
          zeroAddress,
          resolver,
          REGISTRATION_DURATION,
          deployments.paymentToken,
          zeroHash,
        ],
      }),
    },
    {
      target: resolver,
      value: 0n,
      callData: encodeFunctionData({
        abi: PermissionedResolver.abi,
        functionName: "setAddr",
        args: [node, COIN_TYPE_ETH, owner.address],
      }),
    },
    {
      target: resolver,
      value: 0n,
      callData: encodeFunctionData({
        abi: PermissionedResolver.abi,
        functionName: "setText",
        args: [node, "url", `https://example.com/${label}`],
      }),
    },
    {
      target: resolver,
      value: 0n,
      callData: encodeFunctionData({
        abi: PermissionedResolver.abi,
        functionName: "setName",
        args: [reverseNode, `${label}.eth`],
      }),
    },
    {
      target: deployments.defaultReverseRegistrarAdapter,
      value: 0n,
      callData: encodeFunctionData({
        abi: DefaultReverseRegistrarAdapter.abi,
        functionName: "setNameWithHCA",
        args: [owner.address, `${label}.eth`],
      }),
    },
  ];

  const operationData = buildOperationData(executions);
  const typedDataElement = {
    mandate: {
      destinationChainId: String(chainId),
      destinationOps: {
        vt: ENTRYPOINT_ERC7579_SIGMODE_ERC1271,
        ops: executions.map((execution) => ({
          to: execution.target,
          value: execution.value,
          data: execution.callData,
        })),
      },
      qualifier: {
        settlementContext: {
          gasRefund: {
            token: zeroAddress,
            exchangeRate: 0n,
            overhead: 0n,
          },
        },
      },
    },
  };
  const nonce = BigInt(Date.now());
  const typedData = getRhinestoneSingleChainOpsTypedData(
    deployments.intentExecutor,
    hca,
    typedDataElement,
    nonce,
  );
  const intentDigest = hashTypedData(typedData);
  const latestForSession = await publicClient.getBlock();
  const validUntil = latestForSession.timestamp + 3600n;
  const permit2Nonce = BigInt(Date.now()) + 17n;
  const permit2Expires = latestForSession.timestamp + 3600n;
  const ownerSignature = await owner.sign({
    hash: permit2SessionDigest({
      chainId: BigInt(chainId),
      hca,
      owner: owner.address,
      sessionKey: sessionKey.address,
      validUntil,
      resolver,
      permit2: {
        sourceChainId: PERMIT2_SOURCE_CHAIN_ID,
        permit2Contract: PERMIT2_ADDRESS,
        arbiter: hca,
        nonce: permit2Nonce,
        expires: permit2Expires,
      },
    }),
  });
  const sessionSignature = await sessionKey.sign({ hash: intentDigest });
  const signatureBody = encodeAbiParameters(
    parseAbiParameters(
      "address,address,uint48,address,uint256,address,address,uint256,uint256,bytes,bytes,bytes",
    ),
    [
      owner.address,
      sessionKey.address,
      Number(validUntil),
      resolver,
      PERMIT2_SOURCE_CHAIN_ID,
      PERMIT2_ADDRESS,
      hca,
      permit2Nonce,
      permit2Expires,
      ownerSignature,
      sessionSignature,
      operationData,
    ],
  );
  const hcaSignature = concat([zeroAddress, signatureBody]);
  const signedOps = {
    account: hca,
    nonce,
    ops: { data: operationData },
    signature: hcaSignature,
  };

  const nonceAlreadyConsumed = await publicClient.readContract({
    address: deployments.intentExecutor,
    abi: intentExecutorAbi,
    functionName: "isStandaloneIntentNonceConsumed",
    args: [nonce, hca],
  });
  if (nonceAlreadyConsumed) {
    throw new Error(`Rhinestone nonce already consumed: ${nonce}`);
  }

  await publicClient.simulateContract({
    account: relayer,
    address: deployments.intentExecutor,
    abi: intentExecutorAbi,
    functionName: "executeSinglechainOps",
    args: [signedOps],
  });
  const estimatedExecuteGas = await publicClient.estimateContractGas({
    account: relayer.address,
    address: deployments.intentExecutor,
    abi: intentExecutorAbi,
    functionName: "executeSinglechainOps",
    args: [signedOps],
  });
  const executeHash = await walletClient.writeContract({
    account: relayer,
    address: deployments.intentExecutor,
    abi: intentExecutorAbi,
    functionName: "executeSinglechainOps",
    args: [signedOps],
    gas: (estimatedExecuteGas * 12n) / 10n,
  });
  const executeReceipt = await publicClient.waitForTransactionReceipt({
    hash: executeHash,
  });
  if (executeReceipt.status !== "success") {
    throw new Error(`executeSinglechainOps failed: ${executeHash}`);
  }

  const stateAfter = (await publicClient.readContract({
    address: deployments.ethRegistry,
    abi: PermissionedRegistry.abi,
    functionName: "getState",
    args: [labelId],
  })) as { status: number | bigint; latestOwner: Address };
  if (Number(stateAfter.status) !== STATUS_REGISTERED) {
    throw new Error(`${label}.eth status=${stateAfter.status}`);
  }
  assertAddressEqual("registered owner", stateAfter.latestOwner, owner.address);

  const registryResolver = (await publicClient.readContract({
    address: deployments.ethRegistry,
    abi: PermissionedRegistry.abi,
    functionName: "getResolver",
    args: [label],
  })) as Address;
  assertAddressEqual("registry resolver", registryResolver, resolver);

  const resolverImplementation = (await publicClient.readContract({
    address: deployments.verifiableFactory,
    abi: VerifiableFactory.abi,
    functionName: "verifyContract",
    args: [resolver],
  })) as Address;
  assertAddressEqual(
    "resolver implementation",
    resolverImplementation,
    deployments.permissionedResolverImpl,
  );

  const resolvedAddress = (await publicClient.readContract({
    address: resolver,
    abi: PermissionedResolver.abi,
    functionName: "addr",
    args: [node],
  })) as Address;
  assertAddressEqual("resolver addr", resolvedAddress, owner.address);
  const url = (await publicClient.readContract({
    address: resolver,
    abi: PermissionedResolver.abi,
    functionName: "text",
    args: [node, "url"],
  })) as string;
  if (url !== `https://example.com/${label}`) {
    throw new Error(`resolver url mismatch: ${url}`);
  }
  const primary = (await publicClient.readContract({
    address: resolver,
    abi: PermissionedResolver.abi,
    functionName: "name",
    args: [reverseNode],
  })) as string;
  if (primary !== `${label}.eth`) {
    throw new Error(`resolver name mismatch: ${primary}`);
  }
  const defaultPrimary = (await publicClient.readContract({
    address: deployments.defaultReverseRegistrar,
    abi: DefaultReverseRegistrar.abi,
    functionName: "nameForAddr",
    args: [owner.address],
  })) as string;
  if (defaultPrimary !== `${label}.eth`) {
    throw new Error(`default reverse name mismatch: ${defaultPrimary}`);
  }
  const exactV1ReverseResolver = (await publicClient.readContract({
    address: deployments.v1Registry,
    abi: ENSRegistry.abi,
    functionName: "resolver",
    args: [reverseNode],
  })) as Address;
  if (
    HCA_EXPECT_DEFAULT_REVERSE_FALLBACK &&
    exactV1ReverseResolver !== zeroAddress
  ) {
    throw new Error(
      `expected no exact v1 reverse resolver, got ${exactV1ReverseResolver}`,
    );
  }

  const [urPrimary, urForwardResolver, urReverseResolver] =
    (await publicClient.readContract({
      address: deployments.universalResolver,
      abi: UniversalResolverV2.abi,
      functionName: "reverse",
      args: [owner.address, COIN_TYPE_ETH],
    })) as [string, Address, Address];
  if (urPrimary !== `${label}.eth`) {
    throw new Error(`UR reverse mismatch: ${urPrimary}`);
  }

  const forwardCall = encodeFunctionData({
    abi: PermissionedResolver.abi,
    functionName: "addr",
    args: [node],
  });
  const [urForwardAnswer, urResolvedResolver] =
    (await publicClient.readContract({
      address: deployments.universalResolver,
      abi: UniversalResolverV2.abi,
      functionName: "resolve",
      args: [dnsEncodeName(`${label}.eth`), forwardCall],
    })) as [Hex, Address];
  const urResolvedAddress = decodeFunctionResult({
    abi: PermissionedResolver.abi,
    functionName: "addr",
    data: urForwardAnswer,
  }) as Address;
  assertAddressEqual("UR forward addr", urResolvedAddress, owner.address);

  const hcaPaymentTokenBalance = (await publicClient.readContract({
    address: deployments.paymentToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [hca],
  })) as bigint;

  const summary = {
    label,
    name: `${label}.eth`,
    owner: owner.address,
    ownerKeySource,
    relayer: relayer.address,
    sessionKey: sessionKey.address,
    sessionKeySource,
    hca,
    resolver,
    intentExecutor: deployments.intentExecutor,
    universalResolver: deployments.universalResolver,
    rhinestoneSdkHelper: RHINESTONE_SDK_SINGLE_CHAIN_OPS,
    deployments,
    commitment,
    price,
    transactions: {
      ownerFunding,
      deployAndCommit: deployAndCommitHash,
      paymentTokenFunding,
      executeSinglechainOps: executeHash,
    },
    gas: {
      deployAndCommit: deployAndCommitReceipt.gasUsed,
      paymentTokenFunding: paymentTokenFundingGasUsed,
      executeSinglechainOps: executeReceipt.gasUsed,
      estimatedExecuteSinglechainOps: estimatedExecuteGas,
      registrationCoreTotal:
        deployAndCommitReceipt.gasUsed + executeReceipt.gasUsed,
      registrationIncludingTokenFunding:
        deployAndCommitReceipt.gasUsed +
        paymentTokenFundingGasUsed +
        executeReceipt.gasUsed,
    },
    verified: {
      hcaOwner,
      hcaImplementation,
      resolverImplementation,
      registryResolver,
      resolvedAddress,
      url,
      reverseName,
      primary,
      defaultPrimary,
      exactV1ReverseResolver,
      urReverse: {
        primary: urPrimary,
        resolver: urForwardResolver,
        reverseResolver: urReverseResolver,
      },
      urForward: {
        resolver: urResolvedResolver,
        address: urResolvedAddress,
      },
      hcaPaymentTokenBalance,
    },
  };

  console.log(JSON.stringify(summary, jsonReplacer, 2));
}

await main();
