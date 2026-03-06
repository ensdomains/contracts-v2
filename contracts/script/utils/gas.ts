import type { TransactionReceipt } from "viem";

// ========== Gas Tracking ==========

type GasRecord = {
  operation: string;
  gasUsed: bigint;
  effectiveGasPrice?: bigint;
  totalCost?: bigint;
};

const gasTracker: GasRecord[] = [];

export async function trackGas(
  operation: string,
  receipt: TransactionReceipt,
): Promise<void> {
  const gasUsed = BigInt(receipt.gasUsed);
  const effectiveGasPrice = receipt.effectiveGasPrice
    ? BigInt(receipt.effectiveGasPrice)
    : 0n;
  gasTracker.push({
    operation,
    gasUsed,
    effectiveGasPrice,
    totalCost: gasUsed * effectiveGasPrice,
  });
}

export function displayGasReport() {
  if (gasTracker.length === 0) {
    console.log("\nNo gas data collected.");
    return;
  }

  console.log("\n========== Gas Usage Report ==========");

  const groupedByFunction = new Map<string, bigint[]>();

  for (const { operation, gasUsed } of gasTracker) {
    const functionName = operation.split("(")[0];
    if (!groupedByFunction.has(functionName)) {
      groupedByFunction.set(functionName, []);
    }
    groupedByFunction.get(functionName)!.push(gasUsed);
  }

  const reportData = Array.from(groupedByFunction.entries()).map(
    ([functionName, gasValues]) => {
      const count = gasValues.length;
      const total = gasValues.reduce((sum, val) => sum + val, 0n);
      const avg = total / BigInt(count);
      const min = gasValues.reduce(
        (min, val) => (val < min ? val : min),
        gasValues[0],
      );
      const max = gasValues.reduce(
        (max, val) => (val > max ? val : max),
        gasValues[0],
      );

      return {
        Function: functionName,
        Calls: count,
        "Avg Gas": avg.toString(),
        "Min Gas": min.toString(),
        "Max Gas": max.toString(),
        "Total Gas": total.toString(),
      };
    },
  );

  console.table(reportData);

  const totalGas = gasTracker.reduce((sum, { gasUsed }) => sum + gasUsed, 0n);
  const totalCostWei = gasTracker.reduce(
    (sum, { totalCost }) => sum + (totalCost || 0n),
    0n,
  );

  console.log(`\nTotal Gas Used: ${totalGas.toString()}`);
  console.log(`Total Cost: ${totalCostWei.toString()} wei`);
  console.log(`Total Transactions: ${gasTracker.length}`);
  console.log("======================================\n");
}

export function resetGasTracker() {
  gasTracker.length = 0;
}
