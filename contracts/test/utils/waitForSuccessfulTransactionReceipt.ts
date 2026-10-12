import {
  type Address,
  type Client,
  type Hash,
  type TransactionReceipt,
  BaseError,
} from "viem";
import {
  call,
  getBlock,
  getTransaction,
  waitForTransactionReceipt,
} from "viem/actions";

type WaitForSuccessfulTransactionReceiptParams = {
  hash: Hash;
  ensureDeployment?: boolean;
};

type SuccessfulTransactionReceipt = TransactionReceipt & { status: "success" };
type DeployedTransactionReceipt = SuccessfulTransactionReceipt & {
  contractAddress: Address;
};

export async function waitForSuccessfulTransactionReceipt(
  client: Client,
  { hash, ensureDeployment }: { hash: Hash; ensureDeployment: true },
): Promise<DeployedTransactionReceipt>;
export async function waitForSuccessfulTransactionReceipt(
  client: Client,
  { hash, ensureDeployment }: { hash: Hash; ensureDeployment?: false },
): Promise<SuccessfulTransactionReceipt>;
export async function waitForSuccessfulTransactionReceipt(
  client: Client,
  { hash, ensureDeployment }: WaitForSuccessfulTransactionReceiptParams,
): Promise<TransactionReceipt> {
  const receipt = await waitForTransactionReceipt(client, { hash });
  if (ensureDeployment && receipt.contractAddress === null)
    throw new Error("Deployment failed");
  if (receipt.status !== "success")
    throw new Error(
      `Transaction failed: ${await describeRevert(client, receipt)}`,
    );
  return receipt;
}

/// Describes a reverted transaction: the call it made, the block it landed in,
/// and the revert reason found by replaying the call on the state just before
/// that block. The replay can pass where the original failed when an earlier
/// transaction in the same block caused the revert, so the replay result is
/// reported as such rather than as the cause.
async function describeRevert(
  client: Client,
  receipt: TransactionReceipt,
): Promise<string> {
  const [tx, block] = await Promise.all([
    getTransaction(client, { hash: receipt.transactionHash }),
    getBlock(client, { blockNumber: receipt.blockNumber }),
  ]);
  const parts = [
    `hash ${receipt.transactionHash}`,
    `from ${tx.from}`,
    `to ${tx.to ?? "(deployment)"}`,
    `selector ${tx.input.slice(0, 10)}`,
    `block ${receipt.blockNumber} at timestamp ${block.timestamp}`,
    `gas used ${receipt.gasUsed} of ${tx.gas}`,
  ];
  try {
    await call(client, {
      account: tx.from,
      to: tx.to,
      data: tx.input,
      value: tx.value,
      gas: tx.gas,
      blockNumber: receipt.blockNumber - 1n,
    });
    parts.push("replay on the parent block succeeds");
  } catch (error) {
    if (error instanceof BaseError) {
      const raw = error.walk(
        (e) => typeof (e as { data?: unknown }).data === "string",
      ) as { data?: string } | null;
      parts.push(
        `replay on the parent block reverts: ${error.shortMessage}${raw?.data ? ` (data ${raw.data})` : ""}`,
      );
    } else {
      parts.push(`replay on the parent block fails: ${String(error)}`);
    }
  }
  return parts.join("; ");
}
