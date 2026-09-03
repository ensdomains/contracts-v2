import { readFile } from "node:fs/promises";
import { describe, expect, it } from "bun:test";
import {
  type Abi,
  type Address,
  type Hex,
  concat,
  createPublicClient,
  createWalletClient,
  encodeFunctionData,
  getAddress,
  http,
  numberToHex,
  pad,
  parseAbi,
  parseEther,
  toHex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { entryPoint07Address } from "viem/account-abstraction";

/**
 * Gap hunt: no other test in contracts/test submits a UserOperation through a
 * bundler. This one drives the same UserOperation twice — once through Alto
 * plus the mock verifying paymaster, once straight into
 * `EntryPoint.handleOps()` from an EOA — and asserts both reach the same
 * account state while only the bundler leg is paymaster-sponsored.
 *
 * The Alto stack is not part of `bun run test:e2e`; it is brought up
 * separately (`bun run aakit`, i.e. docker compose profile `local` against a
 * devnet on :8545). When any piece of it is missing the whole suite skips.
 */

const ALTO_URL = process.env.ALTO_URL ?? "http://127.0.0.1:4337";
const MOCK_PAYMASTER_URL =
  process.env.MOCK_PAYMASTER_URL ?? "http://127.0.0.1:3000";
const ALTO_CHAIN_RPC_URL =
  process.env.ALTO_CHAIN_RPC_URL ?? "http://127.0.0.1:8545";

// anvil's first default account; not one of Alto's utility/executor keys.
const DEPLOYER_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
// throwaway owner of the mock smart accounts.
const ACCOUNT_OWNER_KEY =
  "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

const CALL_GAS_LIMIT = 200_000n;
const VERIFICATION_GAS_LIMIT = 300_000n;
const PRE_VERIFICATION_GAS = 100_000n;
const DEFAULT_PAYMASTER_GAS = 100_000n;

const entryPointAbi = parseAbi([
  "struct PackedUserOperation { address sender; uint256 nonce; bytes initCode; bytes callData; bytes32 accountGasLimits; uint256 preVerificationGas; bytes32 gasFees; bytes paymasterAndData; bytes signature; }",
  "function getUserOpHash(PackedUserOperation userOp) view returns (bytes32)",
  "function handleOps(PackedUserOperation[] ops, address beneficiary)",
  "function depositTo(address account) payable",
  "function balanceOf(address account) view returns (uint256)",
  "function getNonce(address sender, uint192 key) view returns (uint256)",
]);

type UnpackedUserOperation = {
  sender: Address;
  nonce: bigint;
  callData: Hex;
  callGasLimit: bigint;
  verificationGasLimit: bigint;
  preVerificationGas: bigint;
  maxFeePerGas: bigint;
  maxPriorityFeePerGas: bigint;
  paymaster?: Address;
  paymasterVerificationGasLimit?: bigint;
  paymasterPostOpGasLimit?: bigint;
  paymasterData?: Hex;
  signature: Hex;
};

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

/** Thrown when the peer answered but with a JSON-RPC `error` member. */
class JsonRpcError extends Error {}

async function jsonRpc<T>(
  url: string,
  method: string,
  params: unknown[],
): Promise<T> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    signal: AbortSignal.timeout(20_000),
  });
  const body = (await response.json()) as {
    result?: T;
    error?: { code: number; message: string };
  };
  if (body.error) {
    throw new JsonRpcError(`${url} ${method}: ${body.error.message}`);
  }
  return body.result as T;
}

async function reachable(url: string): Promise<boolean> {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(1_000) });
    return response.ok;
  } catch {
    return false;
  }
}

const packLimits = (high: bigint, low: bigint): Hex =>
  concat([pad(toHex(high), { size: 16 }), pad(toHex(low), { size: 16 })]);

function pack(op: UnpackedUserOperation): PackedUserOperation {
  return {
    sender: op.sender,
    nonce: op.nonce,
    initCode: "0x",
    callData: op.callData,
    accountGasLimits: packLimits(op.verificationGasLimit, op.callGasLimit),
    preVerificationGas: op.preVerificationGas,
    gasFees: packLimits(op.maxPriorityFeePerGas, op.maxFeePerGas),
    paymasterAndData: op.paymaster
      ? concat([
          op.paymaster,
          pad(toHex(op.paymasterVerificationGasLimit ?? 0n), { size: 16 }),
          pad(toHex(op.paymasterPostOpGasLimit ?? 0n), { size: 16 }),
          op.paymasterData ?? "0x",
        ])
      : "0x",
    signature: op.signature,
  };
}

function toRpcUserOperation(op: UnpackedUserOperation) {
  return {
    sender: op.sender,
    nonce: numberToHex(op.nonce),
    callData: op.callData,
    callGasLimit: numberToHex(op.callGasLimit),
    verificationGasLimit: numberToHex(op.verificationGasLimit),
    preVerificationGas: numberToHex(op.preVerificationGas),
    maxFeePerGas: numberToHex(op.maxFeePerGas),
    maxPriorityFeePerGas: numberToHex(op.maxPriorityFeePerGas),
    signature: op.signature,
    ...(op.paymaster
      ? {
          paymaster: op.paymaster,
          paymasterVerificationGasLimit: numberToHex(
            op.paymasterVerificationGasLimit ?? 0n,
          ),
          paymasterPostOpGasLimit: numberToHex(
            op.paymasterPostOpGasLimit ?? 0n,
          ),
          paymasterData: op.paymasterData ?? "0x",
        }
      : {}),
  };
}

type PaymasterFields = {
  paymaster: Address;
  paymasterData: Hex;
  paymasterVerificationGasLimit: bigint;
  paymasterPostOpGasLimit: bigint;
};

/**
 * ERC-7677 (`pm_getPaymasterData`) with a fallback to pimlico's older
 * `pm_sponsorUserOperation`; the mock verifying paymaster has shipped both.
 */
async function sponsor(
  op: UnpackedUserOperation,
  chainId: number,
): Promise<PaymasterFields> {
  const rpcOp = toRpcUserOperation(op);
  let result: Record<string, Hex>;
  try {
    result = await jsonRpc<Record<string, Hex>>(
      MOCK_PAYMASTER_URL,
      "pm_getPaymasterData",
      [rpcOp, entryPoint07Address, numberToHex(chainId), {}],
    );
  } catch (error) {
    if (!(error instanceof JsonRpcError)) throw error;
    result = await jsonRpc<Record<string, Hex>>(
      MOCK_PAYMASTER_URL,
      "pm_sponsorUserOperation",
      [rpcOp, entryPoint07Address],
    );
  }
  const toGas = (value: Hex | undefined) =>
    value ? BigInt(value) : DEFAULT_PAYMASTER_GAS;
  return {
    paymaster: getAddress(result.paymaster),
    paymasterData: result.paymasterData,
    paymasterVerificationGasLimit: toGas(result.paymasterVerificationGasLimit),
    paymasterPostOpGasLimit: toGas(result.paymasterPostOpGasLimit),
  };
}

// ---------------------------------------------------------------------------
// Preconditions: the Alto stack runs outside `bun run test:e2e`.
// ---------------------------------------------------------------------------

async function findBlocker(): Promise<string | undefined> {
  if (!(await reachable(`${ALTO_URL}/health`))) {
    return `Alto is not running at ${ALTO_URL}`;
  }
  if (!(await reachable(`${MOCK_PAYMASTER_URL}/ping`))) {
    return `mock paymaster is not running at ${MOCK_PAYMASTER_URL}`;
  }
  let bundlerChainId: number;
  try {
    bundlerChainId = Number(await jsonRpc<Hex>(ALTO_URL, "eth_chainId", []));
  } catch {
    return `Alto at ${ALTO_URL} did not answer eth_chainId`;
  }
  let nodeChainId: number;
  try {
    nodeChainId = Number(
      await jsonRpc<Hex>(ALTO_CHAIN_RPC_URL, "eth_chainId", []),
    );
  } catch {
    return `no JSON-RPC node at ${ALTO_CHAIN_RPC_URL}`;
  }
  if (nodeChainId !== bundlerChainId) {
    return `${ALTO_CHAIN_RPC_URL} is chain ${nodeChainId}, Alto bundles for chain ${bundlerChainId}`;
  }
  const entryPointCode = await jsonRpc<Hex>(ALTO_CHAIN_RPC_URL, "eth_getCode", [
    entryPoint07Address,
    "latest",
  ]);
  if (!entryPointCode || entryPointCode === "0x") {
    return `EntryPoint v0.7 is not deployed on chain ${nodeChainId}`;
  }
  return undefined;
}

const accountArtifactUrl = new URL(
  "../../out/MockEntryPointAccount.sol/MockEntryPointAccount.json",
  import.meta.url,
);
const accountArtifact = await readFile(accountArtifactUrl, "utf8")
  .then((json) => JSON.parse(json) as { abi: Abi; bytecode: { object: Hex } })
  .catch(() => undefined);

const blocker = accountArtifact
  ? await findBlocker()
  : "MockEntryPointAccount has not been compiled by `forge build`";

if (blocker) {
  console.log(`Skipping Alto bundler e2e: ${blocker}`);
}

const describeAlto = blocker ? describe.skip : describe;

describeAlto("UserOperation through Alto vs in-process handleOps", () => {
  const artifact = accountArtifact!;
  const deployer = privateKeyToAccount(DEPLOYER_KEY);
  const owner = privateKeyToAccount(ACCOUNT_OWNER_KEY);
  const transport = http(ALTO_CHAIN_RPC_URL);
  const publicClient = createPublicClient({ transport });
  const walletClient = createWalletClient({ account: deployer, transport });

  async function deployAccount(): Promise<Address> {
    const hash = await walletClient.deployContract({
      abi: artifact.abi,
      bytecode: artifact.bytecode.object,
      args: [entryPoint07Address, owner.address],
      chain: null,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    expect(receipt.status).toBe("success");
    return getAddress(receipt.contractAddress!);
  }

  const bumpCall = (account: Address): Hex =>
    encodeFunctionData({
      abi: artifact.abi,
      functionName: "execute",
      args: [
        account,
        0n,
        encodeFunctionData({ abi: artifact.abi, functionName: "bump" }),
      ],
    });

  const readBumps = (account: Address) =>
    publicClient.readContract({
      address: account,
      abi: artifact.abi,
      functionName: "bumps",
    }) as Promise<bigint>;

  const readDeposit = (account: Address) =>
    publicClient.readContract({
      address: entryPoint07Address,
      abi: entryPointAbi,
      functionName: "balanceOf",
      args: [account],
    });

  async function gasFees() {
    try {
      const prices = await jsonRpc<{
        fast: { maxFeePerGas: Hex; maxPriorityFeePerGas: Hex };
      }>(ALTO_URL, "pimlico_getUserOperationGasPrice", []);
      return {
        maxFeePerGas: BigInt(prices.fast.maxFeePerGas),
        maxPriorityFeePerGas: BigInt(prices.fast.maxPriorityFeePerGas),
      };
    } catch {
      const fees = await publicClient.estimateFeesPerGas();
      return {
        maxFeePerGas: fees.maxFeePerGas,
        maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
      };
    }
  }

  async function sign(op: UnpackedUserOperation): Promise<Hex> {
    const userOpHash = await publicClient.readContract({
      address: entryPoint07Address,
      abi: entryPointAbi,
      functionName: "getUserOpHash",
      args: [pack(op)],
    });
    return owner.signMessage({ message: { raw: userOpHash } });
  }

  it(
    "the bundler leg is paymaster-sponsored and the direct leg is not, both bump the account",
    async () => {
      const chainId = await publicClient.getChainId();
      const bundlerAccount = await deployAccount();
      const directAccount = await deployAccount();
      const fees = await gasFees();

      // ---- leg 1: through Alto + the mock verifying paymaster ------------
      const unsponsored: UnpackedUserOperation = {
        sender: bundlerAccount,
        nonce: 0n,
        callData: bumpCall(bundlerAccount),
        callGasLimit: CALL_GAS_LIMIT,
        verificationGasLimit: VERIFICATION_GAS_LIMIT,
        preVerificationGas: PRE_VERIFICATION_GAS,
        ...fees,
        // well-formed 65 bytes so simulation reaches SIG_VALIDATION_FAILED
        // rather than tripping over a malformed signature.
        signature: await owner.signMessage({ message: "estimation" }),
      };
      // the verifying paymaster signs over everything but `signature`, so the
      // paymaster fields have to be settled before the owner signs.
      const sponsored: UnpackedUserOperation = {
        ...unsponsored,
        ...(await sponsor(unsponsored, chainId)),
      };
      sponsored.signature = await sign(sponsored);
      const paymaster = sponsored.paymaster!;
      const paymasterDepositBefore = await readDeposit(paymaster);

      const userOpHash = await jsonRpc<Hex>(ALTO_URL, "eth_sendUserOperation", [
        toRpcUserOperation(sponsored),
        entryPoint07Address,
      ]);

      const deadline = Date.now() + 45_000;
      let receipt:
        | { success: boolean; actualGasCost: Hex; receipt: { status: Hex } }
        | null = null;
      while (!receipt && Date.now() < deadline) {
        receipt = await jsonRpc(ALTO_URL, "eth_getUserOperationReceipt", [
          userOpHash,
        ]);
        if (!receipt) await Bun.sleep(250);
      }
      expect(receipt).not.toBeNull();
      expect(receipt!.success).toBe(true);
      expect(await readBumps(bundlerAccount)).toBe(1n);
      // the paymaster's deposit, not the account's, funded execution
      expect(await readDeposit(paymaster)).toBe(
        paymasterDepositBefore - BigInt(receipt!.actualGasCost),
      );
      expect(
        await publicClient.readContract({
          address: entryPoint07Address,
          abi: entryPointAbi,
          functionName: "getNonce",
          args: [bundlerAccount, 0n],
        }),
      ).toBe(1n);

      // ---- leg 2: the same UserOperation via EntryPoint.handleOps() ------
      const depositHash = await walletClient.writeContract({
        address: entryPoint07Address,
        abi: entryPointAbi,
        functionName: "depositTo",
        args: [directAccount],
        value: parseEther("0.05"),
        chain: null,
      });
      await publicClient.waitForTransactionReceipt({ hash: depositHash });
      const depositBefore = await readDeposit(directAccount);
      expect(depositBefore).toBe(parseEther("0.05"));

      const direct: UnpackedUserOperation = {
        ...unsponsored,
        sender: directAccount,
        callData: bumpCall(directAccount),
      };
      direct.signature = await sign(direct);

      const handleOpsHash = await walletClient.writeContract({
        address: entryPoint07Address,
        abi: entryPointAbi,
        functionName: "handleOps",
        args: [[pack(direct)], deployer.address],
        chain: null,
      });
      const handleOpsReceipt = await publicClient.waitForTransactionReceipt({
        hash: handleOpsHash,
      });
      expect(handleOpsReceipt.status).toBe("success");

      expect(await readBumps(directAccount)).toBe(1n);
      // no paymaster here, so the account's own deposit paid for the op
      expect(await readDeposit(directAccount)).toBeLessThan(depositBefore);
      expect(
        await publicClient.readContract({
          address: entryPoint07Address,
          abi: entryPointAbi,
          functionName: "getNonce",
          args: [directAccount, 0n],
        }),
      ).toBe(1n);
    },
    120_000,
  );
});
