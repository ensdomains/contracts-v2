import {
  encodeFunctionData,
  keccak256,
  namehash,
  stringToHex,
  toHex,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";

import {
  isChild,
  isWrapped,
  ownerControlledFuses,
  preMigrationOwnerAlias,
  resolveFuses,
  resolveOptionalRef,
  resolveRef,
  stripActorPrefix,
  v1Form,
  type RefContext,
} from "./scenario.js";
import { FUSES, type FixtureEnvelope, type RecordSpec, type SetupStep } from "./types.js";

/// Minimal explicit ABIs. The deployed PublicResolver exposes overloaded
/// `setAddr`, which viem cannot disambiguate from a full artifact ABI, so the
/// two arities are declared separately.
const RESOLVER_ABI = [
  {
    type: "function",
    name: "setAddr",
    stateMutability: "nonpayable",
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "a", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setText",
    stateMutability: "nonpayable",
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "key", type: "string" },
      { name: "value", type: "string" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setContenthash",
    stateMutability: "nonpayable",
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "hash", type: "bytes" },
    ],
    outputs: [],
  },
] as const;

const RESOLVER_MULTICOIN_ABI = [
  {
    type: "function",
    name: "setAddr",
    stateMutability: "nonpayable",
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "coinType", type: "uint256" },
      { name: "a", type: "bytes" },
    ],
    outputs: [],
  },
] as const;

const REGISTRY_ABI = [
  {
    type: "function",
    name: "setResolver",
    stateMutability: "nonpayable",
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "resolver", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setTTL",
    stateMutability: "nonpayable",
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "ttl", type: "uint64" },
    ],
    outputs: [],
  },
] as const;

const WRAPPER_ABI = [
  {
    type: "function",
    name: "wrapETH2LD",
    stateMutability: "nonpayable",
    inputs: [
      { name: "label", type: "string" },
      { name: "wrappedOwner", type: "address" },
      { name: "ownerControlledFuses", type: "uint16" },
      { name: "resolver", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "unwrapETH2LD",
    stateMutability: "nonpayable",
    inputs: [
      { name: "labelhash", type: "bytes32" },
      { name: "registrant", type: "address" },
      { name: "controller", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setSubnodeRecord",
    stateMutability: "nonpayable",
    inputs: [
      { name: "parentNode", type: "bytes32" },
      { name: "label", type: "string" },
      { name: "owner", type: "address" },
      { name: "resolver", type: "address" },
      { name: "ttl", type: "uint64" },
      { name: "fuses", type: "uint32" },
      { name: "expiry", type: "uint64" },
    ],
    outputs: [{ name: "node", type: "bytes32" }],
  },
  {
    type: "function",
    name: "setFuses",
    stateMutability: "nonpayable",
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "ownerControlledFuses", type: "uint16" },
    ],
    outputs: [{ name: "", type: "uint32" }],
  },
  {
    type: "function",
    name: "setResolver",
    stateMutability: "nonpayable",
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "resolver", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setTTL",
    stateMutability: "nonpayable",
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "ttl", type: "uint64" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "tokenId", type: "uint256" },
    ],
    outputs: [],
  },
] as const;

const ERC721_ABI = [
  {
    type: "function",
    name: "safeTransferFrom",
    stateMutability: "nonpayable",
    inputs: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "tokenId", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "reclaim",
    stateMutability: "nonpayable",
    inputs: [
      { name: "id", type: "uint256" },
      { name: "owner", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setApprovalForAll",
    stateMutability: "nonpayable",
    inputs: [
      { name: "operator", type: "address" },
      { name: "approved", type: "bool" },
    ],
    outputs: [],
  },
] as const;

const REVERSE_REGISTRAR_ABI = [
  {
    type: "function",
    name: "setName",
    stateMutability: "nonpayable",
    inputs: [{ name: "name", type: "string" }],
    outputs: [{ name: "", type: "bytes32" }],
  },
] as const;

const CONTROLLER_RENEW_ABI = [
  {
    type: "function",
    name: "renew",
    stateMutability: "payable",
    inputs: [
      { name: "name", type: "string" },
      { name: "duration", type: "uint256" },
      { name: "referrer", type: "bytes32" },
    ],
    outputs: [],
  },
] as const;

/// Who must sign a planned call. `batcher` means the MigrationFixtureBatcher,
/// which can be aggregated; an actor alias means a direct wallet transaction
/// because the action's authority or its emitted provenance depends on caller.
export type Signer = { kind: "batcher" } | { kind: "actor"; alias: string };

export type PlannedCall = {
  signer: Signer;
  target: Address;
  value: bigint;
  data: Hex;
  allowFailure: boolean;
  label: string;
};

export type PlanContext = RefContext & {
  batcher: Address;
  addresses: {
    baseRegistrar: Address;
    registry: Address;
    wrapper: Address;
    controller: Address;
    publicResolver: Address;
    reverseRegistrar: Address;
    defaultReverseRegistrar: Address;
  };
};

const BATCHER: Signer = { kind: "batcher" };
const actorSigner = (alias: string): Signer => ({ kind: "actor", alias });

export function labelhashOf(label: string): Hex {
  return keccak256(stringToHex(label));
}

export function tokenIdOf(label: string): bigint {
  return BigInt(labelhashOf(label));
}

/// Ownership of a fixture name over the course of its setup. Names are
/// registered to the batcher, handed to the scenario's initial owner, and may
/// move again via `transfer_registrant`; each planned call records the actor
/// who is authorised at that point.
class OwnershipCursor {
  constructor(private current: string) {}
  get alias(): string {
    return this.current;
  }
  set(alias: string) {
    this.current = alias;
  }
}

function recordCalls(
  resolver: Address,
  node: Hex,
  records: readonly RecordSpec[],
  ctx: PlanContext,
  signer: Signer,
  labelPrefix: string,
): PlannedCall[] {
  const calls: PlannedCall[] = [];
  for (const record of records) {
    if (record.kind === "addr") {
      const coinType = record.coin_type ?? 60;
      const value = record.value_actor
        ? resolveRef(record.value_actor, ctx)
        : ((record.value ?? zeroAddress) as Address);
      calls.push({
        signer,
        target: resolver,
        value: 0n,
        allowFailure: false,
        label: `${labelPrefix} setAddr(${coinType})`,
        data:
          coinType === 60
            ? encodeFunctionData({
                abi: RESOLVER_ABI,
                functionName: "setAddr",
                args: [node, value],
              })
            : encodeFunctionData({
                abi: RESOLVER_MULTICOIN_ABI,
                functionName: "setAddr",
                args: [node, BigInt(coinType), value],
              }),
      });
    } else if (record.kind === "text") {
      calls.push({
        signer,
        target: resolver,
        value: 0n,
        allowFailure: false,
        label: `${labelPrefix} setText(${record.key})`,
        data: encodeFunctionData({
          abi: RESOLVER_ABI,
          functionName: "setText",
          args: [node, record.key ?? "", record.value ?? ""],
        }),
      });
    } else if (record.kind === "contenthash") {
      calls.push({
        signer,
        target: resolver,
        value: 0n,
        allowFailure: false,
        label: `${labelPrefix} setContenthash`,
        data: encodeFunctionData({
          abi: RESOLVER_ABI,
          functionName: "setContenthash",
          args: [node, (record.value ?? "0x") as Hex],
        }),
      });
    } else {
      throw new Error(`unknown record kind "${(record as RecordSpec).kind}"`);
    }
  }
  return calls;
}

/// Plans every V1 setup call for one fixture row, in corpus order.
///
/// The name is registered to the batcher, so calls that only need registry or
/// resolver authority are planned as batcher calls and can be aggregated. Calls
/// whose effect is derived from `msg.sender` — reverse claims — or which grant
/// authority on behalf of the holder — operator and token approvals — are
/// planned against the actor that must sign them.
export function planSetupSteps(
  row: FixtureEnvelope,
  ctx: PlanContext,
): PlannedCall[] {
  const scenario = row.scenario;
  const form = v1Form(scenario);
  const wrapped = isWrapped(form);
  const child = isChild(form);
  const label = scenario.top_level_label;
  const node = namehash(scenario.name) as Hex;
  const topNode = namehash(`${label}.eth`) as Hex;
  const tokenId = tokenIdOf(label);
  const calls: PlannedCall[] = [];

  const registrationOwner = stripActorPrefix(
    scenario.v1.registration.owner_actor ?? preMigrationOwnerAlias(scenario),
  );
  const cursor = new OwnershipCursor(registrationOwner);

  // While the batcher still holds the ERC-721, node-scoped writes are cheapest
  // and are authorised by the registry controller it already is.
  let heldByBatcher = true;
  const nodeSigner = (): Signer => (heldByBatcher ? BATCHER : actorSigner(cursor.alias));

  const registrationResolver = resolveOptionalRef(
    scenario.v1.registration.resolver_ref,
    ctx,
  );

  // Baseline resolver and records from the registration block, applied before
  // any step that may burn CANNOT_SET_RESOLVER.
  if (registrationResolver !== zeroAddress && !wrapped) {
    calls.push({
      signer: nodeSigner(),
      target: ctx.addresses.registry,
      value: 0n,
      allowFailure: false,
      label: `${row.fixture_id} registration setResolver`,
      data: encodeFunctionData({
        abi: REGISTRY_ABI,
        functionName: "setResolver",
        args: [node, registrationResolver],
      }),
    });
  }
  const registrationRecords = scenario.v1.registration.records ?? [];
  if (registrationRecords.length && registrationResolver !== zeroAddress) {
    calls.push(
      ...recordCalls(
        registrationResolver,
        node,
        registrationRecords,
        ctx,
        nodeSigner(),
        `${row.fixture_id} registration`,
      ),
    );
  }

  for (const [index, step] of (scenario.v1.setup_steps ?? []).entries()) {
    const tag = `${row.fixture_id}#${index} ${step.action}`;
    switch (step.action) {
      case "set_ttl": {
        const ttl = BigInt(step.ttl ?? 0);
        calls.push({
          signer: nodeSigner(),
          target: wrapped ? ctx.addresses.wrapper : ctx.addresses.registry,
          value: 0n,
          allowFailure: false,
          label: tag,
          data: encodeFunctionData({
            abi: wrapped ? WRAPPER_ABI : REGISTRY_ABI,
            functionName: "setTTL",
            args: [node, ttl],
          }),
        });
        break;
      }

      case "set_resolver": {
        const resolver = resolveRef(step.resolver_ref, ctx);
        calls.push({
          signer: nodeSigner(),
          target: wrapped ? ctx.addresses.wrapper : ctx.addresses.registry,
          value: 0n,
          allowFailure: false,
          label: tag,
          data: encodeFunctionData({
            abi: wrapped ? WRAPPER_ABI : REGISTRY_ABI,
            functionName: "setResolver",
            args: [node, resolver],
          }),
        });
        break;
      }

      case "write_records": {
        const resolver = resolveRef(step.resolver_ref, ctx);
        calls.push(
          ...recordCalls(resolver, node, step.records ?? [], ctx, nodeSigner(), tag),
        );
        break;
      }

      case "set_text": {
        calls.push({
          signer: nodeSigner(),
          target: ctx.addresses.publicResolver,
          value: 0n,
          allowFailure: false,
          label: tag,
          data: encodeFunctionData({
            abi: RESOLVER_ABI,
            functionName: "setText",
            args: [node, String(step.key ?? ""), String(step.value ?? "")],
          }),
        });
        break;
      }

      // Deletion is an explicit write of an empty value so the operation stays
      // in resolver history rather than merely being forgotten locally.
      case "clear_records": {
        const known = (scenario.v1.expected_pre_migration?.record_operation_history ??
          scenario.v1.registration.records ??
          []) as RecordSpec[];
        const cleared = known.map((r) =>
          r.kind === "addr"
            ? { ...r, value_actor: undefined, value: zeroAddress }
            : { ...r, value: "" },
        );
        calls.push(
          ...recordCalls(
            ctx.addresses.publicResolver,
            node,
            cleared,
            ctx,
            nodeSigner(),
            tag,
          ),
        );
        break;
      }

      // An ERC-721 transfer alone leaves the registry controller stale, so the
      // reclaim is part of the action rather than an optional follow-up.
      case "transfer_registrant": {
        const to = stripActorPrefix(step.to_actor);
        const toAddress = resolveRef(to, ctx);
        const fromAddress = heldByBatcher
          ? ctx.batcher
          : resolveRef(cursor.alias, ctx);
        calls.push({
          signer: heldByBatcher ? BATCHER : actorSigner(cursor.alias),
          target: ctx.addresses.baseRegistrar,
          value: 0n,
          allowFailure: false,
          label: `${tag} transfer`,
          data: encodeFunctionData({
            abi: ERC721_ABI,
            functionName: "safeTransferFrom",
            args: [fromAddress, toAddress, tokenId],
          }),
        });
        calls.push({
          signer: actorSigner(to),
          target: ctx.addresses.baseRegistrar,
          value: 0n,
          allowFailure: false,
          label: `${tag} reclaim`,
          data: encodeFunctionData({
            abi: ERC721_ABI,
            functionName: "reclaim",
            args: [tokenId, toAddress],
          }),
        });
        heldByBatcher = false;
        cursor.set(to);
        break;
      }

      case "renew_v1": {
        // Price is attached at execution time from the live controller quote.
        calls.push({
          signer: BATCHER,
          target: ctx.addresses.controller,
          value: 0n,
          allowFailure: false,
          label: `${tag}:renew:${label}:${step.duration_seconds}`,
          data: encodeFunctionData({
            abi: CONTROLLER_RENEW_ABI,
            functionName: "renew",
            args: [label, BigInt(step.duration_seconds ?? 0), `0x${"00".repeat(32)}` as Hex],
          }),
        });
        break;
      }

      case "wrap_2ld":
      case "ensure_wrapped_2ld": {
        const owner = stripActorPrefix(
          step.wrapped_owner_actor ?? cursor.alias,
        );
        const fuses = ownerControlledFuses(resolveFuses(step));
        const resolver = resolveOptionalRef(step.resolver_ref, ctx);
        // The batcher holds the ERC-721 and must approve the wrapper before it
        // can wrap. Owner, fuses and resolver are all set by this single call,
        // so the resolver is in place before CANNOT_SET_RESOLVER can bite.
        calls.push({
          signer: heldByBatcher ? BATCHER : actorSigner(cursor.alias),
          target: ctx.addresses.baseRegistrar,
          value: 0n,
          allowFailure: false,
          label: `${tag} approve wrapper`,
          data: encodeFunctionData({
            abi: ERC721_ABI,
            functionName: "setApprovalForAll",
            args: [ctx.addresses.wrapper, true],
          }),
        });
        calls.push({
          signer: heldByBatcher ? BATCHER : actorSigner(cursor.alias),
          target: ctx.addresses.wrapper,
          value: 0n,
          allowFailure: false,
          label: `${tag} wrapETH2LD`,
          data: encodeFunctionData({
            abi: WRAPPER_ABI,
            functionName: "wrapETH2LD",
            args: [label, resolveRef(owner, ctx), fuses, resolver],
          }),
        });
        heldByBatcher = false;
        cursor.set(owner);
        break;
      }

      case "unwrap_2ld": {
        const to = resolveRef(cursor.alias, ctx);
        calls.push({
          signer: actorSigner(cursor.alias),
          target: ctx.addresses.wrapper,
          value: 0n,
          allowFailure: false,
          label: tag,
          data: encodeFunctionData({
            abi: WRAPPER_ABI,
            functionName: "unwrapETH2LD",
            args: [labelhashOf(label), to, to],
          }),
        });
        break;
      }

      // Parent is wrapped to the batcher so it can mint the child with the
      // exact fuse/expiry shape, then both tokens are handed to the actor.
      case "ensure_wrapped_parent_and_child": {
        const owner = stripActorPrefix(step.wrapped_owner_actor ?? cursor.alias);
        const ownerAddress = resolveRef(owner, ctx);
        const childFuses = resolveFuses(step);
        const resolver = resolveOptionalRef(step.resolver_ref, ctx);
        const childLabel = scenario.child_label;
        if (!childLabel) {
          throw new Error(`${row.fixture_id}: child scenario without child_label`);
        }
        calls.push({
          signer: BATCHER,
          target: ctx.addresses.baseRegistrar,
          value: 0n,
          allowFailure: false,
          label: `${tag} approve wrapper`,
          data: encodeFunctionData({
            abi: ERC721_ABI,
            functionName: "setApprovalForAll",
            args: [ctx.addresses.wrapper, true],
          }),
        });
        calls.push({
          signer: BATCHER,
          target: ctx.addresses.wrapper,
          value: 0n,
          allowFailure: false,
          label: `${tag} wrap parent`,
          data: encodeFunctionData({
            abi: WRAPPER_ABI,
            functionName: "wrapETH2LD",
            args: [label, ctx.batcher, FUSES.CANNOT_UNWRAP, resolver],
          }),
        });
        // Child expiry is clamped to the parent's by NameWrapper; passing the
        // maximum lets it take the parent value rather than guessing one.
        calls.push({
          signer: BATCHER,
          target: ctx.addresses.wrapper,
          value: 0n,
          allowFailure: false,
          label: `${tag} setSubnodeRecord`,
          data: encodeFunctionData({
            abi: WRAPPER_ABI,
            functionName: "setSubnodeRecord",
            args: [
              topNode,
              childLabel,
              ownerAddress,
              resolver,
              0n,
              childFuses,
              BigInt("0xffffffffffffffff"),
            ],
          }),
        });
        heldByBatcher = false;
        cursor.set(owner);
        break;
      }

      // Approval must come from the holder, so this is always actor-signed.
      case "set_operator_approval": {
        const token = resolveRef(step.token_contract, ctx);
        const operator = resolveRef(step.operator_ref, ctx);
        calls.push({
          signer: actorSigner(cursor.alias),
          target: token,
          value: 0n,
          allowFailure: false,
          label: tag,
          data: encodeFunctionData({
            abi: ERC721_ABI,
            functionName: "setApprovalForAll",
            args: [operator, Boolean(step.approved ?? true)],
          }),
        });
        break;
      }

      // Installs the stale approval that the following fuse burn freezes; this
      // is the precondition for the locked migration FrozenTokenApproval guard.
      case "approve_wrapper_token_before_burning_cannot_approve": {
        const approved = resolveRef(stripActorPrefix(step.approved_actor), ctx);
        calls.push({
          signer: actorSigner(cursor.alias),
          target: ctx.addresses.wrapper,
          value: 0n,
          allowFailure: false,
          label: tag,
          data: encodeFunctionData({
            abi: WRAPPER_ABI,
            functionName: "approve",
            args: [approved, BigInt(node)],
          }),
        });
        break;
      }

      // The reverse node is derived from msg.sender, so only the claiming actor
      // can make this call; a batcher-signed equivalent would claim the wrong
      // reverse node entirely.
      case "set_reverse_claim": {
        const claimant = stripActorPrefix(step.address_actor);
        const namespace = String(step.namespace ?? "ethereum");
        const registrar =
          namespace === "default"
            ? ctx.addresses.defaultReverseRegistrar
            : ctx.addresses.reverseRegistrar;
        calls.push({
          signer: actorSigner(claimant),
          target: registrar,
          value: 0n,
          allowFailure: false,
          label: `${tag} (${namespace})`,
          data: encodeFunctionData({
            abi: REVERSE_REGISTRAR_ABI,
            functionName: "setName",
            args: [String(step.claimed_name ?? scenario.name)],
          }),
        });
        break;
      }

      default:
        throw new Error(
          `${row.fixture_id}: unsupported V1 setup action "${step.action}"`,
        );
    }
  }

  // Hand the name to its terminal pre-migration owner if setup never moved it.
  const terminalOwner = preMigrationOwnerAlias(scenario);
  if (heldByBatcher && !child) {
    const terminalAddress = resolveRef(terminalOwner, ctx);
    calls.push({
      signer: BATCHER,
      target: ctx.addresses.baseRegistrar,
      value: 0n,
      allowFailure: false,
      label: `${row.fixture_id} handover transfer`,
      data: encodeFunctionData({
        abi: ERC721_ABI,
        functionName: "safeTransferFrom",
        args: [ctx.batcher, terminalAddress, tokenId],
      }),
    });
    calls.push({
      signer: actorSigner(terminalOwner),
      target: ctx.addresses.baseRegistrar,
      value: 0n,
      allowFailure: false,
      label: `${row.fixture_id} handover reclaim`,
      data: encodeFunctionData({
        abi: ERC721_ABI,
        functionName: "reclaim",
        args: [tokenId, terminalAddress],
      }),
    });
  }

  return calls;
}
