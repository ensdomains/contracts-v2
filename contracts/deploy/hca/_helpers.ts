import { artifacts } from "@rocketh";
import {
  encodeAbiParameters,
  encodeDeployData,
  getCreate2Address,
  isAddress,
  keccak256,
  parseAbiParameters,
  stringToHex,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";

import { ENTRY_POINT_V07_INIT_CODE } from "./_entrypoint070.js";

export const DEFAULT_ENTRY_POINT =
  "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
export const INTENT_EXECUTOR_ID = keccak256(stringToHex("IntentExecutor"));
export const PAYMASTER_ID = keccak256(stringToHex("Paymaster"));
export const SAMECHAIN_ARBITER_ID = keccak256(
  stringToHex("SameChainArbiter"),
);
export const INTENT_EXECUTOR_SALT = keccak256(
  stringToHex("ENSv2.IntentExecutor"),
);

export type IntentExecutorArgs = [
  Address,
  Address,
  Address,
  Address,
  Address,
];

type JsonRpcProvider = {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>;
};

export const ENTRY_POINT_V07_ARTIFACT = {
  ...artifacts.EntryPoint,
  bytecode: ENTRY_POINT_V07_INIT_CODE,
  deployedBytecode: "0x",
  metadata: "{}",
};

async function readCode(
  provider: JsonRpcProvider,
  address: Address,
): Promise<Hex> {
  return (await provider.request({
    method: "eth_getCode",
    params: [address, "latest"],
  })) as Hex;
}

export async function hasCode(
  provider: JsonRpcProvider,
  address: Address,
): Promise<boolean> {
  const code = await readCode(provider, address);
  return code !== "0x" && code !== "0x0";
}

export function optionalAddress(
  value: string | undefined,
  name: string,
): Address | undefined {
  if (!value) return undefined;
  if (!isAddress(value)) throw new Error(`${name} is not a valid address`);
  return value as Address;
}

export function resolveFactoryOwner(deployer: string, owner?: string): Address {
  return (owner || deployer) as Address;
}

export function allowIncompleteIntentStack(tags: {
  local?: boolean;
  test?: boolean;
}): boolean {
  return Boolean(tags.local || tags.test);
}

export function resolveIntentStackAddress(
  value: string | undefined,
  name: string,
  fallback: Address,
  allowFallback: boolean,
): Address {
  const address = optionalAddress(value, name);
  if (address) return address;
  if (allowFallback) return fallback;
  throw new Error(
    `${name} must be set when deploying the HCA intent executor stack`,
  );
}

export function resolveAtomicFillSigner(
  factoryOwner: Address,
  allowFallback: boolean,
): Address {
  return resolveIntentStackAddress(
    process.env.HCA_ATOMIC_FILL_SIGNER,
    "HCA_ATOMIC_FILL_SIGNER",
    factoryOwner,
    allowFallback,
  );
}

export function resolveCompact(allowFallback: boolean): Address {
  return resolveIntentStackAddress(
    process.env.HCA_COMPACT,
    "HCA_COMPACT",
    zeroAddress,
    allowFallback,
  );
}

export function resolveAllocator(
  factoryOwner: Address,
  allowFallback: boolean,
): Address {
  return resolveIntentStackAddress(
    process.env.HCA_ALLOCATOR,
    "HCA_ALLOCATOR",
    factoryOwner,
    allowFallback,
  );
}

export function resolveSmartSessionEmissary(allowFallback: boolean): Address {
  return resolveIntentStackAddress(
    process.env.HCA_SMART_SESSION_EMISSARY,
    "HCA_SMART_SESSION_EMISSARY",
    zeroAddress,
    allowFallback,
  );
}

export function resolveIntentExecutorArgs({
  router,
  addressBook,
  factoryOwner,
  allowFallback,
}: {
  router: Address;
  addressBook: Address;
  factoryOwner: Address;
  allowFallback: boolean;
}): IntentExecutorArgs {
  return [
    router,
    resolveCompact(allowFallback),
    resolveAllocator(factoryOwner, allowFallback),
    addressBook,
    resolveSmartSessionEmissary(allowFallback),
  ];
}

export function encodeIntentExecutorDeployData(args: IntentExecutorArgs): Hex {
  return encodeDeployData({
    abi: artifacts.IntentExecutor.abi,
    bytecode: artifacts.IntentExecutor.bytecode as Hex,
    args,
  });
}

export function computeIntentExecutorAddress({
  create2Factory,
  args,
}: {
  create2Factory: Address;
  args: IntentExecutorArgs;
}): Address {
  return getCreate2Address({
    from: create2Factory,
    salt: INTENT_EXECUTOR_SALT,
    bytecode: encodeIntentExecutorDeployData(args),
  });
}

export function encodeTemplateInitData(): Hex {
  return encodeAbiParameters(
    parseAbiParameters(
      "uint256 threshold, (address addr, uint48 expiration)[] owners",
    ),
    [
      1n,
      [
        {
          addr: "0x0000000000000000000000000000000000000001",
          expiration: 281474976710655,
        },
      ],
    ],
  );
}
