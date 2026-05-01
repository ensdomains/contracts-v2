import { artifacts } from "@rocketh";
import {
  type Account,
  type Address,
  encodeAbiParameters,
  encodeFunctionData,
  encodePacked,
  type Hex,
  keccak256,
  parseAbiParameters,
  parseUnits,
  type TransactionReceipt,
  zeroAddress,
  zeroHash,
} from "viem";

import type { DevnetEnvironment } from "../../script/setup.js";
import { expectVar } from "./expectVar.js";

const HCA_EXECUTE_ABI = [
  {
    type: "function",
    name: "execute",
    stateMutability: "payable",
    inputs: [
      { name: "mode", type: "bytes32" },
      { name: "executionCalldata", type: "bytes" },
    ],
    outputs: [],
  },
] as const;

const SIMPLE_SINGLE_MODE =
  "0x0000000000000000000000000000000000000000000000000000000000000000";
const SIMPLE_BATCH_MODE =
  "0x0100000000000000000000000000000000000000000000000000000000000000";
const MAX_UINT48 = 281474976710655;
const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const PERMIT2_DOMAIN_TYPEHASH =
  "0x8cad95687ba82c2ce50e74f7b754645e5117c3a5bec8151c0726d5857980a866";
const PERMIT2_NAME_HASH =
  "0x9ac997416e8ff9d2ff6bebeb7149f65cdae5e32e2b90440b566bb3044041d36a";
const TYPEHASH_OP =
  "0xdbc520cb50a8aaf3fa06ea43dc3d59d248e52ae638476e3268a1e6e36bffe196";
const TYPEHASH_OPERATION =
  "0x09b0a32e9842b65559835c235891737e06927d59e48a6f0e0512e136a513a9e4";
const TYPEHASH_MANDATE =
  "0xc988b4da10503879cf4b893fed09620229f5ade301ef5e4af6124b22823627dc";
const TYPEHASH_JIT_PERMIT2 =
  "0x1b355fbc76f14a5aefe5c85df793a0f876f90d66f457273501c13ac311b5f3f8";
const EMPTY_ARRAY_HASH =
  "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
const NO_OPS_HASH =
  "0x0c7bea50822ae8a3846eccbda4961a80e1e08aa92f2bf046be0011514ad2ddf1";
const EXEC_TYPE_ERC7579 = 2;
const SIG_MODE_ERC1271 = 1;

export const BURNER_SESSION_SIGNER_KEY =
  "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
export const REGISTRATION_DURATION = 28n * 86400n;

type PackedUserOperation = {
  sender: Address;
  nonce: bigint;
  initCode: Hex;
  callData: Hex;
  accountGasLimits: Hex;
  preVerificationGas: bigint;
  gasFees: Hex;
  paymasterAndData: Hex;
  signature: Hex;
};

export type HCAExecution = {
  target: Address;
  value?: bigint;
  data: Hex;
};

type Execution = {
  target: Address;
  value: bigint;
  callData: Hex;
};

type Operation = {
  data: Hex;
};

type Permit2IntentArgs = readonly [
  Address,
  { nonce: bigint; expires: bigint },
  {
    tokenInHash: Hex;
    minGas: bigint;
    targetAttributesHash: Hex;
    destOpsHash: Hex;
    qHash: Hex;
  },
  Operation,
  Hex,
];

export type GasReporter = {
  record(label: string, receipt: TransactionReceipt): void;
  report(): void;
};

function formatGas(gas: bigint): string {
  return gas.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function formatTxHash(hash: Hex): string {
  return `${hash.slice(0, 10)}...${hash.slice(-8)}`;
}

export function createGasReporter(flow: string): GasReporter {
  const records: {
    label: string;
    gasUsed: bigint;
    transactionHash: Hex;
  }[] = [];

  return {
    record(label, receipt) {
      records.push({
        label,
        gasUsed: BigInt(receipt.gasUsed),
        transactionHash: receipt.transactionHash,
      });
    },
    report() {
      if (records.length === 0) return;

      const labelWidth = Math.max(
        "total".length,
        ...records.map(({ label }) => label.length),
      );
      const total = records.reduce((sum, { gasUsed }) => sum + gasUsed, 0n);

      const lines = [`\n[gas] ${flow}`];
      for (const { label, gasUsed, transactionHash } of records) {
        lines.push(
          [
            `[gas] ${label.padEnd(labelWidth)}`,
            `${formatGas(gasUsed)} gas`,
            formatTxHash(transactionHash),
          ].join("  "),
        );
      }
      lines.push(
        `[gas] ${"total".padEnd(labelWidth)}  ${formatGas(total)} gas\n`,
      );
      console.log(lines.join("\n"));
    },
  };
}

function packUint128Pair(high: bigint, low: bigint): Hex {
  return encodePacked(["uint128", "uint128"], [high, low]);
}

function buildUserOp({
  sender,
  nonce,
  initCode = "0x",
  callData,
  signature = "0x",
}: {
  sender: Address;
  nonce: bigint;
  initCode?: Hex;
  callData: Hex;
  signature?: Hex;
}): PackedUserOperation {
  return {
    sender,
    nonce,
    initCode,
    callData,
    accountGasLimits: packUint128Pair(5_000_000n, 5_000_000n),
    preVerificationGas: 1_000_000n,
    gasFees: packUint128Pair(1_000_000_000n, 20_000_000_000n),
    paymasterAndData: "0x",
    signature,
  };
}

async function signUserOpHash(owner: Account, userOpHash: Hex): Promise<Hex> {
  if (!owner.signMessage) {
    throw new Error("HCA e2e owner account must support local signing");
  }
  return owner.signMessage({ message: { raw: userOpHash } });
}

async function signRawHash(signer: Account, hash: Hex): Promise<Hex> {
  const rawSigner = signer as Account & {
    sign?: ({ hash }: { hash: Hex }) => Promise<Hex>;
  };
  if (!rawSigner.sign) {
    throw new Error("HCA e2e signer account must support raw signing");
  }
  return rawSigner.sign({ hash });
}

function abiHash(parameters: string, values: unknown[]): Hex {
  return keccak256(encodeAbiParameters(parseAbiParameters(parameters), values));
}

function packedHash(values: Hex[]): Hex {
  return keccak256(
    `0x${values.map((value) => value.slice(2)).join("")}` as Hex,
  );
}

function vtBytes32(execType: number, sigMode: number): Hex {
  return `0x${execType.toString(16).padStart(2, "0")}${sigMode
    .toString(16)
    .padStart(2, "0")}${"00".repeat(30)}` as Hex;
}

function hashExecution(execution: Execution): Hex {
  return abiHash(
    "bytes32 typehash, address target, uint256 value, bytes32 callDataHash",
    [
      TYPEHASH_OPERATION,
      execution.target,
      execution.value,
      keccak256(execution.callData),
    ],
  );
}

function hashExecutions(executions: Execution[]): Hex {
  if (executions.length === 0) return EMPTY_ARRAY_HASH;
  return packedHash(executions.map(hashExecution));
}

function encodeERC7579Operation(executions: Execution[]): Operation {
  const encodedExecutions = encodeAbiParameters(
    parseAbiParameters("(address target, uint256 value, bytes callData)[]"),
    [executions],
  );
  return {
    data: encodePacked(
      ["uint8", "uint8", "bytes"],
      [EXEC_TYPE_ERC7579, SIG_MODE_ERC1271, encodedExecutions],
    ),
  };
}

function hashOperation(executions: Execution[]): Hex {
  return abiHash("bytes32 typehash, bytes32 vt, bytes32 opsHash", [
    TYPEHASH_OP,
    vtBytes32(EXEC_TYPE_ERC7579, SIG_MODE_ERC1271),
    hashExecutions(executions),
  ]);
}

function hashMandate({
  preClaimOpsHash,
  destOpsHash = NO_OPS_HASH,
  targetAttributesHash = zeroHash,
  minGas = 0n,
  qHash = zeroHash,
}: {
  preClaimOpsHash: Hex;
  destOpsHash?: Hex;
  targetAttributesHash?: Hex;
  minGas?: bigint;
  qHash?: Hex;
}): Hex {
  return abiHash(
    "bytes32 typehash, bytes32 targetAttributes, uint128 minGas, bytes32 preClaimOpsHash, bytes32 destOpsHash, bytes32 qHash",
    [
      TYPEHASH_MANDATE,
      targetAttributesHash,
      minGas,
      preClaimOpsHash,
      destOpsHash,
      qHash,
    ],
  );
}

function hashPermit2({
  tokenInHash = EMPTY_ARRAY_HASH,
  arbiter,
  nonce,
  expires,
  mandate,
}: {
  tokenInHash?: Hex;
  arbiter: Address;
  nonce: bigint;
  expires: bigint;
  mandate: Hex;
}): Hex {
  return abiHash(
    "bytes32 typehash, bytes32 tokenInHash, address arbiter, uint256 nonce, uint256 expires, bytes32 mandate",
    [TYPEHASH_JIT_PERMIT2, tokenInHash, arbiter, nonce, expires, mandate],
  );
}

export function createHCATestUtils(env: DevnetEnvironment) {
  function hcaModuleAddress(): Address {
    return env.rocketh.get("HCAModule").address as Address;
  }

  function intentExecutorAddress(): Address {
    return env.rocketh.get("IntentExecutor").address as Address;
  }

  function encodeHCAInitData(owner: Address): Hex {
    return encodeAbiParameters(
      parseAbiParameters(
        "uint256 threshold, (address addr, uint48 expiration)[] owners",
      ),
      [
        1n,
        [
          {
            addr: owner,
            expiration: MAX_UINT48,
          },
        ],
      ],
    );
  }

  function buildHCAInitCode(owner: Account): Hex {
    const initData = encodeHCAInitData(owner.address);
    const createAccountData = encodeFunctionData({
      abi: artifacts.HCAFactory.abi,
      functionName: "createAccount",
      args: [initData],
    });

    return encodePacked(
      ["address", "bytes"],
      [env.v2.HCAFactory.address, createAccountData],
    );
  }

  function permit2Digest(permit2Hash: Hex): Hex {
    const domainSeparator = abiHash(
      "bytes32 typehash, bytes32 nameHash, uint256 chainId, address verifyingContract",
      [
        PERMIT2_DOMAIN_TYPEHASH,
        PERMIT2_NAME_HASH,
        BigInt(env.client.chain.id),
        PERMIT2_ADDRESS,
      ],
    );
    return keccak256(
      encodePacked(
        ["bytes2", "bytes32", "bytes32"],
        ["0x1901", domainSeparator, permit2Hash],
      ),
    );
  }

  async function signHCA1271Digest(
    signer: Account,
    digest: Hex,
  ): Promise<Hex> {
    return encodePacked(
      ["address", "bytes"],
      [zeroAddress, await signRawHash(signer, digest)],
    );
  }

  async function buildPermit2IntentArgs({
    hca,
    signer,
    executions,
    nonce,
    expires,
    arbiter,
  }: {
    hca: Address;
    signer: Account;
    executions: Execution[];
    nonce: bigint;
    expires: bigint;
    arbiter: Address;
  }): Promise<Permit2IntentArgs> {
    const operation = encodeERC7579Operation(executions);
    const mandate = hashMandate({
      preClaimOpsHash: hashOperation(executions),
    });
    const permit2Hash = hashPermit2({
      arbiter,
      nonce,
      expires,
      mandate,
    });
    const signature = await signHCA1271Digest(
      signer,
      permit2Digest(permit2Hash),
    );

    return [
      hca,
      { nonce, expires },
      {
        tokenInHash: EMPTY_ARRAY_HASH,
        minGas: 0n,
        targetAttributesHash: zeroHash,
        destOpsHash: NO_OPS_HASH,
        qHash: zeroHash,
      },
      operation,
      signature,
    ];
  }

  async function buildPermit2IntentCallData({
    hca,
    signer,
    executions,
    nonce,
    expires,
    arbiter,
  }: {
    hca: Address;
    signer: Account;
    executions: Execution[];
    nonce: bigint;
    expires: bigint;
    arbiter: Address;
  }): Promise<Hex> {
    return encodeFunctionData({
      abi: artifacts.IntentExecutor.abi,
      functionName: "executePreClaimOpsWithPermit2Stub",
      args: await buildPermit2IntentArgs({
        hca,
        signer,
        executions,
        nonce,
        expires,
        arbiter,
      }),
    });
  }

  async function createHCA(owner: Account): Promise<Address> {
    const initData = encodeHCAInitData(owner.address);
    const hca = await env.v2.HCAFactory.read.computeAccountAddress([
      owner.address,
    ]);

    await env.v2.HCAFactory.write.createAccount([initData], {
      account: env.namedAccounts.deployer,
    });

    const hcaOwner = await env.v2.HCAFactory.read.getAccountOwner([hca]);
    expectVar({ hcaOwner }).toEqualAddress(owner.address);

    await env.v2.EntryPoint.write.depositTo([hca], {
      account: env.namedAccounts.deployer,
      value: parseUnits("1", 18),
    });

    return hca;
  }

  async function executeHCAUserOp({
    hca,
    owner,
    initCode,
    callData,
    gas,
    gasLabel,
  }: {
    hca: Address;
    owner: Account;
    initCode?: Hex;
    callData: Hex;
    gas?: GasReporter;
    gasLabel?: string;
  }): Promise<TransactionReceipt> {
    const nonce = await env.v2.EntryPoint.read.getNonce([hca, 0n]);
    const unsignedUserOp = buildUserOp({
      sender: hca,
      nonce,
      initCode,
      callData,
    });
    const userOpHash = await env.v2.EntryPoint.read.getUserOpHash([
      unsignedUserOp,
    ]);
    const signature = await signUserOpHash(owner, userOpHash);

    const transactionHash = await env.v2.EntryPoint.write.handleOps(
      [[{ ...unsignedUserOp, signature }], env.namedAccounts.deployer.address],
      { account: env.namedAccounts.deployer },
    );
    const receipt = await env.client.getTransactionReceipt({
      hash: transactionHash,
    });
    gas?.record(gasLabel ?? "handleOps", receipt);
    return receipt;
  }

  async function executeThroughHCA({
    hca,
    owner,
    initCode,
    target,
    data,
    gas,
    gasLabel,
  }: {
    hca: Address;
    owner: Account;
    initCode?: Hex;
    target: Address;
    data: Hex;
    gas?: GasReporter;
    gasLabel?: string;
  }): Promise<TransactionReceipt> {
    const executionCalldata = encodePacked(
      ["address", "uint256", "bytes"],
      [target, 0n, data],
    );
    const callData = encodeFunctionData({
      abi: HCA_EXECUTE_ABI,
      functionName: "execute",
      args: [SIMPLE_SINGLE_MODE, executionCalldata],
    });
    return executeHCAUserOp({
      hca,
      owner,
      initCode,
      callData,
      gas,
      gasLabel,
    });
  }

  async function executeBatchThroughHCA({
    hca,
    owner,
    initCode,
    executions,
    gas,
    gasLabel,
  }: {
    hca: Address;
    owner: Account;
    initCode?: Hex;
    executions: HCAExecution[];
    gas?: GasReporter;
    gasLabel?: string;
  }): Promise<TransactionReceipt> {
    const executionCalldata = encodeAbiParameters(
      parseAbiParameters("(address target, uint256 value, bytes callData)[]"),
      [
        executions.map(({ target, value = 0n, data }) => ({
          target,
          value,
          callData: data,
        })),
      ],
    );
    const callData = encodeFunctionData({
      abi: HCA_EXECUTE_ABI,
      functionName: "execute",
      args: [SIMPLE_BATCH_MODE, executionCalldata],
    });
    return executeHCAUserOp({
      hca,
      owner,
      initCode,
      callData,
      gas,
      gasLabel,
    });
  }

  return {
    buildHCAInitCode,
    buildPermit2IntentCallData,
    createHCA,
    encodeHCAInitData,
    executeBatchThroughHCA,
    executeHCAUserOp,
    executeThroughHCA,
    hcaModuleAddress,
    intentExecutorAddress,
  };
}
