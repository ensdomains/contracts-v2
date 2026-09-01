import {
  createWalletClient,
  encodeFunctionData,
  http,
  parseEther,
  type Address,
  type Chain,
  type Hex,
} from "viem";

import { Artifact_MigrationFixtureBatcher } from "generated/artifacts/MigrationFixtureBatcher.js";

import { receipt, rpc } from "./config.js";
import type { PlannedCall, Signer } from "./plan.js";
import type { CommonOptions, FixtureActor } from "./types.js";

/// Calls the batcher can aggregate into one transaction. Kept well below the
/// block gas limit; setup calls are small but wrapping is not.
const DEFAULT_BATCH_SIZE = 40;

export type Executor = {
  opts: CommonOptions;
  chain: Chain;
  client: any;
  wallet: any;
  batcher: Address;
  actors: Map<string, FixtureActor>;
};

function signerKey(signer: Signer): string {
  return signer.kind === "batcher" ? "batcher" : `actor:${signer.alias}`;
}

/// Splits a call list into maximal runs of calls sharing one signer, preserving
/// order. Ordering within a name is significant — a resolver must be set before
/// a fuse burn freezes it — so runs are never reordered relative to each other.
export function segmentBySigner(calls: PlannedCall[]): PlannedCall[][] {
  const runs: PlannedCall[][] = [];
  for (const call of calls) {
    const last = runs[runs.length - 1];
    if (last && signerKey(last[0].signer) === signerKey(call.signer)) {
      last.push(call);
    } else {
      runs.push([call]);
    }
  }
  return runs;
}

/// Schedules planned calls for many names.
///
/// Names are independent of each other but each name's calls are ordered, so
/// work proceeds in rounds: every name contributes its next same-signer run,
/// those runs are grouped by signer and executed, then the next round begins.
/// This keeps per-name ordering intact while still aggregating batcher calls
/// across names into full batches.
export async function executePlannedCalls(
  ex: Executor,
  perName: Map<string, PlannedCall[]>,
  onTransaction?: (fixtureId: string, hash: Hex) => void,
  batchSize = DEFAULT_BATCH_SIZE,
): Promise<void> {
  const queues = new Map<string, PlannedCall[][]>();
  for (const [id, calls] of perName) {
    if (calls.length) queues.set(id, segmentBySigner(calls));
  }

  let round = 0;
  while (queues.size) {
    round += 1;
    const batcherWork: { id: string; calls: PlannedCall[] }[] = [];
    const actorWork = new Map<string, { id: string; calls: PlannedCall[] }[]>();

    for (const [id, runs] of [...queues]) {
      const run = runs.shift();
      if (!run) {
        queues.delete(id);
        continue;
      }
      if (!runs.length) queues.delete(id);
      if (run[0].signer.kind === "batcher") {
        batcherWork.push({ id, calls: run });
      } else {
        const alias = run[0].signer.alias;
        const list = actorWork.get(alias);
        if (list) list.push({ id, calls: run });
        else actorWork.set(alias, [{ id, calls: run }]);
      }
    }

    // Batcher runs from different names may be concatenated freely.
    const flatBatcher = batcherWork.flatMap((w) =>
      w.calls.map((c) => ({ id: w.id, call: c })),
    );
    for (let i = 0; i < flatBatcher.length; i += batchSize) {
      const slice = flatBatcher.slice(i, i + batchSize);
      const hash = await executeBatcherCalls(
        ex,
        slice.map((s) => s.call),
        `round ${round} batcher (${slice.length} calls)`,
      );
      if (hash && onTransaction) {
        for (const s of slice) onTransaction(s.id, hash);
      }
    }

    // Actor runs must each be a separate transaction from that actor.
    for (const [alias, work] of actorWork) {
      for (const { id, calls } of work) {
        for (const call of calls) {
          const hash = await executeAsActor(ex, alias, call);
          if (hash && onTransaction) onTransaction(id, hash);
        }
      }
    }
  }
}

export async function executeBatcherCalls(
  ex: Executor,
  calls: PlannedCall[],
  label: string,
): Promise<Hex | undefined> {
  if (!calls.length) return undefined;
  const value = calls.reduce((sum, c) => sum + c.value, 0n);
  const hash = await ex.wallet.writeContract({
    address: ex.batcher,
    abi: Artifact_MigrationFixtureBatcher.abi,
    functionName: "executeBatch",
    args: [
      calls.map((c) => ({
        target: c.target,
        value: c.value,
        data: c.data,
        allowFailure: c.allowFailure,
      })),
    ],
    value,
  });
  await receipt(ex.client, hash, label);
  return hash;
}

export async function actorWallet(ex: Executor, alias: string) {
  const actor = ex.actors.get(alias);
  if (!actor) throw new Error(`unknown actor alias "${alias}"`);
  if (ex.opts.rpcStateControls) {
    await fundAndImpersonate(ex.opts, actor.account.address);
  }
  return createWalletClient({
    chain: ex.chain,
    account: actor.account,
    transport: http(ex.opts.rpcUrl),
  });
}

async function executeAsActor(
  ex: Executor,
  alias: string,
  call: PlannedCall,
): Promise<Hex | undefined> {
  const wallet = await actorWallet(ex, alias);
  try {
    const hash = await wallet.sendTransaction({
      to: call.target,
      data: call.data,
      value: call.value,
    });
    await receipt(ex.client, hash, `${alias}: ${call.label}`);
    return hash;
  } catch (error) {
    if (call.allowFailure) return undefined;
    throw error;
  }
}

export async function fundAndImpersonate(
  opts: CommonOptions,
  address: Address,
): Promise<void> {
  if (!opts.rpcStateControls) return;
  await rpc(opts, "anvil_setBalance", [address, "0x8ac7230489e80000"]).catch(async () => {
    await rpc(opts, "hardhat_setBalance", [address, "0x8ac7230489e80000"]);
  });
  await rpc(opts, "anvil_impersonateAccount", [address]).catch(async () => {
    await rpc(opts, "hardhat_impersonateAccount", [address]);
  });
}

/// Tops every fixture actor up to a floor balance from the operator key. Actor
/// transactions are a large share of seeding, so they need funding before a run
/// rather than failing part-way through.
export async function fundActors(
  ex: Executor,
  floorEth: string,
): Promise<void> {
  const floor = parseEther(floorEth);
  for (const [alias, actor] of ex.actors) {
    const balance = (await ex.client.getBalance({
      address: actor.account.address,
    })) as bigint;
    if (balance >= floor) continue;
    const topUp = floor - balance;
    const hash = await ex.wallet.sendTransaction({
      to: actor.account.address,
      value: topUp,
    });
    await receipt(ex.client, hash, `fund ${alias}`);
  }
}
