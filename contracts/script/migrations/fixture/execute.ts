import {
  BaseError,
  ContractFunctionRevertedError,
  createWalletClient,
  decodeErrorResult,
  ExecutionRevertedError,
  http,
  isHex,
  type Abi,
  type Address,
  type Chain,
  type Hex,
} from "viem";

import { Artifact_BaseRegistrarImplementation } from "generated/artifacts/BaseRegistrarImplementation.js";
import { Artifact_ENSRegistry } from "generated/artifacts/ENSRegistry.js";
import { Artifact_ETHRegistrarController } from "generated/artifacts/ETHRegistrarController.js";
import { Artifact_MigrationFixtureBatcher } from "generated/artifacts/MigrationFixtureBatcher.js";
import { Artifact_NameWrapper } from "generated/artifacts/NameWrapper.js";
import { Artifact_PublicResolver } from "generated/artifacts/PublicResolver.js";
import { Artifact_ReverseRegistrar } from "generated/artifacts/ReverseRegistrar.js";

import {
  bufferedGas,
  fundingTargets,
  receipt,
  rpcAny,
  v1Deployment,
  withPriceBuffer,
} from "./config.js";
import { EthRegistrarController } from "../abis.js";
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

/// A name whose setup was abandoned: the call a contract refused, and why.
export type SetAside = { fixtureId: string; call: string; reason: string };

export type ExecutionHooks = {
  onTransaction?: (fixtureId: string, hash: Hex) => void;
  onNameComplete?: (fixtureId: string) => Promise<void> | void;
  onNameSetAside?: (setAside: SetAside) => Promise<void> | void;
};

/// Schedules planned calls for many names.
///
/// Names are independent of each other but each name's calls are ordered, so
/// work proceeds in rounds: every name contributes its next same-signer run,
/// those runs are grouped by signer and executed, then the next round begins.
/// This keeps per-name ordering intact while still aggregating batcher calls
/// across names into full batches.
///
/// Because names are independent, a contract refusing one name's call is that
/// name's fault alone. The name is set aside with the refusal and the rest carry
/// on, where stopping would leave every name in the round part-shaped. Anything
/// that is not a refusal — a dropped connection, a nonce clash, a transaction
/// that reverted after its estimate passed — says nothing about one name, so it
/// still stops the run.
///
/// Returns the names set aside, in the order they were.
export async function executePlannedCalls(
  ex: Executor,
  perName: Map<string, PlannedCall[]>,
  hooks: ExecutionHooks = {},
  batchSize = DEFAULT_BATCH_SIZE,
): Promise<SetAside[]> {
  const queues = new Map<string, PlannedCall[][]>();
  for (const [id, calls] of perName) {
    if (calls.length) queues.set(id, segmentBySigner(calls));
  }

  const setAside: SetAside[] = [];
  const abandoned = new Set<string>();
  const abandon = async (id: string, call: PlannedCall, reason: string) => {
    abandoned.add(id);
    queues.delete(id);
    const entry = { fixtureId: id, call: call.label, reason };
    setAside.push(entry);
    await hooks.onNameSetAside?.(entry);
  };

  let round = 0;
  while (queues.size) {
    round += 1;
    const batcherWork: { id: string; calls: PlannedCall[] }[] = [];
    const actorWork = new Map<string, { id: string; calls: PlannedCall[] }[]>();

    // A name whose last run is dispatched this round is finished once the round
    // executes, which is when its checkpoint can be written.
    const finishing: string[] = [];
    for (const [id, runs] of [...queues]) {
      const run = runs.shift();
      if (!run) {
        queues.delete(id);
        continue;
      }
      if (!runs.length) {
        queues.delete(id);
        finishing.push(id);
      }
      if (run[0].signer.kind === "batcher") {
        batcherWork.push({ id, calls: run });
      } else {
        const alias = run[0].signer.alias;
        const list = actorWork.get(alias);
        if (list) list.push({ id, calls: run });
        else actorWork.set(alias, [{ id, calls: run }]);
      }
    }

    // Batcher runs from different names may be concatenated freely. A refused
    // call takes its whole name out of the batch, which is then retried.
    const flatBatcher = batcherWork.flatMap((w) =>
      w.calls.map((c) => ({ id: w.id, call: c })),
    );
    for (let i = 0; i < flatBatcher.length; i += batchSize) {
      let slice = flatBatcher.slice(i, i + batchSize);
      while ((slice = slice.filter((s) => !abandoned.has(s.id))).length) {
        try {
          const hash = await executeBatcherCalls(
            ex,
            slice.map((s) => s.call),
            `round ${round} batcher (${slice.length} calls)`,
          );
          if (hash) for (const s of slice) hooks.onTransaction?.(s.id, hash);
          break;
        } catch (error) {
          const refused = refusedBatchCall(error);
          const failed = refused && slice[refused.index];
          if (!failed) throw error;
          await abandon(failed.id, failed.call, refused.reason);
        }
      }
    }

    // Actor runs must each be a separate transaction from that actor.
    for (const [alias, work] of actorWork) {
      for (const { id, calls } of work) {
        for (const call of calls) {
          let hash: Hex | undefined;
          try {
            hash = await executeAsActor(ex, alias, call);
          } catch (error) {
            const reason = refusalReason(error);
            if (reason === null) throw error;
            await abandon(id, call, reason);
            break;
          }
          if (hash) hooks.onTransaction?.(id, hash);
        }
      }
    }

    for (const id of finishing) {
      if (!abandoned.has(id)) await hooks.onNameComplete?.(id);
    }
  }
  return setAside;
}

/// The call a batch was refused on, when the batcher names one.
///
/// The batcher reverts with the position of the first call that failed and that
/// call's own revert data, so the refusal can be pinned on one name.
function refusedBatchCall(
  error: unknown,
): { index: number; reason: string } | null {
  if (!(error instanceof BaseError)) return null;
  const reverted = error.walk(
    (e) => e instanceof ContractFunctionRevertedError,
  ) as ContractFunctionRevertedError | null;
  if (reverted?.data?.errorName !== "CallFailed") return null;
  const [index, , data] = reverted.data.args as readonly [bigint, Address, Hex];
  return { index: Number(index), reason: describeRevert(data) };
}

/// What a contract said when it refused a call, or null when the error is not a
/// refusal at all but a failure to get the call to the chain.
function refusalReason(error: unknown): string | null {
  if (!(error instanceof BaseError)) return null;
  const reverted = error.walk(
    (e) =>
      e instanceof ExecutionRevertedError ||
      e instanceof ContractFunctionRevertedError,
  );
  if (!reverted) return null;
  const data = error.walk(
    (e) =>
      typeof (e as { data?: unknown }).data === "string" &&
      isHex((e as { data: string }).data),
  ) as { data: Hex } | null;
  return data
    ? describeRevert(data.data)
    : (reverted as BaseError).shortMessage;
}

/// Every custom error the v1 contracts that setup writes through can revert
/// with, so a refusal is reported by name rather than as raw bytes.
const V1_ERRORS: Abi = [
  Artifact_BaseRegistrarImplementation.abi,
  Artifact_ENSRegistry.abi,
  Artifact_ETHRegistrarController.abi,
  Artifact_NameWrapper.abi,
  Artifact_PublicResolver.abi,
  Artifact_ReverseRegistrar.abi,
].flatMap((abi: Abi) => abi.filter((entry) => entry.type === "error"));

/// Names a revert from the v1 contracts' errors, falling back to its raw bytes.
function describeRevert(data: Hex): string {
  if (data === "0x") return "reverted without a reason";
  try {
    const { errorName, args } = decodeErrorResult({ abi: V1_ERRORS, data });
    return `${errorName}(${(args ?? []).map(String).join(", ")})`;
  } catch {
    return `reverted with unrecognised data ${data}`;
  }
}

const RENT_PRICE_ABI = EthRegistrarController.rentPrice;

/// Resolves any quoted price into the value the call must carry.
async function resolveCallValue(
  ex: Executor,
  call: PlannedCall,
): Promise<bigint> {
  if (!call.quote) return call.value;
  const controller = v1Deployment(ex.opts, "ETHRegistrarController");
  const price = (await ex.client.readContract({
    address: controller.address,
    abi: RENT_PRICE_ABI,
    functionName: "rentPrice",
    args: [call.quote.label, call.quote.duration],
  })) as { base: bigint; premium: bigint };
  return withPriceBuffer(price.base + price.premium);
}

async function pricedCalls(
  ex: Executor,
  calls: PlannedCall[],
): Promise<PlannedCall[]> {
  if (!calls.some((c) => c.quote)) return calls;
  return Promise.all(
    calls.map(async (c) =>
      c.quote ? { ...c, value: await resolveCallValue(ex, c) } : c,
    ),
  );
}

export async function executeBatcherCalls(
  ex: Executor,
  rawCalls: PlannedCall[],
  label: string,
): Promise<Hex | undefined> {
  if (!rawCalls.length) return undefined;
  const calls = await pricedCalls(ex, rawCalls);
  const value = calls.reduce((sum, c) => sum + c.value, 0n);
  const args = [
    calls.map((c) => ({
      target: c.target,
      value: c.value,
      data: c.data,
      allowFailure: c.allowFailure,
    })),
  ] as const;
  const hash = await ex.wallet.writeContract({
    address: ex.batcher,
    abi: Artifact_MigrationFixtureBatcher.abi,
    functionName: "executeBatch",
    args,
    value,
    gas: await bufferedGas(ex.client, {
      address: ex.batcher,
      abi: Artifact_MigrationFixtureBatcher.abi,
      functionName: "executeBatch",
      args,
      value,
      account: ex.wallet.account,
    }),
  });
  await receipt(ex.client, hash, label);
  return hash;
}

export async function actorWallet(ex: Executor, alias: string) {
  const actor = ex.actors.get(alias);
  if (!actor) throw new Error(`unknown actor alias "${alias}"`);
  // Actors are local HD accounts that sign their own transactions, so they only
  // need a balance — unlocking them at the node would do nothing.
  await fundAccount(ex.opts, actor.account.address);
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
      value: await resolveCallValue(ex, call),
    });
    await receipt(ex.client, hash, `${alias}: ${call.label}`);
    return hash;
  } catch (error) {
    if (call.allowFailure) return undefined;
    throw error;
  }
}

/// Balance a state-controlled endpoint hands an account that needs gas.
const STATE_CONTROL_BALANCE = "0x8ac7230489e80000";

/// Tops an account up through whichever state-control method the endpoint has.
export async function fundAccount(
  opts: CommonOptions,
  address: Address,
): Promise<void> {
  if (!opts.rpcStateControls) return;
  await rpcAny(opts, [
    { method: "anvil_setBalance", params: [address, STATE_CONTROL_BALANCE] },
    { method: "hardhat_setBalance", params: [address, STATE_CONTROL_BALANCE] },
    { method: "tenderly_setBalance", params: [address, STATE_CONTROL_BALANCE] },
    {
      method: "tenderly_setBalance",
      params: [[address], STATE_CONTROL_BALANCE],
    },
  ]);
}

/// Unlocks an account the run has no key for, and funds it so it can pay gas.
/// Only accounts signed for by the node need this; locally signed accounts just
/// need the balance.
export async function impersonateAccount(
  opts: CommonOptions,
  address: Address,
): Promise<void> {
  if (!opts.rpcStateControls) return;
  await rpcAny(opts, [
    { method: "anvil_impersonateAccount", params: [address] },
    { method: "hardhat_impersonateAccount", params: [address] },
    { method: "tenderly_impersonateAccount", params: [address] },
    { method: "tenderly_impersonateAccount", params: [[address]] },
  ]);
  await fundAccount(opts, address);
}

/// Address used only to prove the endpoint honours state-control calls. Nothing
/// signs from it, so overwriting its balance cannot disturb a run.
const STATE_CONTROL_PROBE =
  "0x000000000000000000000000000000000000dEaD" as Address;

/// Confirms the endpoint really offers state controls before a caller spends on
/// the strength of that claim. The flag is caller-asserted and nothing else
/// checks it, so a mistyped target would otherwise spend real funds before the
/// first state-control call revealed the mistake.
export async function assertStateControls(opts: CommonOptions): Promise<void> {
  if (!opts.rpcStateControls) return;
  try {
    await fundAccount(opts, STATE_CONTROL_PROBE);
  } catch (error) {
    throw new Error(
      `--rpc-state-controls was set but ${opts.rpcUrl} rejected every state-control method; ` +
        "point at a fork or a Tenderly virtual testnet",
      { cause: error },
    );
  }
}

/// Tops every fixture actor up to a floor balance from the operator key. Actor
/// transactions are a large share of seeding, so they need funding before a run
/// rather than failing part-way through.
///
/// Funding is per account, not per alias: aliases can share an account, and a
/// shared one has to arrive holding every alias's floor. Topping up per alias
/// would stop at the first, because the account already clears the check the
/// others are measured against.
///
/// An alias can also resolve to the account paying for the top-ups, which a
/// nominated owner wallet does when it holds the operator key too. Nothing can
/// be sent to it: a transfer out of an account and back leaves it poorer by the
/// gas. It is reported as a shortfall to fund elsewhere instead, which is the
/// same promise the command makes for every other account — that what the run
/// needs is there before the first name is registered.
export async function fundActors(
  ex: Executor,
  floorEth: string,
): Promise<void> {
  const funder = String(ex.wallet.account.address).toLowerCase();
  for (const target of fundingTargets(ex.actors.values(), floorEth)) {
    const balance = (await ex.client.getBalance({
      address: target.address,
    })) as bigint;
    if (balance >= target.required) continue;
    if (target.address.toLowerCase() === funder) {
      throw new Error(
        `${target.aliases.join("+")} is the funding account ${target.address}, ` +
          `which holds ${balance} of the ${target.required} wei this selection needs ` +
          "of it; fund it from outside the run",
      );
    }
    const hash = await ex.wallet.sendTransaction({
      to: target.address,
      value: target.required - balance,
    });
    await receipt(ex.client, hash, `fund ${target.aliases.join("+")}`);
  }
}
