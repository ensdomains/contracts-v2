import { readFileSync } from "node:fs";

import {
  RhinestoneSDK,
  type RhinestoneAccount,
  type RhinestoneAccountConfig,
  type Session,
  type SignerSet,
  type StandaloneHcaAccount,
  type Transaction,
} from "@rhinestone/sdk";
import { getPermissionId } from "@rhinestone/sdk/smart-sessions";
import {
  type Address,
  concat,
  createPublicClient,
  createWalletClient,
  decodeFunctionData,
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  getContractAddress,
  type Hex,
  http,
  keccak256,
  namehash,
  parseSignature,
  type PublicClient,
  recoverTypedDataAddress,
  size,
  stringToHex,
  zeroAddress,
  zeroHash,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { arbitrumSepolia, baseSepolia, sepolia } from "viem/chains";

import {
  DefaultReverseRegistrar,
  DefaultReverseRegistrarAdapter,
  ENSRegistry,
  ETHRegistrar,
  OwnerBoundRegistrationSessionValidator,
  PermissionedRegistry,
  PermissionedResolver,
  StandaloneHCADeployer,
  StandaloneSingleOwnerHCA,
  test_mocks_MockERC20_sol_MockERC20 as MockERC20,
  UniversalResolverV2,
  VerifiableFactory,
} from "../generated/artifacts/index.ts";
import { dnsEncodeName } from "../test/utils/utils.ts";

const DEPLOYMENT_NETWORK = process.env.DEPLOYMENT_NETWORK ?? "sepolia";
const HCA_DEPLOYMENT_NETWORK =
  process.env.HCA_DEPLOYMENT_NETWORK ?? DEPLOYMENT_NETWORK;
const V1_DEPLOYMENT_NETWORK = process.env.V1_DEPLOYMENT_NETWORK ?? "sepolia";
const RPC_URL = process.env.SEPOLIA_RPC_URL;
const DEPLOYER_KEY = process.env.DEPLOYER_KEY;
const RHINESTONE_API_KEY =
  process.env.RHINESTONE_API_KEY ??
  process.env.RHINESTONE_SDK_API_KEY ??
  process.env.VITE_RHINESTONE_API_KEY;
const BASE_SEPOLIA_RPC_URL = process.env.BASE_SEPOLIA_RPC_URL;
const ARBITRUM_SEPOLIA_RPC_URL = process.env.ARBITRUM_SEPOLIA_RPC_URL;
const HCA_SOURCE_CHAIN = process.env.HCA_SOURCE_CHAIN ?? "base-sepolia";
const sourceChain = (() => {
  if (HCA_SOURCE_CHAIN === "base-sepolia") return baseSepolia;
  if (HCA_SOURCE_CHAIN === "arbitrum-sepolia") return arbitrumSepolia;
  throw new Error("HCA_SOURCE_CHAIN must be base-sepolia or arbitrum-sepolia");
})();
const SOURCE_RPC_URL =
  process.env.HCA_SOURCE_RPC_URL ??
  (sourceChain.id === baseSepolia.id
    ? BASE_SEPOLIA_RPC_URL
    : ARBITRUM_SEPOLIA_RPC_URL);
const CIRCLE_SOURCE_BLOCKCHAIN =
  sourceChain.id === baseSepolia.id ? "BASE-SEPOLIA" : "ARB-SEPOLIA";
const CIRCLE_API_KEY = process.env.CIRCLE_API_KEY;
const HCA_CROSS_CHAIN = process.env.HCA_CROSS_CHAIN === "1";
const HCA_CROSS_CHAIN_SOURCE = process.env.HCA_CROSS_CHAIN_SOURCE ?? "nexus";
const HCA_CROSS_CHAIN_NEXUS_FUNDING =
  process.env.HCA_CROSS_CHAIN_NEXUS_FUNDING ?? "prefund";
const HCA_SOURCE_APPROVAL_TRANSACTION_HASH = process.env
  .HCA_SOURCE_APPROVAL_TRANSACTION_HASH as Hex | undefined;
const HCA_GENERATE_OWNER = process.env.HCA_GENERATE_OWNER === "1";
const HCA_DRY_RUN_ONLY = process.env.HCA_DRY_RUN_ONLY === "1";
const HCA_SPONSORED = process.env.HCA_SPONSORED !== "0";
const HCA_USER_PAID_USDC = process.env.HCA_USER_PAID_USDC === "1";
const HCA_FEE_ASSET = process.env.HCA_FEE_ASSET as
  | Transaction["feeAsset"]
  | undefined;
const HCA_ALLOW_TARGET_TEST_TOP_UP =
  process.env.HCA_ALLOW_TARGET_TEST_TOP_UP === "1";
const HCA_ALLOW_SOURCE_TEST_TOP_UP =
  process.env.HCA_ALLOW_SOURCE_TEST_TOP_UP === "1";
const HCA_EXPECT_INITIAL_STATE =
  process.env.HCA_EXPECT_INITIAL_STATE ?? "either";
const HCA_EXPECT_DEFAULT_REVERSE_FALLBACK =
  process.env.HCA_EXPECT_DEFAULT_REVERSE_FALLBACK === "1";
const HCA_USER_SALT = process.env.HCA_USER_SALT
  ? BigInt(process.env.HCA_USER_SALT)
  : 0n;

const REGISTRATION_DURATION = 28n * 86400n;
const SESSION_DURATION = 24n * 60n * 60n;
const COIN_TYPE_ETH = 60n;
const STATUS_REGISTERED = 2;
const ROLES_ALL =
  0x1111111111111111111111111111111111111111111111111111111111111111n;
const RHINESTONE_INTENT_EXECUTOR =
  "0x00000000005aD9ce1f5035FD62CA96CEf16AdAAF" as const;
const RHINESTONE_GAS_REFUND_PAYMASTER =
  "0x1d7df6Ddc7328Ac827EB4D7f171C60AFB7f9A599" as const;
const NEXUS_FACTORY = "0x0000000000679A258c64d2F20F310e12B64b7375" as const;
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as const;
const SOURCE_PAYMENT_TOKEN = (process.env.HCA_SOURCE_PAYMENT_TOKEN ??
  (sourceChain.id === baseSepolia.id
    ? "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
    : "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d")) as Address;
const SEPOLIA_USDC = (process.env.HCA_TARGET_PAYMENT_TOKEN ??
  "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238") as Address;
const CROSS_CHAIN_TARGET_AMOUNT = process.env.HCA_CROSS_CHAIN_TARGET_AMOUNT
  ? BigInt(process.env.HCA_CROSS_CHAIN_TARGET_AMOUNT)
  : 14_000_000n;
const CROSS_CHAIN_SOURCE_AMOUNT = process.env.HCA_CROSS_CHAIN_SOURCE_AMOUNT
  ? BigInt(process.env.HCA_CROSS_CHAIN_SOURCE_AMOUNT)
  : 20_000_000n;
const CROSS_CHAIN_DESTINATION_GAS = process.env.HCA_CROSS_CHAIN_DESTINATION_GAS
  ? BigInt(process.env.HCA_CROSS_CHAIN_DESTINATION_GAS)
  : 1_200_000n;
const MODE_ERC1271 = `0x0201${"00".repeat(30)}` as Hex;
const MODE_EMISSARY_EXECUTION = `0x0204${"00".repeat(30)}` as Hex;
const OPERATOR_MAX_FEE_PER_GAS = 500_000_000_000n;
const OPERATOR_MAX_PRIORITY_FEE_PER_GAS = 2_000_000_000n;
const MAX_REFUND_EXCHANGE_RATE = process.env.HCA_MAX_REFUND_EXCHANGE_RATE
  ? BigInt(process.env.HCA_MAX_REFUND_EXCHANGE_RATE)
  : 5_000_000_000n;
const MAX_REFUND_GAS_OVERHEAD = process.env.HCA_MAX_REFUND_GAS_OVERHEAD
  ? BigInt(process.env.HCA_MAX_REFUND_GAS_OVERHEAD)
  : 100_000n;
const MAX_REFUND_AMOUNT = process.env.HCA_MAX_REFUND_AMOUNT
  ? BigInt(process.env.HCA_MAX_REFUND_AMOUNT)
  : 25_000_000n;
const LEGACY_EIP2612_DOMAIN_ABI = [
  {
    type: "function",
    name: "name",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    type: "function",
    name: "version",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    type: "function",
    name: "DOMAIN_SEPARATOR",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "bytes32" }],
  },
] as const;

if (!RPC_URL) throw new Error("SEPOLIA_RPC_URL is required");
if (!DEPLOYER_KEY) throw new Error("DEPLOYER_KEY is required");
if (!RHINESTONE_API_KEY) throw new Error("RHINESTONE_API_KEY is required");
if (HCA_CROSS_CHAIN && !SOURCE_RPC_URL) {
  throw new Error(
    `HCA_SOURCE_RPC_URL or the ${HCA_SOURCE_CHAIN} RPC variable is required for HCA_CROSS_CHAIN=1`,
  );
}
if (!new Set(["new", "existing", "either"]).has(HCA_EXPECT_INITIAL_STATE)) {
  throw new Error("HCA_EXPECT_INITIAL_STATE must be new, existing, or either");
}
if (!new Set(["eoa", "nexus"]).has(HCA_CROSS_CHAIN_SOURCE)) {
  throw new Error("HCA_CROSS_CHAIN_SOURCE must be eoa or nexus");
}
if (
  !new Set(["prefund", "atomic-pull", "permit-pull"]).has(
    HCA_CROSS_CHAIN_NEXUS_FUNDING,
  )
) {
  throw new Error(
    "HCA_CROSS_CHAIN_NEXUS_FUNDING must be prefund, atomic-pull, or permit-pull",
  );
}
if (
  new Set(["atomic-pull", "permit-pull"]).has(HCA_CROSS_CHAIN_NEXUS_FUNDING) &&
  HCA_CROSS_CHAIN_SOURCE !== "nexus"
) {
  throw new Error("pull funding requires a Nexus source account");
}
if (
  HCA_USER_PAID_USDC &&
  (!HCA_CROSS_CHAIN ||
    HCA_CROSS_CHAIN_SOURCE !== "nexus" ||
    HCA_CROSS_CHAIN_NEXUS_FUNDING !== "permit-pull" ||
    HCA_SPONSORED)
) {
  throw new Error(
    "HCA_USER_PAID_USDC=1 requires cross-chain Nexus permit-pull routing with HCA_SPONSORED=0",
  );
}
if (
  MAX_REFUND_EXCHANGE_RATE > (1n << 96n) - 1n ||
  MAX_REFUND_GAS_OVERHEAD > (1n << 48n) - 1n ||
  MAX_REFUND_AMOUNT > (1n << 96n) - 1n
) {
  throw new Error("HCA refund limits exceed the validator field widths");
}

type Deployment = { address: Address };
type Call = { to: Address; value: bigint; data: Hex };
type SameChainWalletFunding = {
  calls: Call[];
  paymentToken: Address;
  hca: Address;
  required: bigint;
  amountPulled: bigint;
  walletBalanceBeforeProvisioning: bigint;
  walletBalanceBeforePull: bigint;
  hcaBalanceBefore: bigint;
  provisionedAmount: bigint;
  provisioningTransactionHash?: Hex;
  provisioningGasUsed: bigint;
  permitSignatureCount: number;
};

function asPrivateKey(value: string): Hex {
  return value.startsWith("0x") ? (value as Hex) : (`0x${value}` as Hex);
}

const generatedOwnerKey = HCA_GENERATE_OWNER ? generatePrivateKey() : undefined;
const rpcUrl = RPC_URL;
const rhinestoneApiKey = RHINESTONE_API_KEY;
const owner = privateKeyToAccount(
  asPrivateKey(process.env.HCA_OWNER_KEY ?? generatedOwnerKey ?? DEPLOYER_KEY),
);
const session = privateKeyToAccount(
  asPrivateKey(process.env.HCA_SESSION_KEY ?? generatePrivateKey()),
);
const relayer = privateKeyToAccount(asPrivateKey(DEPLOYER_KEY));
const ownerKeySource =
  process.env.HCA_OWNER_KEY_SOURCE ??
  (generatedOwnerKey
    ? "generated"
    : process.env.HCA_OWNER_KEY
      ? "HCA_OWNER_KEY"
      : "DEPLOYER_KEY");

const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(RPC_URL),
});
const walletClient = createWalletClient({
  account: relayer,
  chain: sepolia,
  transport: http(RPC_URL),
});
const sourcePublicClient = HCA_CROSS_CHAIN
  ? createPublicClient({
      chain: sourceChain,
      transport: http(SOURCE_RPC_URL!),
    })
  : undefined;
const sourceWalletClient = HCA_CROSS_CHAIN
  ? createWalletClient({
      account: owner,
      chain: sourceChain,
      transport: http(SOURCE_RPC_URL!),
    })
  : undefined;
const sourceProvisionerWalletClient = HCA_CROSS_CHAIN
  ? createWalletClient({
      account: relayer,
      chain: sourceChain,
      transport: http(SOURCE_RPC_URL!),
    })
  : undefined;

function deployment(name: string, network = DEPLOYMENT_NETWORK): Address {
  const raw = readFileSync(
    new URL(`../deployments/${network}/${name}.json`, import.meta.url),
    "utf8",
  );
  return (JSON.parse(raw) as Deployment).address;
}

function deploymentFromEnv(
  envName: string,
  names: string[],
  network = DEPLOYMENT_NETWORK,
): Address {
  if (process.env[envName]) return process.env[envName] as Address;
  for (const name of names) {
    try {
      return deployment(name, network);
    } catch {}
  }
  throw new Error(
    `${envName} is not set and ${names.join(" or ")} is absent from deployments/${network}`,
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

async function eip2612Domain(
  client: PublicClient,
  token: Address,
  chainId: number,
) {
  try {
    const [, name, version, domainChainId, verifyingContract] =
      await client.readContract({
        address: token,
        abi: MockERC20.abi,
        functionName: "eip712Domain",
      });
    if (
      Number(domainChainId) !== chainId ||
      verifyingContract.toLowerCase() !== token.toLowerCase()
    ) {
      throw new Error("payment token returned an unexpected EIP-2612 domain");
    }
    return { name, version, chainId, verifyingContract: token } as const;
  } catch (error) {
    const [name, version, separator] = await Promise.all([
      client.readContract({
        address: token,
        abi: LEGACY_EIP2612_DOMAIN_ABI,
        functionName: "name",
      }),
      client.readContract({
        address: token,
        abi: LEGACY_EIP2612_DOMAIN_ABI,
        functionName: "version",
      }),
      client.readContract({
        address: token,
        abi: LEGACY_EIP2612_DOMAIN_ABI,
        functionName: "DOMAIN_SEPARATOR",
      }),
    ]);
    const expectedSeparator = keccak256(
      encodeAbiParameters(
        [
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "bytes32" },
          { type: "uint256" },
          { type: "address" },
        ],
        [
          keccak256(
            stringToHex(
              "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
            ),
          ),
          keccak256(stringToHex(name)),
          keccak256(stringToHex(version)),
          BigInt(chainId),
          token,
        ],
      ),
    );
    if (separator.toLowerCase() !== expectedSeparator.toLowerCase()) {
      throw new Error(
        "payment token returned an unexpected legacy EIP-2612 domain",
        {
          cause: error,
        },
      );
    }
    return { name, version, chainId, verifyingContract: token } as const;
  }
}

function assertAddress(name: string, actual: Address, expected: Address) {
  if (actual.toLowerCase() !== expected.toLowerCase()) {
    throw new Error(`${name}: expected ${expected}, got ${actual}`);
  }
}

async function assertCode(name: string, address: Address) {
  const code = await publicClient.getCode({ address });
  if (!code || code === "0x")
    throw new Error(`${name} has no code at ${address}`);
}

function ethReverseName(address: Address) {
  return `${address.slice(2).toLowerCase()}.addr.reverse`;
}

function ownedResolverSalt(ownerAddress: Address) {
  return BigInt(
    keccak256(
      encodeAbiParameters(
        [
          { name: "id", type: "bytes32" },
          { name: "owner", type: "address" },
          { name: "version", type: "uint256" },
        ],
        [keccak256(stringToHex("OwnedResolver")), ownerAddress, 0n],
      ),
    ),
  );
}

function verifiableProxyAddress({
  factory,
  proxyLogic,
  deployer,
  salt,
}: {
  factory: Address;
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
    from: factory,
    opcode: "CREATE2",
    salt: outerSalt,
  });
}

async function main() {
  if ((await publicClient.getChainId()) !== sepolia.id) {
    throw new Error(`RPC is not Sepolia (${sepolia.id})`);
  }
  if (
    HCA_CROSS_CHAIN &&
    (await sourcePublicClient!.getChainId()) !== sourceChain.id
  ) {
    throw new Error(
      `source RPC is not ${sourceChain.name} (${sourceChain.id})`,
    );
  }

  const deployments = {
    verifiableFactory: deployment("VerifiableFactory"),
    permissionedResolverImpl: deployment("PermissionedResolverImpl"),
    ethRegistrar: deployment("ETHRegistrar"),
    ethRegistry: deployment("ETHRegistry"),
    paymentToken: deploymentFromEnv("HCA_TEST_PAYMENT_TOKEN", ["MockUSDC"]),
    standaloneHcaDeployer: deploymentFromEnv(
      "HCA_STANDALONE_HCA_DEPLOYER",
      ["StandaloneHCADeployer"],
      HCA_DEPLOYMENT_NETWORK,
    ),
    standaloneHcaImplementation: deploymentFromEnv(
      "HCA_STANDALONE_HCA_IMPLEMENTATION",
      ["StandaloneHCAImplementation"],
      HCA_DEPLOYMENT_NETWORK,
    ),
    validator: deploymentFromEnv(
      "HCA_SESSION_VALIDATOR",
      ["OwnerBoundRegistrationSessionValidator"],
      HCA_DEPLOYMENT_NETWORK,
    ),
    defaultReverseRegistrarAdapter: deploymentFromEnv(
      "HCA_DEFAULT_REVERSE_REGISTRAR_ADAPTER",
      ["DefaultReverseRegistrarHCAAdapter"],
      HCA_DEPLOYMENT_NETWORK,
    ),
    universalResolver: deploymentFromEnv("UNIVERSAL_RESOLVER", [
      "UniversalResolverV2",
      "UniversalResolver",
    ]),
    v1Registry: v1Deployment("ENSRegistry"),
    defaultReverseRegistrar: v1Deployment("DefaultReverseRegistrar"),
    intentExecutor: RHINESTONE_INTENT_EXECUTOR,
    gasRefundPaymaster: RHINESTONE_GAS_REFUND_PAYMASTER,
  };

  await Promise.all(
    Object.entries(deployments).map(([name, address]) =>
      assertCode(name, address),
    ),
  );
  if (
    HCA_CROSS_CHAIN &&
    deployments.paymentToken.toLowerCase() !== SEPOLIA_USDC.toLowerCase()
  ) {
    throw new Error(
      `cross-chain test payment token must be Circle Sepolia USDC ${SEPOLIA_USDC}`,
    );
  }

  const proxyLogic = (await publicClient.readContract({
    address: deployments.verifiableFactory,
    abi: VerifiableFactory.abi,
    functionName: "proxyLogic",
  })) as Address;
  const configuredFactory = (await publicClient.readContract({
    address: deployments.standaloneHcaDeployer,
    abi: StandaloneHCADeployer.abi,
    functionName: "VERIFIABLE_FACTORY",
  })) as Address;
  assertAddress(
    "StandaloneHCADeployer.VERIFIABLE_FACTORY",
    configuredFactory,
    deployments.verifiableFactory,
  );

  const validatorBindings = await Promise.all(
    [
      "DEFAULT_REVERSE_REGISTRAR_HCA_ADAPTER",
      "PERMITTED_RESOLVER_IMPL",
      "ETH_REGISTRAR",
      "VERIFIABLE_FACTORY",
      "PAYMENT_TOKEN",
      "SECONDARY_PAYMENT_TOKEN",
      "INTENT_EXECUTOR",
      "GAS_REFUND_PAYMASTER",
    ].map(
      (functionName) =>
        publicClient.readContract({
          address: deployments.validator,
          abi: OwnerBoundRegistrationSessionValidator.abi,
          functionName: functionName as never,
        }) as Promise<Address>,
    ),
  );
  const [
    boundReverseAdapter,
    boundResolverImpl,
    boundRegistrar,
    boundFactory,
    boundPaymentToken,
    boundSecondaryPaymentToken,
    boundIntentExecutor,
    boundGasRefundPaymaster,
  ] = validatorBindings;
  assertAddress(
    "validator reverse adapter",
    boundReverseAdapter,
    deployments.defaultReverseRegistrarAdapter,
  );
  assertAddress(
    "validator resolver implementation",
    boundResolverImpl,
    deployments.permissionedResolverImpl,
  );
  assertAddress(
    "validator registrar",
    boundRegistrar,
    deployments.ethRegistrar,
  );
  assertAddress(
    "validator factory",
    boundFactory,
    deployments.verifiableFactory,
  );
  assertAddress(
    "validator IntentExecutor",
    boundIntentExecutor,
    deployments.intentExecutor,
  );
  assertAddress(
    "validator gas-refund paymaster",
    boundGasRefundPaymaster,
    deployments.gasRefundPaymaster,
  );
  const paymasterIntentExecutor = (await publicClient.readContract({
    address: deployments.gasRefundPaymaster,
    abi: [
      {
        type: "function",
        name: "INTENT_EXECUTOR",
        stateMutability: "view",
        inputs: [],
        outputs: [{ type: "address" }],
      },
    ],
    functionName: "INTENT_EXECUTOR",
  })) as Address;
  assertAddress(
    "gas-refund paymaster IntentExecutor",
    paymasterIntentExecutor,
    deployments.intentExecutor,
  );
  if (
    ![boundPaymentToken, boundSecondaryPaymentToken].some(
      (token) => token.toLowerCase() === deployments.paymentToken.toLowerCase(),
    )
  ) {
    throw new Error(
      `validator does not permit test payment token ${deployments.paymentToken}`,
    );
  }

  const adapterIsController = await publicClient.readContract({
    address: deployments.defaultReverseRegistrar,
    abi: DefaultReverseRegistrar.abi,
    functionName: "controllers",
    args: [deployments.defaultReverseRegistrarAdapter],
  });
  if (!adapterIsController) {
    throw new Error("HCA reverse adapter is not a default.reverse controller");
  }
  const implementationIsTrusted = await publicClient.readContract({
    address: deployments.defaultReverseRegistrarAdapter,
    abi: DefaultReverseRegistrarAdapter.abi,
    functionName: "trustedHCAImplementations",
    args: [deployments.standaloneHcaImplementation],
  });
  if (!implementationIsTrusted) {
    throw new Error(
      "HCA reverse adapter does not trust the HCA implementation",
    );
  }

  const providerUrls: Record<number, string> = { [sepolia.id]: rpcUrl };
  if (HCA_CROSS_CHAIN) {
    providerUrls[sourceChain.id] = SOURCE_RPC_URL!;
  }
  const sdk = new RhinestoneSDK({
    auth: { mode: "apiKey", apiKey: rhinestoneApiKey },
    provider: {
      type: "custom",
      urls: providerUrls,
    },
    ...(process.env.RHINESTONE_ENDPOINT_URL
      ? { endpointUrl: process.env.RHINESTONE_ENDPOINT_URL }
      : {}),
  });
  const standalone: StandaloneHcaAccount = {
    type: "hca",
    version: "ens-standalone-1.1.0",
    deployer: deployments.standaloneHcaDeployer,
    implementation: deployments.standaloneHcaImplementation,
    validator: deployments.validator,
    verifiableFactory: deployments.verifiableFactory,
    proxyLogic,
    userSalt: HCA_USER_SALT,
  };
  let hcaOwnerSignatureCount = 0;
  const trackedHcaOwner = {
    ...owner,
    signTypedData: (async (parameters: unknown) => {
      hcaOwnerSignatureCount += 1;
      return owner.signTypedData(parameters as never);
    }) as typeof owner.signTypedData,
  };
  const baseAccountConfig: RhinestoneAccountConfig = {
    account: standalone,
    owners: {
      type: "ecdsa",
      accounts: [trackedHcaOwner],
      module: deployments.validator,
    },
    experimental_sessions: {
      enabled: true,
      module: deployments.validator,
    },
  };
  let sourceWalletSignatureCount = 0;
  const countSourceWalletSignature = () => {
    sourceWalletSignatureCount += 1;
  };
  const trackedSignTypedData = (async (parameters: unknown) => {
    countSourceWalletSignature();
    return owner.signTypedData(parameters as never);
  }) as typeof owner.signTypedData;
  const trackedSignMessage = (async (parameters: unknown) => {
    countSourceWalletSignature();
    return owner.signMessage(parameters as never);
  }) as typeof owner.signMessage;
  const trackedSourceOwner = {
    ...owner,
    signTypedData: trackedSignTypedData,
    signMessage: trackedSignMessage,
  };
  const sourceAccount = HCA_CROSS_CHAIN
    ? await sdk.createAccount({
        ...(HCA_CROSS_CHAIN_SOURCE === "eoa"
          ? { account: { type: "eoa" as const }, eoa: trackedSourceOwner }
          : {
              account: { type: "nexus" as const },
              owners: {
                type: "ecdsa" as const,
                accounts: [trackedSourceOwner],
              },
            }),
      })
    : undefined;
  const candidateAccount = await sdk.createAccount(baseAccountConfig);
  const hca = candidateAccount.getAddress();
  const codeBefore = await publicClient.getCode({ address: hca });
  const initiallyDeployed = Boolean(codeBefore && codeBefore !== "0x");
  if (HCA_USER_PAID_USDC && initiallyDeployed) {
    throw new Error("USDC-only proof requires a fresh destination HCA");
  }
  if (
    (HCA_EXPECT_INITIAL_STATE === "new" && initiallyDeployed) ||
    (HCA_EXPECT_INITIAL_STATE === "existing" && !initiallyDeployed)
  ) {
    throw new Error(
      `expected ${HCA_EXPECT_INITIAL_STATE} HCA, got ${initiallyDeployed ? "existing" : "new"} at ${hca}`,
    );
  }
  if (initiallyDeployed) await verifyHca(hca, deployments, owner.address);

  const firstAccount = initiallyDeployed
    ? await sdk.createAccount({
        ...baseAccountConfig,
        initData: { address: hca },
      })
    : candidateAccount;
  const resolverSalt = ownedResolverSalt(hca);
  const resolver = verifiableProxyAddress({
    factory: deployments.verifiableFactory,
    proxyLogic,
    deployer: hca,
    salt: resolverSalt,
  });

  const runId = Date.now().toString(36).toLowerCase();
  const labels = process.env.HCA_LABELS?.split(",") ?? [
    `hca${runId}a`,
    `hca${runId}b`,
  ];
  const secrets: [Hex, Hex] = [generatePrivateKey(), generatePrivateKey()];
  if (
    labels.length !== 2 ||
    labels.some((label) => !/^[a-z0-9-]+$/.test(label))
  ) {
    throw new Error(
      "HCA_LABELS must contain two comma-separated DNS-safe labels",
    );
  }
  await Promise.all(
    labels.map(async (label) => {
      const state = (await publicClient.readContract({
        address: deployments.ethRegistry,
        abi: PermissionedRegistry.abi,
        functionName: "getState",
        args: [BigInt(keccak256(stringToHex(label)))],
      })) as { status: number | bigint };
      if (Number(state.status) !== 0)
        throw new Error(`${label}.eth is unavailable`);
    }),
  );

  const prices = await Promise.all(
    labels.map((label) => registrationPrice(label, deployments)),
  );
  const sameChainFunding = HCA_CROSS_CHAIN
    ? undefined
    : await prepareSameChainWalletFunding({
        hca,
        required: prices[0] + prices[1],
        paymentToken: deployments.paymentToken,
      });

  const latestBlock = await publicClient.getBlock();
  const sessionConfig: Session = {
    chain: sepolia,
    owners: { type: "ecdsa", accounts: [session] },
  };
  const permissionId = getPermissionId(sessionConfig);
  const validUntil = latestBlock.timestamp + SESSION_DURATION;
  const sessionEnabled =
    await firstAccount.experimental_isSessionEnabled(sessionConfig);

  const commitments = await Promise.all(
    labels.map((label, index) =>
      makeCommitment(
        label,
        resolver,
        deployments,
        owner.address,
        secrets[index]!,
      ),
    ),
  );

  if (HCA_CROSS_CHAIN) {
    const preparation = HCA_USER_PAID_USDC
      ? undefined
      : HCA_DRY_RUN_ONLY
        ? {
            phase: "permissionless deploy and commit",
            deploymentTransactionHash: undefined,
            commitTransactionHash: undefined,
            deploymentGasUsed: 0n,
            commitGasUsed: 0n,
            gasUsed: 0n,
            dryRun: true as const,
          }
        : await preparePermissionlessCrossChainRegistration({
            hca,
            initiallyDeployed,
            commitment: commitments[0],
            deployments,
          });

    const recipientAccount = HCA_USER_PAID_USDC
      ? firstAccount
      : await sdk.createAccount({
          ...baseAccountConfig,
          initData: { address: hca },
        });
    if (!HCA_USER_PAID_USDC && !HCA_DRY_RUN_ONLY) {
      await verifyHca(hca, deployments, owner.address);
      await waitForCommitment(commitments[0], deployments.ethRegistrar);
    }

    const crossChainSource = await fundCrossChainSourceAccount({
      wallet: owner.address,
      sourceAccount: sourceAccount!.getAddress(),
      sourceType: HCA_CROSS_CHAIN_SOURCE as "eoa" | "nexus",
      nexusFundingMode: HCA_CROSS_CHAIN_NEXUS_FUNDING as
        | "prefund"
        | "atomic-pull"
        | "permit-pull",
    });
    const firstRegistrationCalls: Call[] = [];
    if (!sessionEnabled) {
      firstRegistrationCalls.push({
        to: deployments.validator,
        value: 0n,
        data: encodeFunctionData({
          abi: OwnerBoundRegistrationSessionValidator.abi,
          functionName: HCA_USER_PAID_USDC
            ? "enableSessionWithRefund"
            : "enableSession",
          args: HCA_USER_PAID_USDC
            ? [
                permissionId,
                session.address,
                Number(validUntil),
                resolver,
                deployments.paymentToken,
                MAX_REFUND_EXCHANGE_RATE,
                Number(MAX_REFUND_GAS_OVERHEAD),
                MAX_REFUND_AMOUNT,
              ]
            : [permissionId, session.address, Number(validUntil), resolver],
        }),
      });
    }
    if (HCA_USER_PAID_USDC) {
      firstRegistrationCalls.push({
        to: deployments.ethRegistrar,
        value: 0n,
        data: encodeFunctionData({
          abi: ETHRegistrar.abi,
          functionName: "commit",
          args: [commitments[0]],
        }),
      });
    } else {
      firstRegistrationCalls.push(
        ...(await registrationCalls({
          label: labels[0],
          price: prices[0],
          hca,
          resolver,
          resolverSalt,
          secret: secrets[0],
          deployments,
        })),
      );
    }

    const firstRegistration = await executeCrossChainRegistration({
      account: sourceAccount!,
      recipient: recipientAccount.config,
      recipientAddress: hca,
      calls: firstRegistrationCalls,
      sourceAmount: crossChainSource.routeSourceAmount,
      sourceCalls: crossChainSource.sourceCalls,
      expectedSourcePull: new Set(["atomic-pull", "permit-pull"]).has(
        HCA_CROSS_CHAIN_NEXUS_FUNDING,
      )
        ? {
            owner: owner.address,
            recipient: crossChainSource.sourceAccount,
            amount: crossChainSource.routeSourceAmount,
          }
        : undefined,
      expectedSourcePermit: HCA_CROSS_CHAIN_NEXUS_FUNDING === "permit-pull",
      expectedSourceSetupOps: HCA_CROSS_CHAIN_SOURCE === "eoa" ? 0 : 1,
      expectedRecipientSetupOps:
        HCA_USER_PAID_USDC && !initiallyDeployed ? 1 : 0,
      expectedSourcePermit2Approval: HCA_CROSS_CHAIN_SOURCE === "nexus",
      sourceType: HCA_CROSS_CHAIN_SOURCE as "eoa" | "nexus",
      signatureCount: () => sourceWalletSignatureCount,
      phase: HCA_USER_PAID_USDC
        ? "new-user cross-chain deploy and commit"
        : "new-user cross-chain registration",
    });
    if (hcaOwnerSignatureCount !== 0) {
      throw new Error(
        `cross-chain registration requested ${hcaOwnerSignatureCount} additional HCA owner signatures`,
      );
    }

    if (!HCA_DRY_RUN_ONLY) {
      if (!("claimTransactionHash" in firstRegistration)) {
        throw new Error("live cross-chain route returned no claim checkpoint");
      }
      console.error(
        JSON.stringify(
          {
            checkpoint: "cross-chain claim and fill confirmed",
            intentId: firstRegistration.intentId,
            claimTransactionHash: firstRegistration.claimTransactionHash,
            fillTransactionHash: firstRegistration.fillTransactionHash,
          },
          jsonReplacer,
        ),
      );
    }

    if (HCA_DRY_RUN_ONLY) {
      console.log(
        JSON.stringify(
          {
            dryRun: true,
            initialState: initiallyDeployed ? "existing" : "new",
            owner: owner.address,
            hca,
            resolver,
            permissionId,
            routes: {
              ...(preparation && { preparation }),
              firstRegistration,
            },
            crossChainSource,
            walletInteractions: {
              sourceFundingTransactions: crossChainSource.walletTransactions,
              sourcePermitSignatures:
                crossChainSource.permitSignatureCount ?? 0,
              permit2Signatures: sourceWalletSignatureCount,
              additionalHcaOwnerSignatures: hcaOwnerSignatureCount,
              total:
                crossChainSource.walletTransactions +
                (crossChainSource.permitSignatureCount ?? 0) +
                sourceWalletSignatureCount +
                hcaOwnerSignatureCount,
            },
          },
          jsonReplacer,
          2,
        ),
      );
      return;
    }

    const [
      walletBalanceAfterClaim,
      sourceAccountBalanceAfterClaim,
      walletNativeBalanceAfterClaim,
      permitNonceAfterClaim,
      walletToSourceAllowanceAfterClaim,
    ] = (await Promise.all([
      sourcePublicClient!.readContract({
        address: SOURCE_PAYMENT_TOKEN,
        abi: MockERC20.abi,
        functionName: "balanceOf",
        args: [owner.address],
      }),
      sourcePublicClient!.readContract({
        address: SOURCE_PAYMENT_TOKEN,
        abi: MockERC20.abi,
        functionName: "balanceOf",
        args: [crossChainSource.sourceAccount],
      }),
      sourcePublicClient!.getBalance({ address: owner.address }),
      sourcePublicClient!.readContract({
        address: SOURCE_PAYMENT_TOKEN,
        abi: MockERC20.abi,
        functionName: "nonces",
        args: [owner.address],
      }),
      sourcePublicClient!.readContract({
        address: SOURCE_PAYMENT_TOKEN,
        abi: MockERC20.abi,
        functionName: "allowance",
        args: [owner.address, crossChainSource.sourceAccount],
      }),
    ])) as [bigint, bigint, bigint, bigint, bigint];
    const sourceClaimState = {
      walletBalanceAfterClaim,
      sourceAccountBalanceAfterClaim,
      walletNativeBalanceAfterClaim,
      permitNonceAfterClaim,
      walletToSourceAllowanceAfterClaim,
    };
    if (
      new Set(["atomic-pull", "permit-pull"]).has(HCA_CROSS_CHAIN_NEXUS_FUNDING)
    ) {
      const expectedWalletBalanceAfterClaim =
        crossChainSource.walletBalanceBefore -
        crossChainSource.routeSourceAmount;
      if (walletBalanceAfterClaim !== expectedWalletBalanceAfterClaim) {
        throw new Error(
          `atomic Nexus pull left ${walletBalanceAfterClaim} source tokens in the wallet; expected ${expectedWalletBalanceAfterClaim}`,
        );
      }
      const expectedSourceResidual =
        crossChainSource.routeSourceAmount -
        firstRegistration.sourcePermit2Amount;
      if (sourceAccountBalanceAfterClaim !== expectedSourceResidual) {
        throw new Error(
          `source Nexus retained ${sourceAccountBalanceAfterClaim} tokens; expected unused budget ${expectedSourceResidual}`,
        );
      }
    }
    if (HCA_CROSS_CHAIN_NEXUS_FUNDING === "permit-pull") {
      if (permitNonceAfterClaim !== crossChainSource.permitNonceBefore! + 1n) {
        throw new Error("source claim did not consume the EIP-2612 permit");
      }
      if (walletToSourceAllowanceAfterClaim !== 0n) {
        throw new Error("source claim did not consume the Nexus allowance");
      }
      if (
        crossChainSource.walletNativeBalance !== 0n ||
        walletNativeBalanceAfterClaim !== 0n
      ) {
        throw new Error("USDC-only source wallet used native gas");
      }
    }

    const sourceAccountCode = await sourcePublicClient!.getCode({
      address: crossChainSource.sourceAccount,
    });
    if (!sourceAccountCode || sourceAccountCode === "0x") {
      throw new Error("cross-chain claim did not deploy the source Nexus");
    }
    if (HCA_USER_PAID_USDC) {
      await verifyHca(hca, deployments, owner.address);
      await waitForCommitment(commitments[0], deployments.ethRegistrar);
    }
    const sessionAccount = await sdk.createAccount({
      ...baseAccountConfig,
      initData: { address: hca },
    });
    if (!(await sessionAccount.experimental_isSessionEnabled(sessionConfig))) {
      throw new Error(
        "fixed HCA session was not enabled by the Permit2-authorized intent",
      );
    }
    const hcaBalanceAfterCrossChain = (await publicClient.readContract({
      address: deployments.paymentToken,
      abi: MockERC20.abi,
      functionName: "balanceOf",
      args: [hca],
    })) as bigint;
    if (
      HCA_USER_PAID_USDC &&
      hcaBalanceAfterCrossChain !== CROSS_CHAIN_TARGET_AMOUNT
    ) {
      throw new Error(
        `cross-chain route funded the HCA with ${hcaBalanceAfterCrossChain}; expected ${CROSS_CHAIN_TARGET_AMOUNT}`,
      );
    }
    const firstReveal = HCA_USER_PAID_USDC
      ? await executeIntent({
          account: sessionAccount,
          calls: await registrationCalls({
            label: labels[0],
            price: prices[0],
            hca,
            resolver,
            resolverSalt,
            secret: secrets[0],
            deployments,
          }),
          signers: {
            type: "experimental_session",
            session: sessionConfig,
            verifyExecutions: true,
          },
          permissionId,
          expectedMode: MODE_ERC1271,
          expectedSetupOps: 0,
          feeToken: deployments.paymentToken,
          protocolTokenSpend: prices[0],
          phase: "new-user reveal",
        })
      : undefined;
    const funding = HCA_USER_PAID_USDC
      ? {
          source: "cross-chain USDC" as const,
          hcaBalanceAfterCrossChain,
          operatorTopUp: 0n,
        }
      : await ensurePaymentTokenFunding(
          hca,
          prices[1],
          deployments.paymentToken,
        );
    await verifyRegistration(
      labels[0],
      hca,
      resolver,
      deployments,
      owner.address,
    );

    const secondCommit = await executeIntent({
      account: sessionAccount,
      calls: [
        {
          to: deployments.ethRegistrar,
          value: 0n,
          data: encodeFunctionData({
            abi: ETHRegistrar.abi,
            functionName: "commit",
            args: [commitments[1]],
          }),
        },
      ],
      signers: {
        type: "experimental_session",
        session: sessionConfig,
        verifyExecutions: true,
      },
      permissionId,
      expectedMode: MODE_ERC1271,
      expectedSetupOps: 0,
      ...(HCA_USER_PAID_USDC && {
        feeToken: deployments.paymentToken,
        protocolTokenSpend: 0n,
      }),
      phase: "existing-user commit",
    });

    await waitForCommitment(commitments[1], deployments.ethRegistrar);
    const secondReveal = await executeIntent({
      account: sessionAccount,
      calls: await registrationCalls({
        label: labels[1],
        price: prices[1],
        hca,
        resolver,
        resolverSalt,
        secret: secrets[1],
        deployments,
      }),
      signers: {
        type: "experimental_session",
        session: sessionConfig,
        verifyExecutions: true,
      },
      permissionId,
      expectedMode: MODE_ERC1271,
      expectedSetupOps: 0,
      ...(HCA_USER_PAID_USDC && {
        feeToken: deployments.paymentToken,
        protocolTokenSpend: prices[1],
      }),
      phase: "existing-user reveal",
    });
    const verified = await verifyRegistration(
      labels[1],
      hca,
      resolver,
      deployments,
      owner.address,
    );

    console.log(
      JSON.stringify(
        {
          initialState: initiallyDeployed ? "existing" : "new",
          names: labels.map((label) => `${label}.eth`),
          owner: owner.address,
          ownerKeySource,
          hca,
          resolver,
          permissionId,
          sdk: "@rhinestone/sdk@1.7.0 (Bun patch)",
          crossChain: {
            sourceChain: sourceChain.id,
            targetChain: sepolia.id,
            sourceToken: SOURCE_PAYMENT_TOKEN,
            targetToken: deployments.paymentToken,
            targetAmount: CROSS_CHAIN_TARGET_AMOUNT,
            source: { ...crossChainSource, ...sourceClaimState },
          },
          walletInteractions: {
            sourceFundingTransactions: crossChainSource.walletTransactions,
            sourcePermitSignatures: crossChainSource.permitSignatureCount ?? 0,
            permit2Signatures: sourceWalletSignatureCount,
            additionalHcaOwnerSignatures: hcaOwnerSignatureCount,
            total:
              crossChainSource.walletTransactions +
              (crossChainSource.permitSignatureCount ?? 0) +
              sourceWalletSignatureCount +
              hcaOwnerSignatureCount,
          },
          flows: {
            newUser: HCA_USER_PAID_USDC
              ? [firstRegistration, firstReveal!]
              : [preparation!, firstRegistration],
            existingUser: [secondCommit, secondReveal],
          },
          gas: {
            newUserRoundTrip: HCA_USER_PAID_USDC
              ? firstRegistration.gasUsed + firstReveal!.gasUsed
              : preparation!.gasUsed + firstRegistration.gasUsed,
            existingUserRoundTrip: secondCommit.gasUsed + secondReveal.gasUsed,
            testWalletTokenProvisioning: 0n,
          },
          funding,
          verified,
        },
        jsonReplacer,
        2,
      ),
    );
    return;
  }

  const firstCommitCalls: Call[] = [...(sameChainFunding?.calls ?? [])];
  if (!sessionEnabled) {
    firstCommitCalls.push({
      to: deployments.validator,
      value: 0n,
      data: encodeFunctionData({
        abi: OwnerBoundRegistrationSessionValidator.abi,
        functionName: "enableSession",
        args: [permissionId, session.address, Number(validUntil), resolver],
      }),
    });
  }
  firstCommitCalls.push({
    to: deployments.ethRegistrar,
    value: 0n,
    data: encodeFunctionData({
      abi: ETHRegistrar.abi,
      functionName: "commit",
      args: [commitments[0]],
    }),
  });

  const firstCommit = await executeIntent({
    account: firstAccount,
    calls: firstCommitCalls,
    expectedMode: MODE_ERC1271,
    expectedSetupOps: initiallyDeployed ? 0 : 1,
    phase: "new-user commit",
  });
  if (hcaOwnerSignatureCount !== 1) {
    throw new Error(
      `new-user commit: expected one HCA owner signature, got ${hcaOwnerSignatureCount}`,
    );
  }
  if (HCA_DRY_RUN_ONLY) {
    const sessionReveal = await executeIntent({
      account: firstAccount,
      calls: await registrationCalls({
        label: labels[0],
        price: prices[0],
        hca,
        resolver,
        resolverSalt,
        secret: secrets[0],
        deployments,
      }),
      signers: {
        type: "experimental_session",
        session: sessionConfig,
        verifyExecutions: true,
      },
      permissionId,
      expectedMode: MODE_ERC1271,
      expectedSetupOps: initiallyDeployed ? 0 : 1,
      phase: "new-user reveal",
    });
    console.log(
      JSON.stringify(
        {
          dryRun: true,
          initialState: initiallyDeployed ? "existing" : "new",
          owner: owner.address,
          hca,
          resolver,
          permissionId,
          routes: { firstCommit, sessionReveal },
          sameChainFunding,
          hcaOwnerSignatureCount,
        },
        jsonReplacer,
        2,
      ),
    );
    return;
  }

  await verifyHca(hca, deployments, owner.address);
  const existingAccount = await sdk.createAccount({
    ...baseAccountConfig,
    initData: { address: hca },
  });
  if (!(await existingAccount.experimental_isSessionEnabled(sessionConfig))) {
    throw new Error("fixed HCA session was not enabled by the first intent");
  }

  const funding = await verifySameChainWalletFunding(sameChainFunding!);

  await waitForCommitment(commitments[0], deployments.ethRegistrar);
  const firstReveal = await executeIntent({
    account: existingAccount,
    calls: await registrationCalls({
      label: labels[0],
      price: prices[0],
      hca,
      resolver,
      resolverSalt,
      secret: secrets[0],
      deployments,
    }),
    signers: {
      type: "experimental_session",
      session: sessionConfig,
      verifyExecutions: true,
    },
    permissionId,
    expectedMode: MODE_ERC1271,
    expectedSetupOps: 0,
    phase: "new-user reveal",
  });
  await verifyRegistration(
    labels[0],
    hca,
    resolver,
    deployments,
    owner.address,
  );

  const secondCommit = await executeIntent({
    account: existingAccount,
    calls: [
      {
        to: deployments.ethRegistrar,
        value: 0n,
        data: encodeFunctionData({
          abi: ETHRegistrar.abi,
          functionName: "commit",
          args: [commitments[1]],
        }),
      },
    ],
    signers: {
      type: "experimental_session",
      session: sessionConfig,
      verifyExecutions: true,
    },
    permissionId,
    expectedMode: MODE_ERC1271,
    expectedSetupOps: 0,
    phase: "existing-user commit",
  });

  await waitForCommitment(commitments[1], deployments.ethRegistrar);
  const secondReveal = await executeIntent({
    account: existingAccount,
    calls: await registrationCalls({
      label: labels[1],
      price: prices[1],
      hca,
      resolver,
      resolverSalt,
      secret: secrets[1],
      deployments,
    }),
    signers: {
      type: "experimental_session",
      session: sessionConfig,
      verifyExecutions: true,
    },
    permissionId,
    expectedMode: MODE_ERC1271,
    expectedSetupOps: 0,
    phase: "existing-user reveal",
  });
  const verified = await verifyRegistration(
    labels[1],
    hca,
    resolver,
    deployments,
    owner.address,
  );

  console.log(
    JSON.stringify(
      {
        initialState: initiallyDeployed ? "existing" : "new",
        names: labels.map((label) => `${label}.eth`),
        owner: owner.address,
        ownerKeySource,
        hca,
        resolver,
        permissionId,
        sdk: "@rhinestone/sdk@1.7.0 (Bun patch)",
        sameChainFunding: funding,
        walletInteractions: {
          paymentPermitSignatures: sameChainFunding!.permitSignatureCount,
          ownerIntentSignatures: hcaOwnerSignatureCount,
          postCommitWalletInteractions: 0,
          total:
            sameChainFunding!.permitSignatureCount + hcaOwnerSignatureCount,
        },
        flows: {
          newUser: [firstCommit, firstReveal],
          existingUser: [secondCommit, secondReveal],
        },
        gas: {
          newUserRoundTrip: firstCommit.gasUsed + firstReveal.gasUsed,
          existingUserRoundTrip: secondCommit.gasUsed + secondReveal.gasUsed,
          testWalletTokenProvisioning: funding.gasUsed,
        },
        verified,
      },
      jsonReplacer,
      2,
    ),
  );
}

async function fundCrossChainSourceAccount({
  wallet,
  sourceAccount,
  sourceType,
  nexusFundingMode,
}: {
  wallet: Address;
  sourceAccount: Address;
  sourceType: "eoa" | "nexus";
  nexusFundingMode: "prefund" | "atomic-pull" | "permit-pull";
}) {
  const walletBalances = async () =>
    Promise.all([
      sourcePublicClient!.getBalance({ address: wallet }),
      sourcePublicClient!.readContract({
        address: SOURCE_PAYMENT_TOKEN,
        abi: MockERC20.abi,
        functionName: "balanceOf",
        args: [wallet],
      }) as Promise<bigint>,
    ]);

  let [walletNativeBalance, walletUsdcBalance] = await walletBalances();
  let circleFaucetRequested = false;
  let provisioningSource = "existing" as "existing" | "circle" | "operator";
  const provisioningTransactionHashes: Hex[] = [];
  let provisioningGasUsed = 0n;
  const requiredSourceAmount =
    nexusFundingMode === "permit-pull"
      ? CROSS_CHAIN_SOURCE_AMOUNT
      : CROSS_CHAIN_TARGET_AMOUNT;
  if (
    (!HCA_USER_PAID_USDC && walletNativeBalance === 0n) ||
    walletUsdcBalance < requiredSourceAmount
  ) {
    if (!CIRCLE_API_KEY) {
      throw new Error(
        "CIRCLE_API_KEY is required to fund the fresh source wallet",
      );
    }
    const response = await fetch("https://api.circle.com/v1/faucet/drips", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${CIRCLE_API_KEY}`,
        "Content-Type": "application/json",
        "X-Request-Id": crypto.randomUUID(),
      },
      body: JSON.stringify({
        address: wallet,
        blockchain: CIRCLE_SOURCE_BLOCKCHAIN,
        native: !HCA_USER_PAID_USDC,
        usdc: true,
        eurc: false,
      }),
    });
    if (response.status === 204) {
      provisioningSource = "circle";
    } else if (response.status === 429) {
      if (!HCA_ALLOW_SOURCE_TEST_TOP_UP) {
        throw new Error(
          "Circle faucet is rate-limited; set HCA_ALLOW_SOURCE_TEST_TOP_UP=1 to fund the test wallet from DEPLOYER_KEY",
        );
      }
      provisioningSource = "operator";
      if (!HCA_USER_PAID_USDC && walletNativeBalance === 0n) {
        const hash = await sourceProvisionerWalletClient!.sendTransaction({
          to: wallet,
          value: 1_000_000_000_000_000n,
        });
        const receipt = await sourcePublicClient!.waitForTransactionReceipt({
          hash,
        });
        if (receipt.status !== "success") {
          throw new Error(`test-wallet native provisioning reverted: ${hash}`);
        }
        provisioningTransactionHashes.push(hash);
        provisioningGasUsed += receipt.gasUsed;
      }
      if (walletUsdcBalance < requiredSourceAmount) {
        const operatorBalance = (await sourcePublicClient!.readContract({
          address: SOURCE_PAYMENT_TOKEN,
          abi: MockERC20.abi,
          functionName: "balanceOf",
          args: [relayer.address],
        })) as bigint;
        const desired = requiredSourceAmount;
        const amount = operatorBalance < desired ? operatorBalance : desired;
        if (amount < requiredSourceAmount) {
          throw new Error(
            `Circle is rate-limited and the operator has ${operatorBalance} USDC units; ${requiredSourceAmount} required`,
          );
        }
        const simulation = await sourcePublicClient!.simulateContract({
          account: relayer,
          address: SOURCE_PAYMENT_TOKEN,
          abi: MockERC20.abi,
          functionName: "transfer",
          args: [wallet, amount],
        });
        const hash = await sourceProvisionerWalletClient!.writeContract(
          simulation.request,
        );
        const receipt = await sourcePublicClient!.waitForTransactionReceipt({
          hash,
        });
        if (receipt.status !== "success") {
          throw new Error(`test-wallet USDC provisioning reverted: ${hash}`);
        }
        provisioningTransactionHashes.push(hash);
        provisioningGasUsed += receipt.gasUsed;
      }
    } else {
      throw new Error(
        `Circle faucet returned ${response.status}: ${await response.text()}`,
      );
    }
    circleFaucetRequested = true;
    for (let attempt = 0; attempt < 24; attempt += 1) {
      [walletNativeBalance, walletUsdcBalance] = await walletBalances();
      if (
        (HCA_USER_PAID_USDC || walletNativeBalance > 0n) &&
        walletUsdcBalance >= requiredSourceAmount
      ) {
        break;
      }
      await Bun.sleep(5_000);
    }
  }
  if (!HCA_USER_PAID_USDC && walletNativeBalance === 0n) {
    throw new Error(
      `fresh source wallet has no ${sourceChain.name} ETH for funding`,
    );
  }
  if (HCA_USER_PAID_USDC && walletNativeBalance !== 0n) {
    throw new Error(
      `USDC-only proof wallet unexpectedly has ${walletNativeBalance} wei on ${sourceChain.name}`,
    );
  }
  if (walletUsdcBalance < requiredSourceAmount) {
    throw new Error(
      `fresh source wallet has ${walletUsdcBalance} USDC units; ${requiredSourceAmount} required`,
    );
  }

  const sourceAccountBalanceBefore = (await sourcePublicClient!.readContract({
    address: SOURCE_PAYMENT_TOKEN,
    abi: MockERC20.abi,
    functionName: "balanceOf",
    args: [sourceAccount],
  })) as bigint;
  const permit2AllowanceBefore = (await sourcePublicClient!.readContract({
    address: SOURCE_PAYMENT_TOKEN,
    abi: MockERC20.abi,
    functionName: "allowance",
    args: [sourceAccount, PERMIT2],
  })) as bigint;
  if (
    sourceType === "nexus" &&
    (sourceAccountBalanceBefore !== 0n || permit2AllowanceBefore !== 0n)
  ) {
    throw new Error(
      "fresh source account already has funds or Permit2 allowance",
    );
  }

  if (sourceType === "eoa") {
    assertAddress("EOA source account", sourceAccount, wallet);
    let fundingTransactionHash: Hex | undefined;
    let fundingGasUsed = 0n;
    let walletTransactions = 0;
    if (permit2AllowanceBefore < walletUsdcBalance) {
      const simulation = await sourcePublicClient!.simulateContract({
        account: owner,
        address: SOURCE_PAYMENT_TOKEN,
        abi: MockERC20.abi,
        functionName: "approve",
        args: [PERMIT2, walletUsdcBalance],
      });
      fundingTransactionHash = await sourceWalletClient!.writeContract(
        simulation.request,
      );
      const receipt = await sourcePublicClient!.waitForTransactionReceipt({
        hash: fundingTransactionHash,
      });
      if (receipt.status !== "success") {
        throw new Error(`Permit2 approval reverted: ${fundingTransactionHash}`);
      }
      assertAddress("Permit2 approval sender", receipt.from, wallet);
      fundingGasUsed = receipt.gasUsed;
      walletTransactions = 1;
    }
    const permit2AllowanceAfter = (await sourcePublicClient!.readContract({
      address: SOURCE_PAYMENT_TOKEN,
      abi: MockERC20.abi,
      functionName: "allowance",
      args: [wallet, PERMIT2],
    })) as bigint;
    if (permit2AllowanceAfter < walletUsdcBalance) {
      throw new Error("EOA Permit2 allowance does not cover the source amount");
    }
    return {
      sourceType,
      wallet,
      sourceAccount,
      circleFaucetRequested,
      provisioningSource,
      provisioningTransactionHashes,
      provisioningGasUsed,
      walletNativeBalance,
      walletBalanceBefore: walletUsdcBalance,
      walletBalanceAfter: walletUsdcBalance,
      sourceAccountBalanceBefore,
      sourceAccountBalanceAfter: walletUsdcBalance,
      routeSourceAmount: walletUsdcBalance,
      sourceCalls: [] as Call[],
      permit2AllowanceBefore,
      permit2AllowanceAfter,
      fundingTransactionHash,
      fundingGasUsed,
      walletTransactions,
      fundingAction: fundingTransactionHash ? "permit2 approval" : "none",
    };
  }

  if (nexusFundingMode === "permit-pull") {
    const permitPullAmount = requiredSourceAmount;
    const [walletToSourceAllowanceBefore, permitNonceBefore, latestBlock] =
      await Promise.all([
        sourcePublicClient!.readContract({
          address: SOURCE_PAYMENT_TOKEN,
          abi: MockERC20.abi,
          functionName: "allowance",
          args: [wallet, sourceAccount],
        }) as Promise<bigint>,
        sourcePublicClient!.readContract({
          address: SOURCE_PAYMENT_TOKEN,
          abi: MockERC20.abi,
          functionName: "nonces",
          args: [wallet],
        }) as Promise<bigint>,
        sourcePublicClient!.getBlock(),
      ]);
    if (walletToSourceAllowanceBefore !== 0n) {
      throw new Error(
        "fresh wallet already has an allowance for the source Nexus",
      );
    }
    const domain = await eip2612Domain(
      sourcePublicClient! as unknown as PublicClient,
      SOURCE_PAYMENT_TOKEN,
      sourceChain.id,
    );
    const permitDeadline = latestBlock.timestamp + SESSION_DURATION;
    const permitSignature = await owner.signTypedData({
      domain,
      types: {
        Permit: [
          { name: "owner", type: "address" },
          { name: "spender", type: "address" },
          { name: "value", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      primaryType: "Permit",
      message: {
        owner: wallet,
        spender: sourceAccount,
        value: permitPullAmount,
        nonce: permitNonceBefore,
        deadline: permitDeadline,
      },
    });
    const { r, s, v, yParity } = parseSignature(permitSignature);
    const permitV = Number(v ?? BigInt(27 + (yParity ?? 0)));
    const permitArgs = [
      wallet,
      sourceAccount,
      permitPullAmount,
      permitDeadline,
      permitV,
      r,
      s,
    ] as const;
    await sourcePublicClient!.simulateContract({
      account: relayer,
      address: SOURCE_PAYMENT_TOKEN,
      abi: MockERC20.abi,
      functionName: "permit",
      args: permitArgs,
    });
    return {
      sourceType,
      wallet,
      sourceAccount,
      nexusFundingMode,
      circleFaucetRequested,
      provisioningSource,
      provisioningTransactionHashes,
      provisioningGasUsed,
      walletNativeBalance,
      walletBalanceBefore: walletUsdcBalance,
      walletBalanceAfter: walletUsdcBalance,
      sourceAccountBalanceBefore,
      sourceAccountBalanceAfter: sourceAccountBalanceBefore,
      routeSourceAmount: permitPullAmount,
      sourceCalls: [
        {
          to: SOURCE_PAYMENT_TOKEN,
          value: 0n,
          data: encodeFunctionData({
            abi: MockERC20.abi,
            functionName: "permit",
            args: permitArgs,
          }),
        },
        {
          to: SOURCE_PAYMENT_TOKEN,
          value: 0n,
          data: encodeFunctionData({
            abi: MockERC20.abi,
            functionName: "transferFrom",
            args: [wallet, sourceAccount, permitPullAmount],
          }),
        },
      ] as Call[],
      permit2AllowanceBefore,
      permit2AllowanceAfter: permit2AllowanceBefore,
      walletToSourceAllowanceBefore,
      walletToSourceAllowanceAfter: walletToSourceAllowanceBefore,
      permitNonceBefore,
      permitDeadline,
      permitSignatureCount: 1,
      fundingTransactionHash: undefined,
      fundingGasUsed: 0n,
      walletTransactions: 0,
      fundingAction: "EIP-2612 permit",
    };
  }

  if (nexusFundingMode === "atomic-pull") {
    const atomicPullAmount = CROSS_CHAIN_TARGET_AMOUNT;
    const walletToSourceAllowanceBefore =
      (await sourcePublicClient!.readContract({
        address: SOURCE_PAYMENT_TOKEN,
        abi: MockERC20.abi,
        functionName: "allowance",
        args: [wallet, sourceAccount],
      })) as bigint;
    let fundingTransactionHash = HCA_SOURCE_APPROVAL_TRANSACTION_HASH;
    let fundingGasUsed = 0n;
    let walletTransactions = fundingTransactionHash ? 1 : 0;
    if (walletToSourceAllowanceBefore < atomicPullAmount) {
      if (fundingTransactionHash) {
        throw new Error(
          "recorded source Nexus approval does not cover the atomic pull",
        );
      }
      const simulation = await sourcePublicClient!.simulateContract({
        account: owner,
        address: SOURCE_PAYMENT_TOKEN,
        abi: MockERC20.abi,
        functionName: "approve",
        args: [sourceAccount, atomicPullAmount],
      });
      fundingTransactionHash = await sourceWalletClient!.writeContract(
        simulation.request,
      );
      const receipt = await sourcePublicClient!.waitForTransactionReceipt({
        hash: fundingTransactionHash,
      });
      if (receipt.status !== "success") {
        throw new Error(
          `source Nexus approval reverted: ${fundingTransactionHash}`,
        );
      }
      assertAddress("source Nexus approval sender", receipt.from, wallet);
      fundingGasUsed = receipt.gasUsed;
      walletTransactions = 1;
    } else if (fundingTransactionHash) {
      const [receipt, transaction] = await Promise.all([
        sourcePublicClient!.getTransactionReceipt({
          hash: fundingTransactionHash,
        }),
        sourcePublicClient!.getTransaction({ hash: fundingTransactionHash }),
      ]);
      if (receipt.status !== "success") {
        throw new Error(
          `recorded source Nexus approval reverted: ${fundingTransactionHash}`,
        );
      }
      assertAddress(
        "recorded source Nexus approval sender",
        receipt.from,
        wallet,
      );
      assertAddress(
        "recorded source Nexus approval token",
        transaction.to!,
        SOURCE_PAYMENT_TOKEN,
      );
      const decoded = decodeFunctionData({
        abi: MockERC20.abi,
        data: transaction.input,
      });
      if (
        decoded.functionName !== "approve" ||
        decoded.args[0].toLowerCase() !== sourceAccount.toLowerCase() ||
        decoded.args[1] < atomicPullAmount
      ) {
        throw new Error(
          "recorded transaction is not the required source Nexus approval",
        );
      }
      fundingGasUsed = receipt.gasUsed;
    }
    let walletToSourceAllowanceAfter = walletToSourceAllowanceBefore;
    for (let attempt = 0; attempt < 12; attempt += 1) {
      walletToSourceAllowanceAfter = (await sourcePublicClient!.readContract({
        address: SOURCE_PAYMENT_TOKEN,
        abi: MockERC20.abi,
        functionName: "allowance",
        args: [wallet, sourceAccount],
      })) as bigint;
      if (walletToSourceAllowanceAfter >= atomicPullAmount) break;
      await Bun.sleep(1_000);
    }
    if (walletToSourceAllowanceAfter < atomicPullAmount) {
      throw new Error("wallet allowance does not cover the atomic Nexus pull");
    }
    return {
      sourceType,
      wallet,
      sourceAccount,
      nexusFundingMode,
      circleFaucetRequested,
      provisioningSource,
      provisioningTransactionHashes,
      provisioningGasUsed,
      walletNativeBalance,
      walletBalanceBefore: walletUsdcBalance,
      walletBalanceAfter: walletUsdcBalance,
      sourceAccountBalanceBefore,
      sourceAccountBalanceAfter: sourceAccountBalanceBefore,
      routeSourceAmount: atomicPullAmount,
      sourceCalls: [
        {
          to: SOURCE_PAYMENT_TOKEN,
          value: 0n,
          data: encodeFunctionData({
            abi: MockERC20.abi,
            functionName: "transferFrom",
            args: [wallet, sourceAccount, atomicPullAmount],
          }),
        },
      ] as Call[],
      permit2AllowanceBefore,
      permit2AllowanceAfter: permit2AllowanceBefore,
      walletToSourceAllowanceBefore,
      walletToSourceAllowanceAfter,
      fundingTransactionHash,
      fundingGasUsed,
      walletTransactions,
      resumedAfterApproval: HCA_SOURCE_APPROVAL_TRANSACTION_HASH !== undefined,
      fundingAction: fundingTransactionHash
        ? "source account approval"
        : "none",
    };
  }

  const simulation = await sourcePublicClient!.simulateContract({
    account: owner,
    address: SOURCE_PAYMENT_TOKEN,
    abi: MockERC20.abi,
    functionName: "transfer",
    args: [sourceAccount, walletUsdcBalance],
  });
  const fundingTransactionHash = await sourceWalletClient!.writeContract(
    simulation.request,
  );
  const receipt = await sourcePublicClient!.waitForTransactionReceipt({
    hash: fundingTransactionHash,
  });
  if (receipt.status !== "success") {
    throw new Error(
      `source-account funding reverted: ${fundingTransactionHash}`,
    );
  }
  assertAddress("source-account funding sender", receipt.from, wallet);

  let walletBalanceAfter = walletUsdcBalance;
  let sourceAccountBalanceAfter = sourceAccountBalanceBefore;
  for (let attempt = 0; attempt < 12; attempt += 1) {
    [, walletBalanceAfter] = await walletBalances();
    sourceAccountBalanceAfter = (await sourcePublicClient!.readContract({
      address: SOURCE_PAYMENT_TOKEN,
      abi: MockERC20.abi,
      functionName: "balanceOf",
      args: [sourceAccount],
    })) as bigint;
    if (
      walletBalanceAfter === 0n &&
      sourceAccountBalanceAfter - sourceAccountBalanceBefore ===
        walletUsdcBalance
    ) {
      break;
    }
    await Bun.sleep(1_000);
  }
  if (
    walletBalanceAfter !== 0n ||
    sourceAccountBalanceAfter - sourceAccountBalanceBefore !== walletUsdcBalance
  ) {
    throw new Error(
      "source-account funding balances do not match the wallet transfer",
    );
  }

  return {
    sourceType,
    wallet,
    sourceAccount,
    circleFaucetRequested,
    provisioningSource,
    provisioningTransactionHashes,
    provisioningGasUsed,
    walletNativeBalance,
    walletBalanceBefore: walletUsdcBalance,
    walletBalanceAfter,
    sourceAccountBalanceBefore,
    sourceAccountBalanceAfter,
    routeSourceAmount: sourceAccountBalanceAfter,
    sourceCalls: [] as Call[],
    permit2AllowanceBefore,
    permit2AllowanceAfter: permit2AllowanceBefore,
    fundingTransactionHash,
    fundingGasUsed: receipt.gasUsed,
    walletTransactions: 1,
    fundingAction: "source account transfer",
  };
}

async function debugFillFailure(context: unknown) {
  type StateOverride = {
    address: Address;
    balance?: string;
    stateDiff?: { slot: Hex; value: Hex }[];
  };
  type FillSimulation = {
    action: string;
    call?: { to: Address; data: Hex; value: string };
    details?: {
      blockNumber: string;
      relayer: Address;
      stateOverride: StateOverride[];
    };
  };
  type TraceNode = {
    to?: Address;
    input?: Hex;
    output?: Hex;
    error?: string;
    revertReason?: string;
    type?: string;
    calls?: TraceNode[];
  };

  const simulations = (context as { simulations?: FillSimulation[] })
    .simulations;
  const fill = simulations?.find(({ action }) => action === "fill");
  if (!fill?.call || !fill.details) return undefined;
  const stateOverrides = Object.fromEntries(
    fill.details.stateOverride.map(({ address, balance, stateDiff }) => [
      address,
      {
        ...(balance && { balance: `0x${BigInt(balance).toString(16)}` }),
        ...(stateDiff && {
          stateDiff: Object.fromEntries(
            stateDiff.map(({ slot, value }) => [slot, value]),
          ),
        }),
      },
    ]),
  );
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "debug_traceCall",
      params: [
        {
          from: fill.details.relayer,
          to: fill.call.to,
          data: fill.call.data,
          value: `0x${BigInt(fill.call.value).toString(16)}`,
        },
        `0x${BigInt(fill.details.blockNumber).toString(16)}`,
        { tracer: "callTracer", stateOverrides },
      ],
    }),
  });
  const body = (await response.json()) as {
    result?: TraceNode;
    error?: unknown;
  };
  if (!body.result) return body.error;

  const failurePath = [];
  let node: TraceNode | undefined = body.result;
  while (node) {
    failurePath.push({
      type: node.type,
      to: node.to,
      selector: node.input?.slice(0, 10),
      error: node.error,
      revertReason: node.revertReason,
      output: node.output?.slice(0, 10),
    });
    node = node.calls?.find((call) => call.error || call.revertReason);
  }
  return failurePath;
}

async function executeCrossChainRegistration({
  account,
  recipient,
  recipientAddress,
  calls,
  sourceAmount,
  sourceCalls,
  expectedSourcePull,
  expectedSourcePermit,
  expectedSourceSetupOps,
  expectedRecipientSetupOps,
  expectedSourcePermit2Approval,
  sourceType,
  signatureCount,
  phase,
}: {
  account: RhinestoneAccount;
  recipient: RhinestoneAccountConfig;
  recipientAddress: Address;
  calls: Call[];
  sourceAmount: bigint;
  sourceCalls: Call[];
  expectedSourcePull?: {
    owner: Address;
    recipient: Address;
    amount: bigint;
  };
  expectedSourcePermit: boolean;
  expectedSourceSetupOps: number;
  expectedRecipientSetupOps: number;
  expectedSourcePermit2Approval: boolean;
  sourceType: "eoa" | "nexus";
  signatureCount: () => number;
  phase: string;
}) {
  const transaction: Transaction = {
    sourceChains: [sourceChain],
    targetChain: sepolia,
    recipient,
    calls,
    gasLimit: CROSS_CHAIN_DESTINATION_GAS,
    tokenRequests: [
      { address: SEPOLIA_USDC, amount: CROSS_CHAIN_TARGET_AMOUNT },
    ],
    sourceAssets: [
      {
        chain: sourceChain,
        address: SOURCE_PAYMENT_TOKEN,
        amount: sourceAmount,
      },
    ],
    auxiliaryFunds: {
      [sourceChain.id]: { [SOURCE_PAYMENT_TOKEN]: sourceAmount },
    },
    ...(sourceCalls.length > 0 && {
      sourceCalls: { [sourceChain.id]: sourceCalls },
    }),
    settlementLayers: ["ACROSS"],
    ...(!HCA_SPONSORED && { feeAsset: HCA_FEE_ASSET ?? "USDC" }),
    sponsored: HCA_SPONSORED
      ? { gas: true, bridging: true, swaps: true }
      : { gas: false, bridging: false, swaps: false },
  };
  const prepared = await account.prepareTransaction(transaction);
  const metadata = prepared.intentRoute.intentOp.signedMetadata;
  let sourcePermit2Amount = 0n;
  if (metadata.account.setupOps.length !== expectedSourceSetupOps) {
    throw new Error(
      `${phase}: expected ${expectedSourceSetupOps} source setup ops, got ${metadata.account.setupOps.length}`,
    );
  }
  if (
    expectedSourceSetupOps === 1 &&
    metadata.account.setupOps[0]?.to.toLowerCase() !==
      NEXUS_FACTORY.toLowerCase()
  ) {
    throw new Error(`${phase}: source setup does not call the Nexus factory`);
  }
  if (!metadata.recipient) {
    throw new Error(`${phase}: HCA recipient metadata is missing`);
  }
  if (metadata.recipient.setupOps.length !== expectedRecipientSetupOps) {
    throw new Error(
      `${phase}: expected ${expectedRecipientSetupOps} recipient setup ops, got ${metadata.recipient.setupOps.length}`,
    );
  }
  if (
    expectedRecipientSetupOps === 1 &&
    metadata.recipient.setupOps[0]?.to.toLowerCase() !==
      (recipient.account as StandaloneHcaAccount).deployer.toLowerCase()
  ) {
    throw new Error(
      `${phase}: recipient setup does not call StandaloneHCADeployer`,
    );
  }
  let targetMode: Hex | undefined;
  for (const element of prepared.intentRoute.intentOp.elements) {
    const context = element.mandate.qualifier.settlementContext;
    if (
      context.settlementLayer !== "ACROSS" ||
      context.fundingMethod !== "PERMIT2" ||
      context.using7579 !== true
    ) {
      throw new Error(
        `${phase}: expected ACROSS + PERMIT2 through ERC-7579, got ${context.settlementLayer} + ${context.fundingMethod} (using7579=${context.using7579})`,
      );
    }
    if (
      element.mandate.recipient.toLowerCase() !== recipientAddress.toLowerCase()
    ) {
      throw new Error(`${phase}: target recipient is not the standalone HCA`);
    }
    const mode = element.mandate.destinationOps.vt;
    if (mode.toLowerCase() !== MODE_ERC1271.toLowerCase()) {
      throw new Error(
        `${phase}: target HCA does not use ERC-1271 mode (${mode})`,
      );
    }
    const permit2Approval = element.mandate.preClaimOps.ops.find((op) => {
      if (op.to.toLowerCase() !== SOURCE_PAYMENT_TOKEN.toLowerCase())
        return false;
      try {
        const decoded = decodeFunctionData({
          abi: MockERC20.abi,
          data: op.data,
        });
        return (
          decoded.functionName === "approve" &&
          decoded.args[0].toLowerCase() === PERMIT2.toLowerCase() &&
          decoded.args[1] > 0n
        );
      } catch {
        return false;
      }
    });
    if (Boolean(permit2Approval) !== expectedSourcePermit2Approval) {
      throw new Error(
        `${phase}: source Permit2 approval presence does not match ${sourceType} routing`,
      );
    }
    const sourcePull = element.mandate.preClaimOps.ops.find((op) => {
      if (op.to.toLowerCase() !== SOURCE_PAYMENT_TOKEN.toLowerCase())
        return false;
      try {
        const decoded = decodeFunctionData({
          abi: MockERC20.abi,
          data: op.data,
        });
        return (
          decoded.functionName === "transferFrom" &&
          expectedSourcePull !== undefined &&
          decoded.args[0].toLowerCase() ===
            expectedSourcePull.owner.toLowerCase() &&
          decoded.args[1].toLowerCase() ===
            expectedSourcePull.recipient.toLowerCase() &&
          decoded.args[2] === expectedSourcePull.amount
        );
      } catch {
        return false;
      }
    });
    const sourcePermit = element.mandate.preClaimOps.ops.find((op) => {
      if (op.to.toLowerCase() !== SOURCE_PAYMENT_TOKEN.toLowerCase())
        return false;
      try {
        const decoded = decodeFunctionData({
          abi: MockERC20.abi,
          data: op.data,
        });
        return (
          decoded.functionName === "permit" &&
          expectedSourcePull !== undefined &&
          decoded.args[0].toLowerCase() ===
            expectedSourcePull.owner.toLowerCase() &&
          decoded.args[1].toLowerCase() ===
            expectedSourcePull.recipient.toLowerCase() &&
          decoded.args[2] === expectedSourcePull.amount
        );
      } catch {
        return false;
      }
    });
    if (Boolean(sourcePermit) !== expectedSourcePermit) {
      throw new Error(
        `${phase}: EIP-2612 source permit presence does not match the requested route`,
      );
    }
    if (Boolean(sourcePull) !== Boolean(expectedSourcePull)) {
      throw new Error(
        `${phase}: atomic wallet-to-Nexus pull is missing from the signed pre-claim operations`,
      );
    }
    if (expectedSourcePull) {
      const tokenMask = (1n << 160n) - 1n;
      const elementPermit2Amount = element.idsAndAmounts.reduce(
        (total, [id, amount]) => {
          const token = `0x${(BigInt(id) & tokenMask)
            .toString(16)
            .padStart(40, "0")}`;
          return token.toLowerCase() === SOURCE_PAYMENT_TOKEN.toLowerCase()
            ? total + BigInt(amount)
            : total;
        },
        0n,
      );
      sourcePermit2Amount += elementPermit2Amount;
      if (elementPermit2Amount > expectedSourcePull.amount) {
        throw new Error(
          `${phase}: signed Permit2 amount ${elementPermit2Amount} exceeds source budget ${expectedSourcePull.amount}`,
        );
      }
    }
    targetMode ??= mode;
    const routedCalls = element.mandate.destinationOps.ops;
    if (routedCalls.length !== calls.length) {
      throw new Error(
        `${phase}: wallet mandate contains ${routedCalls.length} target calls, expected ${calls.length}`,
      );
    }
    for (const [index, call] of calls.entries()) {
      const routed = routedCalls[index]!;
      if (
        routed.to.toLowerCase() !== call.to.toLowerCase() ||
        BigInt(routed.value) !== call.value ||
        routed.data.toLowerCase() !== call.data.toLowerCase()
      ) {
        throw new Error(
          `${phase}: target call ${index} changed during routing`,
        );
      }
    }
  }
  if (
    expectedSourcePull &&
    (sourcePermit2Amount === 0n ||
      sourcePermit2Amount > expectedSourcePull.amount)
  ) {
    throw new Error(
      `${phase}: signed Permit2 amount ${sourcePermit2Amount} is outside source budget ${expectedSourcePull.amount}`,
    );
  }

  const signaturesBefore = signatureCount();
  const signed = await account.signTransaction(prepared);
  const signaturesUsed = signatureCount() - signaturesBefore;
  if (signaturesUsed !== 1 || signed.originSignatures.length !== 1) {
    throw new Error(
      `${phase}: expected one wallet signature, used ${signaturesUsed} for ${signed.originSignatures.length} origin signatures`,
    );
  }
  const originSignature = signed.originSignatures[0];
  if (typeof originSignature !== "string") {
    throw new Error(`${phase}: Permit2 signature is not a byte string`);
  }
  const ownerSignature =
    sourceType === "eoa"
      ? originSignature
      : (`0x${originSignature.slice(42)}` as Hex);
  const expectedDestinationSignature = concat([zeroAddress, ownerSignature]);
  if (
    size(ownerSignature) !== 65 ||
    (sourceType === "nexus" &&
      (size(originSignature) !== 85 ||
        !originSignature.toLowerCase().startsWith(zeroAddress))) ||
    size(signed.destinationSignature) !== 85 ||
    signed.destinationSignature.toLowerCase() !==
      expectedDestinationSignature.toLowerCase()
  ) {
    throw new Error(`${phase}: target HCA did not reuse the Permit2 signature`);
  }
  if (signed.targetExecutionSignature) {
    throw new Error(`${phase}: SDK requested a second target signature`);
  }
  const messages = account.getTransactionMessages(prepared);
  if (messages.origin.length !== 1) {
    throw new Error(`${phase}: expected one Permit2 typed-data message`);
  }
  const recovered = await recoverTypedDataAddress({
    ...messages.origin[0]!,
    signature: ownerSignature,
  });
  assertAddress(`${phase} Permit2 signer`, recovered, owner.address);

  const route = {
    phase,
    intentId: prepared.intentRoute.intentOp.nonce,
    sourceSetupOps: metadata.account.setupOps.length,
    recipientSetupOps: metadata.recipient.setupOps.length,
    sourceWalletSignatures: signaturesUsed,
    destinationReusesPermit2Signature: true,
    sourcePullViaNexus: expectedSourcePull !== undefined,
    sourcePermitViaEip2612: expectedSourcePermit,
    sourcePullAmount: expectedSourcePull?.amount ?? 0n,
    sourcePermit2Amount,
    using7579: true,
    mode: targetMode!,
    settlementLayer: "ACROSS" as const,
    fundingMethod: "PERMIT2" as const,
    sponsored: HCA_SPONSORED,
    feeAsset: HCA_FEE_ASSET ?? "USDC",
    fees: metadata.fees,
    sourceSpends: prepared.intentRoute.intentOp.elements.map((element) => ({
      spendTokens: element.spendTokens,
      idsAndAmounts: element.idsAndAmounts,
    })),
  };
  if (HCA_DRY_RUN_ONLY) {
    return {
      ...route,
      dryRun: true as const,
      gasUsed: 0n,
    };
  }

  let result;
  try {
    result = await account.submitTransaction(signed, []);
  } catch (error) {
    const context = (
      error as {
        _context?: unknown;
        _traceId?: string;
      }
    )._context;
    const traceId = (error as { _traceId?: string })._traceId;
    const trace = await debugFillFailure(context).catch((traceError) => ({
      traceError: String(traceError),
    }));
    throw new Error(
      `${phase}: submit simulation failed${traceId ? ` (${traceId})` : ""}${trace ? `: ${JSON.stringify(trace)}` : ""}`,
    );
  }
  const status = await account.waitForExecution(result, false);
  if (!status.fill.hash || status.fill.chainId !== sepolia.id) {
    throw new Error(`${phase}: target fill is missing or on the wrong chain`);
  }
  if (
    status.claims.length !== 1 ||
    !status.claims[0]?.hash ||
    status.claims[0].chainId !== sourceChain.id
  ) {
    throw new Error(`${phase}: expected one ${sourceChain.name} claim`);
  }
  const [claimReceipt, fillReceipt] = await Promise.all([
    sourcePublicClient!.waitForTransactionReceipt({
      hash: status.claims[0].hash,
    }),
    publicClient.waitForTransactionReceipt({ hash: status.fill.hash }),
  ]);
  if (claimReceipt.status !== "success" || fillReceipt.status !== "success") {
    throw new Error(`${phase}: claim or fill reverted`);
  }
  return {
    ...route,
    intentId: result.id,
    claimTransactionHash: status.claims[0].hash,
    fillTransactionHash: status.fill.hash,
    claimGasUsed: claimReceipt.gasUsed,
    fillGasUsed: fillReceipt.gasUsed,
    gasUsed: claimReceipt.gasUsed + fillReceipt.gasUsed,
  };
}

async function executeIntent({
  account,
  calls,
  signers,
  permissionId,
  expectedMode,
  expectedSetupOps,
  feeToken,
  protocolTokenSpend = 0n,
  phase,
}: {
  account: RhinestoneAccount;
  calls: Call[];
  signers?: SignerSet;
  permissionId?: Hex;
  expectedMode: Hex;
  expectedSetupOps: number;
  feeToken?: Address;
  protocolTokenSpend?: bigint;
  phase: string;
}) {
  const transaction: Transaction = {
    chain: sepolia,
    calls,
    signers,
    ...(!HCA_SPONSORED && { feeAsset: HCA_FEE_ASSET ?? "USDC" }),
    sponsored: HCA_SPONSORED
      ? { gas: true, bridging: true, swaps: true }
      : { gas: false, bridging: false, swaps: false },
  };
  const prepared = await account.prepareTransaction(transaction);
  const setupOps =
    prepared.intentRoute.intentOp.signedMetadata.account.setupOps;
  const gasRefunds = prepared.intentRoute.intentOp.elements.map(
    (element) =>
      element.mandate.qualifier.settlementContext.gasRefund ?? {
        token: zeroAddress,
        exchangeRate: 0n,
        overhead: 0n,
      },
  );
  const hasGasRefund = gasRefunds.some(
    ({ token, exchangeRate, overhead }) =>
      token.toLowerCase() !== zeroAddress ||
      BigInt(exchangeRate) !== 0n ||
      BigInt(overhead) !== 0n,
  );
  if (HCA_USER_PAID_USDC) {
    if (!feeToken || !hasGasRefund) {
      throw new Error(`${phase}: unsponsored session route has no USDC refund`);
    }
    for (const refund of gasRefunds) {
      const exchangeRate = BigInt(refund.exchangeRate);
      const packedOverhead = BigInt(refund.overhead);
      const refundAmount = packedOverhead >> 128n;
      const gasOverhead = packedOverhead & ((1n << 128n) - 1n);
      if (
        refund.token.toLowerCase() !== feeToken.toLowerCase() ||
        exchangeRate === 0n ||
        exchangeRate > MAX_REFUND_EXCHANGE_RATE ||
        refundAmount === 0n ||
        refundAmount > MAX_REFUND_AMOUNT ||
        gasOverhead > MAX_REFUND_GAS_OVERHEAD
      ) {
        throw new Error(
          `${phase}: refund ${JSON.stringify(
            {
              token: refund.token,
              exchangeRate,
              refundAmount,
              gasOverhead,
            },
            jsonReplacer,
          )} exceeds limits ${JSON.stringify(
            {
              token: feeToken,
              maxExchangeRate: MAX_REFUND_EXCHANGE_RATE,
              maxRefundAmount: MAX_REFUND_AMOUNT,
              maxGasOverhead: MAX_REFUND_GAS_OVERHEAD,
            },
            jsonReplacer,
          )}`,
        );
      }
    }
  }
  const paymentMetadata = {
    sponsor: prepared.intentRoute.intentOp.sponsor,
    fees: prepared.intentRoute.intentOp.signedMetadata.fees,
    elements: prepared.intentRoute.intentOp.elements.map((element) => ({
      fundingMethod: element.mandate.qualifier.settlementContext.fundingMethod,
      subsidizedAmount:
        element.mandate.qualifier.settlementContext.subsidizedAmount,
      spendTokens: element.spendTokens,
      idsAndAmounts: element.idsAndAmounts,
    })),
  };
  if (setupOps.length !== expectedSetupOps) {
    throw new Error(
      `${phase}: expected ${expectedSetupOps} setup ops, got ${setupOps.length}`,
    );
  }
  if (
    expectedSetupOps === 1 &&
    setupOps[0].to.toLowerCase() !==
      (account.config.account as StandaloneHcaAccount).deployer.toLowerCase()
  ) {
    throw new Error(`${phase}: setup op does not call StandaloneHCADeployer`);
  }
  for (const element of prepared.intentRoute.intentOp.elements) {
    if (element.mandate.destinationOps.vt.toLowerCase() !== expectedMode) {
      throw new Error(
        `${phase}: expected operation mode ${expectedMode}, got ${element.mandate.destinationOps.vt}`,
      );
    }
  }

  const signed = await account.signTransaction(prepared);
  const originSignatures = signed.originSignatures.map((signature) => {
    if (typeof signature !== "string") {
      throw new Error(`${phase}: SDK emitted a hybrid signature`);
    }
    return signature;
  });
  if (expectedMode === MODE_ERC1271 && !permissionId) {
    if (signed.targetExecutionSignature) {
      throw new Error(
        `${phase}: owner route unexpectedly has a target execution signature`,
      );
    }
    const messages = account.getTransactionMessages(prepared);
    if (messages.origin.length !== originSignatures.length) {
      throw new Error(`${phase}: route message and signature counts differ`);
    }
    const routeSignatures = [
      ...originSignatures.map((signature, index) => ({
        label: `origin ${index}`,
        message: messages.origin[index]!,
        signature,
      })),
      {
        label: "destination",
        message: messages.destination,
        signature: signed.destinationSignature,
      },
    ];
    for (const { label, message, signature } of routeSignatures) {
      if (!signature.toLowerCase().startsWith(zeroAddress)) {
        throw new Error(
          `${phase}: ${label} does not select the default validator`,
        );
      }
      if (size(signature) !== 85) {
        throw new Error(
          `${phase}: ${label} signature is ${size(signature)} bytes`,
        );
      }
      const signatureV = Number.parseInt(signature.slice(-2), 16);
      if (signatureV !== 27 && signatureV !== 28) {
        throw new Error(`${phase}: ${label} signature v is ${signatureV}`);
      }
      const recovered = await recoverTypedDataAddress({
        ...message,
        signature: `0x${signature.slice(42)}`,
      });
      if (recovered.toLowerCase() !== owner.address.toLowerCase()) {
        throw new Error(
          `${phase}: ${label} signature does not recover the HCA owner`,
        );
      }
    }
  } else if (expectedMode === MODE_ERC1271) {
    if (!permissionId) throw new Error(`${phase}: permission ID is required`);
    const signature = signed.targetExecutionSignature;
    if (!signature) {
      throw new Error(
        `${phase}: fixed session has no target execution signature`,
      );
    }
    const expectedPrefix =
      `${zeroAddress}${hasGasRefund ? "02" : "01"}${permissionId.slice(2)}`.toLowerCase();
    if (!signature.toLowerCase().startsWith(expectedPrefix)) {
      throw new Error(
        `${phase}: fixed session does not select the HCA validator; signature=${signature.slice(0, 108)}, refunds=${JSON.stringify(gasRefunds, jsonReplacer)}`,
      );
    }
    if (size(signature) <= 150) {
      throw new Error(
        `${phase}: fixed session does not carry an operation preimage`,
      );
    }
    const signatureV = Number.parseInt(signature.slice(-2), 16);
    if (signatureV !== 31 && signatureV !== 32) {
      throw new Error(`${phase}: fixed session signature v is ${signatureV}`);
    }
  } else {
    throw new Error(
      `${phase}: unsupported session operation mode ${expectedMode}`,
    );
  }

  if (HCA_DRY_RUN_ONLY) {
    return {
      phase,
      intentId: prepared.intentRoute.intentOp.nonce,
      setupOps: setupOps.length,
      mode: expectedMode,
      settlementLayers: prepared.intentRoute.intentOp.elements.map(
        (element) =>
          element.mandate.qualifier.settlementContext.settlementLayer,
      ),
      gasRefunds,
      paymentMetadata,
      dryRun: true as const,
      gasUsed: 0n,
    };
  }
  const feeTokenBalanceBefore = feeToken
    ? ((await publicClient.readContract({
        address: feeToken,
        abi: MockERC20.abi,
        functionName: "balanceOf",
        args: [account.getAddress()],
      })) as bigint)
    : undefined;
  let result;
  try {
    result = await account.submitTransaction(signed, []);
  } catch (error) {
    const context = (
      error as {
        _context?: unknown;
        _traceId?: string;
      }
    )._context;
    const traceId = (error as { _traceId?: string })._traceId;
    const trace = await debugFillFailure(context).catch((traceError) => ({
      traceError: String(traceError),
    }));
    throw new Error(
      `${phase}: submit simulation failed${traceId ? ` (${traceId})` : ""}${trace ? `: ${JSON.stringify(trace)}` : ""}`,
    );
  }
  const status = await account.waitForExecution(result, false);
  if (!status.fill.hash)
    throw new Error(`${phase}: fill has no transaction hash`);
  const receipt = await publicClient.waitForTransactionReceipt({
    hash: status.fill.hash,
  });
  if (receipt.status !== "success") {
    throw new Error(`${phase}: fill reverted (${status.fill.hash})`);
  }
  const feePayment = feeToken
    ? await (async () => {
        const balanceAfter = (await publicClient.readContract({
          address: feeToken,
          abi: MockERC20.abi,
          functionName: "balanceOf",
          args: [account.getAddress()],
        })) as bigint;
        if (
          feeTokenBalanceBefore === undefined ||
          feeTokenBalanceBefore < balanceAfter
        ) {
          throw new Error(`${phase}: invalid USDC balance change`);
        }
        const totalCharge = feeTokenBalanceBefore - balanceAfter;
        if (totalCharge < protocolTokenSpend) {
          throw new Error(
            `${phase}: USDC charge is smaller than protocol spend`,
          );
        }
        const executionFee = totalCharge - protocolTokenSpend;
        if (HCA_USER_PAID_USDC && executionFee === 0n) {
          throw new Error(`${phase}: executor took no USDC fee`);
        }
        return {
          token: feeToken,
          balanceBefore: feeTokenBalanceBefore,
          balanceAfter,
          totalCharge,
          protocolSpend: protocolTokenSpend,
          executionFee,
        };
      })()
    : undefined;
  return {
    phase,
    intentId: result.id,
    transactionHash: status.fill.hash,
    setupOps: setupOps.length,
    mode: expectedMode,
    gasRefunds,
    paymentMetadata,
    feePayment,
    gasUsed: receipt.gasUsed,
  };
}

async function verifyHca(
  hca: Address,
  deployments: {
    verifiableFactory: Address;
    standaloneHcaImplementation: Address;
  },
  expectedOwner: Address,
) {
  await assertCode("HCA", hca);
  const implementation = (await publicClient.readContract({
    address: deployments.verifiableFactory,
    abi: VerifiableFactory.abi,
    functionName: "verifyContract",
    args: [hca],
  })) as Address;
  assertAddress(
    "HCA implementation",
    implementation,
    deployments.standaloneHcaImplementation,
  );
  const [actualOwner] = (await publicClient.readContract({
    address: hca,
    abi: StandaloneSingleOwnerHCA.abi,
    functionName: "ownerAndSessionNonce",
  })) as [Address, bigint];
  assertAddress("HCA owner", actualOwner, expectedOwner);
}

async function preparePermissionlessCrossChainRegistration({
  hca,
  initiallyDeployed,
  commitment,
  deployments,
}: {
  hca: Address;
  initiallyDeployed: boolean;
  commitment: Hex;
  deployments: {
    standaloneHcaDeployer: Address;
    standaloneHcaImplementation: Address;
    ethRegistrar: Address;
  };
}) {
  let deploymentTransactionHash: Hex | undefined;
  let deploymentGasUsed = 0n;
  if (!initiallyDeployed) {
    await publicClient.simulateContract({
      account: relayer,
      address: deployments.standaloneHcaDeployer,
      abi: StandaloneHCADeployer.abi,
      functionName: "deploy",
      args: [
        owner.address,
        deployments.standaloneHcaImplementation,
        HCA_USER_SALT,
      ],
    });
    deploymentTransactionHash = await walletClient.writeContract({
      account: relayer,
      chain: sepolia,
      address: deployments.standaloneHcaDeployer,
      abi: StandaloneHCADeployer.abi,
      functionName: "deploy",
      args: [
        owner.address,
        deployments.standaloneHcaImplementation,
        HCA_USER_SALT,
      ],
      maxFeePerGas: OPERATOR_MAX_FEE_PER_GAS,
      maxPriorityFeePerGas: OPERATOR_MAX_PRIORITY_FEE_PER_GAS,
    });
    const receipt = await publicClient.waitForTransactionReceipt({
      hash: deploymentTransactionHash,
    });
    if (receipt.status !== "success") {
      throw new Error(
        `permissionless HCA deployment reverted: ${deploymentTransactionHash}`,
      );
    }
    deploymentGasUsed = receipt.gasUsed;
    await assertCode("permissionlessly deployed HCA", hca);
  }

  await publicClient.simulateContract({
    account: relayer,
    address: deployments.ethRegistrar,
    abi: ETHRegistrar.abi,
    functionName: "commit",
    args: [commitment],
  });
  const commitTransactionHash = await walletClient.writeContract({
    account: relayer,
    chain: sepolia,
    address: deployments.ethRegistrar,
    abi: ETHRegistrar.abi,
    functionName: "commit",
    args: [commitment],
    maxFeePerGas: OPERATOR_MAX_FEE_PER_GAS,
    maxPriorityFeePerGas: OPERATOR_MAX_PRIORITY_FEE_PER_GAS,
  });
  const commitReceipt = await publicClient.waitForTransactionReceipt({
    hash: commitTransactionHash,
  });
  if (commitReceipt.status !== "success") {
    throw new Error(
      `permissionless commitment reverted: ${commitTransactionHash}`,
    );
  }

  return {
    phase: "permissionless deploy and commit",
    deploymentTransactionHash,
    commitTransactionHash,
    deploymentGasUsed,
    commitGasUsed: commitReceipt.gasUsed,
    gasUsed: deploymentGasUsed + commitReceipt.gasUsed,
  };
}

async function makeCommitment(
  label: string,
  resolver: Address,
  deployments: { ethRegistrar: Address },
  expectedOwner: Address,
  secret: Hex,
) {
  return (await publicClient.readContract({
    address: deployments.ethRegistrar,
    abi: ETHRegistrar.abi,
    functionName: "makeCommitment",
    args: [
      label,
      expectedOwner,
      secret,
      zeroAddress,
      resolver,
      REGISTRATION_DURATION,
      zeroHash,
    ],
  })) as Hex;
}

async function registrationPrice(
  label: string,
  deployments: { ethRegistrar: Address; paymentToken: Address },
) {
  const [base, premium] = (await publicClient.readContract({
    address: deployments.ethRegistrar,
    abi: ETHRegistrar.abi,
    functionName: "getRegisterPrice",
    args: [label, REGISTRATION_DURATION, deployments.paymentToken],
  })) as [bigint, bigint];
  return base + premium;
}

async function prepareSameChainWalletFunding({
  hca,
  required,
  paymentToken,
}: {
  hca: Address;
  required: bigint;
  paymentToken: Address;
}): Promise<SameChainWalletFunding> {
  const [walletBalanceBeforeProvisioning, hcaBalanceBefore] = await Promise.all(
    [
      publicClient.readContract({
        address: paymentToken,
        abi: MockERC20.abi,
        functionName: "balanceOf",
        args: [owner.address],
      }) as Promise<bigint>,
      publicClient.readContract({
        address: paymentToken,
        abi: MockERC20.abi,
        functionName: "balanceOf",
        args: [hca],
      }) as Promise<bigint>,
    ],
  );
  const amountPulled =
    required > hcaBalanceBefore ? required - hcaBalanceBefore : 0n;
  const provisionedAmount =
    amountPulled > walletBalanceBeforeProvisioning
      ? amountPulled - walletBalanceBeforeProvisioning
      : 0n;
  let provisioningTransactionHash: Hex | undefined;
  let provisioningGasUsed = 0n;
  if (provisionedAmount > 0n) {
    const simulation = await publicClient.simulateContract({
      account: relayer,
      address: paymentToken,
      abi: MockERC20.abi,
      functionName: "mint",
      args: [owner.address, provisionedAmount],
    });
    provisioningTransactionHash = await walletClient.writeContract(
      simulation.request,
    );
    const receipt = await publicClient.waitForTransactionReceipt({
      hash: provisioningTransactionHash,
    });
    if (receipt.status !== "success") {
      throw new Error(
        `test wallet token provisioning reverted: ${provisioningTransactionHash}`,
      );
    }
    provisioningGasUsed = receipt.gasUsed;
  }

  const walletBalanceBeforePull = (await publicClient.readContract({
    address: paymentToken,
    abi: MockERC20.abi,
    functionName: "balanceOf",
    args: [owner.address],
  })) as bigint;
  if (walletBalanceBeforePull < amountPulled) {
    throw new Error(
      `wallet has ${walletBalanceBeforePull} payment-token units; ${amountPulled} required`,
    );
  }
  if (amountPulled === 0n) {
    return {
      calls: [],
      paymentToken,
      hca,
      required,
      amountPulled,
      walletBalanceBeforeProvisioning,
      walletBalanceBeforePull,
      hcaBalanceBefore,
      provisionedAmount,
      provisioningTransactionHash,
      provisioningGasUsed,
      permitSignatureCount: 0,
    };
  }

  const [domain, nonce, latestBlock] = await Promise.all([
    eip2612Domain(publicClient, paymentToken, sepolia.id),
    publicClient.readContract({
      address: paymentToken,
      abi: MockERC20.abi,
      functionName: "nonces",
      args: [owner.address],
    }) as Promise<bigint>,
    publicClient.getBlock(),
  ]);
  const deadline = latestBlock.timestamp + SESSION_DURATION;
  const permitSignature = await owner.signTypedData({
    domain,
    types: {
      Permit: [
        { name: "owner", type: "address" },
        { name: "spender", type: "address" },
        { name: "value", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    },
    primaryType: "Permit",
    message: {
      owner: owner.address,
      spender: hca,
      value: amountPulled,
      nonce,
      deadline,
    },
  });
  const { r, s, v, yParity } = parseSignature(permitSignature);
  const permitV = Number(v ?? BigInt(27 + (yParity ?? 0)));
  const permitArgs = [
    owner.address,
    hca,
    amountPulled,
    deadline,
    permitV,
    r,
    s,
  ] as const;
  await publicClient.simulateContract({
    account: relayer,
    address: paymentToken,
    abi: MockERC20.abi,
    functionName: "permit",
    args: permitArgs,
  });

  return {
    calls: [
      {
        to: paymentToken,
        value: 0n,
        data: encodeFunctionData({
          abi: MockERC20.abi,
          functionName: "permit",
          args: permitArgs,
        }),
      },
      {
        to: paymentToken,
        value: 0n,
        data: encodeFunctionData({
          abi: MockERC20.abi,
          functionName: "transferFrom",
          args: [owner.address, hca, amountPulled],
        }),
      },
    ],
    paymentToken,
    hca,
    required,
    amountPulled,
    walletBalanceBeforeProvisioning,
    walletBalanceBeforePull,
    hcaBalanceBefore,
    provisionedAmount,
    provisioningTransactionHash,
    provisioningGasUsed,
    permitSignatureCount: 1,
  };
}

async function verifySameChainWalletFunding(plan: SameChainWalletFunding) {
  const [walletBalanceAfter, hcaBalanceAfter, allowanceAfter] =
    await Promise.all([
      publicClient.readContract({
        address: plan.paymentToken,
        abi: MockERC20.abi,
        functionName: "balanceOf",
        args: [owner.address],
      }) as Promise<bigint>,
      publicClient.readContract({
        address: plan.paymentToken,
        abi: MockERC20.abi,
        functionName: "balanceOf",
        args: [plan.hca],
      }) as Promise<bigint>,
      publicClient.readContract({
        address: plan.paymentToken,
        abi: MockERC20.abi,
        functionName: "allowance",
        args: [owner.address, plan.hca],
      }) as Promise<bigint>,
    ]);
  if (walletBalanceAfter !== plan.walletBalanceBeforePull - plan.amountPulled) {
    throw new Error(
      "first HCA intent did not pull payment tokens from the wallet",
    );
  }
  if (hcaBalanceAfter !== plan.hcaBalanceBefore + plan.amountPulled) {
    throw new Error("first HCA intent did not fund the HCA from the wallet");
  }
  if (hcaBalanceAfter < plan.required) {
    throw new Error(
      `HCA has ${hcaBalanceAfter} payment-token units; ${plan.required} required`,
    );
  }
  if (plan.amountPulled > 0n && allowanceAfter !== 0n) {
    throw new Error(
      `HCA payment-token allowance was not consumed: ${allowanceAfter}`,
    );
  }
  return {
    source: "wallet EIP-2612 permit" as const,
    amountPulled: plan.amountPulled,
    walletBalanceBeforePull: plan.walletBalanceBeforePull,
    walletBalanceAfter,
    hcaBalanceBefore: plan.hcaBalanceBefore,
    hcaBalanceAfter,
    allowanceAfter,
    provisionedAmount: plan.provisionedAmount,
    provisioningTransactionHash: plan.provisioningTransactionHash,
    provisioningGasUsed: plan.provisioningGasUsed,
    permitSignatureCount: plan.permitSignatureCount,
    gasUsed: plan.provisioningGasUsed,
  };
}

async function ensurePaymentTokenFunding(
  hca: Address,
  required: bigint,
  paymentToken: Address,
) {
  const balanceBeforeProvisioning = (await publicClient.readContract({
    address: paymentToken,
    abi: MockERC20.abi,
    functionName: "balanceOf",
    args: [hca],
  })) as bigint;
  const provisionedAmount =
    balanceBeforeProvisioning < required
      ? required - balanceBeforeProvisioning
      : 0n;
  if (provisionedAmount > 0n && !HCA_ALLOW_TARGET_TEST_TOP_UP) {
    throw new Error(
      `cross-chain fill left ${balanceBeforeProvisioning} token units; ${required} required for the session follow-up`,
    );
  }
  let provisioningTransactionHash: Hex | undefined;
  let provisioningGasUsed = 0n;
  if (provisionedAmount > 0n) {
    const simulation = await publicClient.simulateContract({
      account: relayer,
      address: paymentToken,
      abi: MockERC20.abi,
      functionName: "transfer",
      args: [hca, provisionedAmount],
    });
    provisioningTransactionHash = await walletClient.writeContract(
      simulation.request,
    );
    const receipt = await publicClient.waitForTransactionReceipt({
      hash: provisioningTransactionHash,
    });
    if (receipt.status !== "success") {
      throw new Error(
        `existing-user test funding reverted: ${provisioningTransactionHash}`,
      );
    }
    provisioningGasUsed = receipt.gasUsed;
  }
  const balance = balanceBeforeProvisioning + provisionedAmount;
  return {
    source: "Base Sepolia Permit2 + Across" as const,
    amount: balance,
    crossChainBalance: balanceBeforeProvisioning,
    testProvisionedAmount: provisionedAmount,
    provisioningTransactionHash,
    gasUsed: provisioningGasUsed,
  };
}

async function waitForCommitment(commitment: Hex, ethRegistrar: Address) {
  const [committedAt, minAge] = await Promise.all([
    publicClient.readContract({
      address: ethRegistrar,
      abi: ETHRegistrar.abi,
      functionName: "commitmentAt",
      args: [commitment],
    }) as Promise<bigint>,
    publicClient.readContract({
      address: ethRegistrar,
      abi: ETHRegistrar.abi,
      functionName: "MIN_COMMITMENT_AGE",
    }) as Promise<bigint>,
  ]);
  const latest = await publicClient.getBlock();
  const validAt = committedAt + minAge;
  if (latest.timestamp <= validAt) {
    await Bun.sleep(Number(validAt - latest.timestamp + 2n) * 1000);
  }
}

async function registrationCalls({
  label,
  price,
  hca,
  resolver,
  resolverSalt,
  secret,
  deployments,
}: {
  label: string;
  price: bigint;
  hca: Address;
  resolver: Address;
  resolverSalt: bigint;
  secret: Hex;
  deployments: {
    verifiableFactory: Address;
    permissionedResolverImpl: Address;
    paymentToken: Address;
    ethRegistrar: Address;
    defaultReverseRegistrarAdapter: Address;
  };
}) {
  const name = `${label}.eth`;
  const node = namehash(name);
  const reverseNode = namehash(ethReverseName(owner.address));
  const calls: Call[] = [];
  const resolverCode = await publicClient.getCode({ address: resolver });
  if (!resolverCode || resolverCode === "0x") {
    calls.push({
      to: deployments.verifiableFactory,
      value: 0n,
      data: encodeFunctionData({
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
    });
  }
  calls.push(
    {
      to: deployments.paymentToken,
      value: 0n,
      data: encodeFunctionData({
        abi: MockERC20.abi,
        functionName: "approve",
        args: [deployments.ethRegistrar, price],
      }),
    },
    {
      to: deployments.ethRegistrar,
      value: 0n,
      data: encodeFunctionData({
        abi: ETHRegistrar.abi,
        functionName: "register",
        args: [
          label,
          owner.address,
          secret,
          zeroAddress,
          resolver,
          REGISTRATION_DURATION,
          deployments.paymentToken,
          zeroHash,
        ],
      }),
    },
    {
      to: resolver,
      value: 0n,
      data: encodeFunctionData({
        abi: PermissionedResolver.abi,
        functionName: "setAddr",
        args: [node, COIN_TYPE_ETH, owner.address],
      }),
    },
    {
      to: resolver,
      value: 0n,
      data: encodeFunctionData({
        abi: PermissionedResolver.abi,
        functionName: "setText",
        args: [node, "url", `https://example.com/${label}`],
      }),
    },
    {
      to: resolver,
      value: 0n,
      data: encodeFunctionData({
        abi: PermissionedResolver.abi,
        functionName: "setName",
        args: [reverseNode, name],
      }),
    },
    {
      to: deployments.defaultReverseRegistrarAdapter,
      value: 0n,
      data: encodeFunctionData({
        abi: DefaultReverseRegistrarAdapter.abi,
        functionName: "setNameWithHCA",
        args: [owner.address, name],
      }),
    },
    {
      to: resolver,
      value: 0n,
      data: encodeFunctionData({
        abi: PermissionedResolver.abi,
        functionName: "authorizeNameRoles",
        args: ["0x00", ROLES_ALL, owner.address, true],
      }),
    },
  );
  return calls;
}

async function verifyRegistration(
  label: string,
  hca: Address,
  resolver: Address,
  deployments: {
    ethRegistry: Address;
    verifiableFactory: Address;
    permissionedResolverImpl: Address;
    defaultReverseRegistrar: Address;
    v1Registry: Address;
    universalResolver: Address;
  },
  expectedOwner: Address,
) {
  const name = `${label}.eth`;
  const node = namehash(name);
  const reverseNode = namehash(ethReverseName(expectedOwner));
  const state = (await publicClient.readContract({
    address: deployments.ethRegistry,
    abi: PermissionedRegistry.abi,
    functionName: "getState",
    args: [BigInt(keccak256(stringToHex(label)))],
  })) as { status: number | bigint; latestOwner: Address };
  if (Number(state.status) !== STATUS_REGISTERED) {
    throw new Error(`${name} status=${state.status}`);
  }
  assertAddress("registered owner", state.latestOwner, expectedOwner);

  const registryResolver = (await publicClient.readContract({
    address: deployments.ethRegistry,
    abi: PermissionedRegistry.abi,
    functionName: "getResolver",
    args: [label],
  })) as Address;
  assertAddress("registry resolver", registryResolver, resolver);
  const resolverImplementation = (await publicClient.readContract({
    address: deployments.verifiableFactory,
    abi: VerifiableFactory.abi,
    functionName: "verifyContract",
    args: [resolver],
  })) as Address;
  assertAddress(
    "resolver implementation",
    resolverImplementation,
    deployments.permissionedResolverImpl,
  );
  const [ownerHasRoles, hcaHasRoles] = await Promise.all(
    [expectedOwner, hca].map((account) =>
      publicClient.readContract({
        address: resolver,
        abi: PermissionedResolver.abi,
        functionName: "hasRoles",
        args: [0n, ROLES_ALL, account],
      }),
    ),
  );
  if (!ownerHasRoles || !hcaHasRoles) {
    throw new Error("resolver roles were not retained for both wallet and HCA");
  }

  const resolvedAddress = (await publicClient.readContract({
    address: resolver,
    abi: PermissionedResolver.abi,
    functionName: "addr",
    args: [node],
  })) as Address;
  assertAddress("resolver address", resolvedAddress, expectedOwner);
  const defaultPrimary = (await publicClient.readContract({
    address: deployments.defaultReverseRegistrar,
    abi: DefaultReverseRegistrar.abi,
    functionName: "nameForAddr",
    args: [expectedOwner],
  })) as string;
  if (defaultPrimary !== name)
    throw new Error(`default primary=${defaultPrimary}`);
  const exactReverseResolver = (await publicClient.readContract({
    address: deployments.v1Registry,
    abi: ENSRegistry.abi,
    functionName: "resolver",
    args: [reverseNode],
  })) as Address;
  if (
    HCA_EXPECT_DEFAULT_REVERSE_FALLBACK &&
    exactReverseResolver !== zeroAddress
  ) {
    throw new Error(
      `expected default.reverse fallback, got ${exactReverseResolver}`,
    );
  }

  const [reversePrimary] = (await publicClient.readContract({
    address: deployments.universalResolver,
    abi: UniversalResolverV2.abi,
    functionName: "reverse",
    args: [expectedOwner, COIN_TYPE_ETH],
  })) as [string, Address, Address];
  if (reversePrimary !== name) throw new Error(`UR reverse=${reversePrimary}`);
  const forwardCall = encodeFunctionData({
    abi: PermissionedResolver.abi,
    functionName: "addr",
    args: [node],
  });
  const [answer] = (await publicClient.readContract({
    address: deployments.universalResolver,
    abi: UniversalResolverV2.abi,
    functionName: "resolve",
    args: [dnsEncodeName(name), forwardCall],
  })) as [Hex, Address];
  const universalAddress = decodeFunctionResult({
    abi: PermissionedResolver.abi,
    functionName: "addr",
    data: answer,
  }) as Address;
  assertAddress("UR forward address", universalAddress, expectedOwner);
  return {
    name,
    registeredOwner: state.latestOwner,
    resolver,
    ownerHasResolverRoles: ownerHasRoles,
    hcaHasResolverRoles: hcaHasRoles,
    defaultPrimary,
    universalAddress,
  };
}

await main();
