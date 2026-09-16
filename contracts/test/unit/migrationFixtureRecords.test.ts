import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Command } from "commander";
import {
  createPublicClient,
  createWalletClient,
  decodeFunctionData,
  encodeErrorResult,
  getAddress,
  http,
  parseEther,
  parseTransaction,
  toHex,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";
import { mnemonicToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

import { Artifact_MigrationFixtureBatcher } from "generated/artifacts/MigrationFixtureBatcher.js";
import { Artifact_PublicResolver } from "generated/artifacts/PublicResolver.js";

import { isRetryableRpcRequest } from "../../script/migrate.js";
import { sameAddress } from "../../script/migrations/plumbing.js";
import {
  clearedRecord,
  isEVMCoinType,
  planSetupSteps,
  recordValue,
  type PlanContext,
  type PlannedCall,
  type Signer,
} from "../../script/migrations/fixture/plan.js";
import {
  accounts,
  ACTOR_ALIASES,
  fundingTargets,
  loadFixture,
} from "../../script/migrations/fixture/config.js";
import {
  executePlannedCalls,
  fundActors,
  type Executor,
} from "../../script/migrations/fixture/execute.js";
import {
  addFixtureSubcommands,
  assertSeedable,
  keptUnreservedFixtureNames,
  refContext,
  reportReverseClaimOverlap,
  splitFixtureReservations,
  v1Holder,
} from "../../script/migrations/fixture.js";
import { renderFixtureMarkdown } from "../../script/migrations/fixture/docs.js";
import type { RefContext } from "../../script/migrations/fixture/scenario.js";
import type {
  CommonOptions,
  FixtureEnvelope,
  FixtureRunState,
  RecordSpec,
} from "../../script/migrations/fixture/types.js";

// The fixture commands fall back to MIGRATION_FIXTURE_* environment variables,
// and `contracts/.env` carries them on any machine that has run a seeding. These
// tests describe what the commands do when nothing is nominated, so they run
// with those variables cleared rather than reporting the operator's .env.
const AMBIENT_FIXTURE_ENV = [
  "MIGRATION_FIXTURE_OWNER_KEY",
  "MIGRATION_FIXTURE_ACTOR_MNEMONIC",
  "MIGRATION_FIXTURE_PRIVATE_KEY",
] as const;
const ambient = new Map<string, string | undefined>();
beforeAll(() => {
  for (const name of AMBIENT_FIXTURE_ENV) {
    ambient.set(name, process.env[name]);
    delete process.env[name];
  }
});
afterAll(() => {
  for (const [name, value] of ambient) {
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  }
});

const OWNER = "0x00000000000000000000000000000000000000a1" as Address;

const ctx: RefContext = {
  actors: new Map([["owner_a", OWNER]]),
  fixtureContracts: {},
  addresses: {},
  v1Address: (name: string) => {
    throw new Error(`unexpected v1 lookup: ${name}`);
  },
  v2Address: (name: string) => {
    throw new Error(`unexpected v2 lookup: ${name}`);
  },
} as unknown as RefContext;

describe("record values", () => {
  it("encodes a multicoin address from its declared bytes", () => {
    const record: RecordSpec = {
      kind: "addr",
      coin_type: 0,
      value_hex: "0x00112233445566778899aabbccddeeff00112233",
    };
    expect(recordValue(record, ctx)).toBe(record.value_hex as string);
  });

  it("falls back to empty bytes when a multicoin slot declares nothing", () => {
    expect(recordValue({ kind: "addr", coin_type: 2147483785 }, ctx)).toBe(
      "0x",
    );
  });

  it("resolves an ether address through its actor", () => {
    expect(
      recordValue({ kind: "addr", value_actor: "actor.owner_a" }, ctx),
    ).toBe(OWNER);
  });

  it("prefers the hex bytes of a contenthash", () => {
    expect(
      recordValue(
        { kind: "contenthash", value_hex: "0xe301", value: "x" },
        ctx,
      ),
    ).toBe("0xe301");
  });
});

describe("cleared records", () => {
  it("drops the bytes of a contenthash rather than rewriting them", () => {
    const cleared = clearedRecord({ kind: "contenthash", value_hex: "0xe301" });
    expect(cleared.value_hex).toBe("0x");
    expect(recordValue(cleared, ctx)).toBe("0x");
  });

  it("empties a multicoin slot rather than zero-filling it", () => {
    const cleared = clearedRecord({
      kind: "addr",
      coin_type: 0,
      value_hex: "0xdead",
    });
    expect(recordValue(cleared, ctx)).toBe("0x");
  });

  it("zeroes an ether address and empties a text slot", () => {
    expect(
      recordValue(
        clearedRecord({ kind: "addr", value_actor: "actor.owner_a" }),
        ctx,
      ),
    ).toBe(zeroAddress);
    expect(
      recordValue(clearedRecord({ kind: "text", key: "url", value: "u" }), ctx),
    ).toBe("");
  });
});

const envelope = (scenario: Record<string, any>): FixtureEnvelope =>
  ({
    fixture_id: "FX-001",
    source_scenario_id: "FX",
    label: "fx",
    name: "fx.eth",
    scenario: {
      scenario_id: "FX-001",
      execution: { scenario: "live_now", clock: "none" },
      v1: {
        registration: { duration_seconds: 31536000 },
        setup_steps: [],
        expected_pre_migration: { expiry_cohort: "long" },
      },
      v2_premigration: { profile: "present" },
      ...scenario,
    },
  }) as unknown as FixtureEnvelope;

describe("fixture reservations", () => {
  const withProfile = (id: string, profile: string) => ({
    ...envelope({ v2_premigration: { profile } }),
    fixture_id: id,
  });

  it("reserves only present names and keeps every other seeded name out", () => {
    const rows = [
      withProfile("A", "present"),
      withProfile("B", "missing"),
      withProfile("C", "already_registered"),
      withProfile("D", "expired"),
      withProfile("E", "present"),
    ];

    // E was never seeded, so it belongs on neither list.
    const { reserved, unreserved } = splitFixtureReservations(
      rows,
      new Set(["A", "B", "C", "D"]),
    );

    expect(reserved.map((row) => row.fixture_id)).toEqual(["A"]);
    expect(unreserved.map((row) => row.fixture_id)).toEqual(["B", "C", "D"]);
  });

  // A work directory as seeding leaves it: run state naming the seeded ids and the
  // corpus they came from.
  function seededWorkDir(corpus: FixtureEnvelope[], seededIds: string[]) {
    const dir = mkdtempSync(join(tmpdir(), "fixture-kept-"));
    mkdirSync(join(dir, "corpus"));
    writeFileSync(
      join(dir, "corpus", "weighted-scenarios.jsonl"),
      corpus.map((row) => JSON.stringify(row)).join("\n"),
    );
    writeFileSync(
      join(dir, "fixture-run.json"),
      JSON.stringify({
        version: 2,
        fixtureRoot: join(dir, "corpus"),
        names: seededIds.map((fixtureId) => ({ fixtureId })),
      }),
    );
    return dir;
  }

  it("reads the names kept unreserved from a seeded work directory", () => {
    const corpus = [
      { ...withProfile("A", "present"), label: "a" },
      { ...withProfile("B", "missing"), label: "b" },
      { ...withProfile("C", "missing"), label: "c" },
    ];

    // C sits in the corpus but was never seeded, so it is no concern of this run.
    expect(
      keptUnreservedFixtureNames(seededWorkDir(corpus, ["A", "B"])),
    ).toEqual([{ label: "b", state: "missing" }]);
  });

  it("refuses a work directory whose corpus no longer holds what it seeded", () => {
    const dir = seededWorkDir([withProfile("A", "present")], ["A", "GONE"]);

    expect(() => keptUnreservedFixtureNames(dir)).toThrow(/holds 1 of the 2/);
  });

  it("refuses a directory no seeding ran in", () => {
    expect(() =>
      keptUnreservedFixtureNames(mkdtempSync(join(tmpdir(), "fixture-empty-"))),
    ).toThrow(/no fixture run state/);
  });
});

describe("fixture corpus document", () => {
  const named = (
    id: string,
    scenario: Record<string, any>,
    run: Record<string, any> = {},
  ) => ({
    row: {
      ...envelope(scenario),
      fixture_id: id,
      label: id.toLowerCase(),
      name: `${id.toLowerCase()}.eth`,
      popularity_tier: "common",
    } as FixtureEnvelope,
    name: {
      fixtureId: id,
      sourceScenarioId: id,
      label: id.toLowerCase(),
      name: `${id.toLowerCase()}.eth`,
      ownerAlias: "owner_a",
      owner: zeroAddress,
      form: "unwrapped",
      wrapped: false,
      locked: false,
      fuses: 0,
      route: "unlocked_controller",
      batchId: null,
      expectedResult: "success",
      seedTransactions: [],
      setupComplete: true,
      ...run,
    },
  });

  const state = (names: any[]) =>
    ({
      version: 2,
      chainId: 11155111,
      fixtureRoot: "/corpus",
      fixtureDigest: "0xdigest",
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
      batcher: zeroAddress,
      fixtureContracts: {},
      actorAddresses: { owner_a: zeroAddress },
      names,
    }) as unknown as FixtureRunState;

  const render = (entries: ReturnType<typeof named>[], reserved: string[]) =>
    renderFixtureMarkdown(
      state(entries.map((entry) => entry.name)),
      entries.map((entry) => entry.row),
      { namespace: "sepolia", reserved: new Set(reserved) },
    );

  it("gives every seeded name a row naming the scenario it stands for", () => {
    const doc = render(
      [
        named("A", {
          title: "Direct unwrapped migration",
          layer: "legacy_anchor",
        }),
        named("B", { title: "Wrapped locked migration", layer: "hierarchy" }),
      ],
      ["A", "B"],
    );

    expect(doc).toContain("| a.eth | A | Direct unwrapped migration |");
    expect(doc).toContain("| b.eth | B | Wrapped locked migration |");
    // Sectioned by the layer each scenario declares.
    expect(doc).toContain("## legacy_anchor (1)");
    expect(doc).toContain("## hierarchy (1)");
    expect(doc).toContain("- **Names:** 2 across 2 layer(s)");
  });

  it("says which names pre-migration left unreserved, and why", () => {
    const doc = render(
      [
        named("A", { title: "Reserved", layer: "legacy_anchor" }),
        named("B", {
          title: "Absent on v2",
          layer: "legacy_anchor",
          v2_premigration: { profile: "missing" },
        }),
      ],
      ["A"],
    );

    expect(doc).toContain("- **Reserved on v2:** 1");
    expect(doc).toContain("- **Kept unreserved:** 1");
    expect(doc).toContain("kept unreserved (missing)");
  });

  it("reports a name a contract refused to shape", () => {
    const doc = render(
      [
        named(
          "A",
          { title: "Refused", layer: "legacy_anchor" },
          { setupFailure: "set_ttl: CannotSetTTL" },
        ),
      ],
      ["A"],
    );

    expect(doc).toContain("- **Set aside part-shaped:** 1");
    expect(doc).toContain("## Set aside");
    expect(doc).toContain("| a.eth | set_ttl: CannotSetTTL |");
  });

  it("collapses owner aliases a nominated wallet made one account", () => {
    const shared = "0x00000000000000000000000000000000000000aa" as Address;
    const entries = [
      named("A", { title: "One", layer: "legacy_anchor" }, { owner: shared }),
      named(
        "B",
        { title: "Two", layer: "legacy_anchor" },
        { ownerAlias: "owner_b", owner: shared },
      ),
    ];
    const runState = state(entries.map((entry) => entry.name));
    runState.actorAddresses = {
      owner_a: shared,
      owner_b: shared,
      owner_c: shared,
      operator: OWNER,
    };

    const doc = renderFixtureMarkdown(
      runState,
      entries.map((entry) => entry.row),
      { namespace: "sepolia", reserved: new Set(["A", "B"]) },
    );

    // One account, so the aliases share a row in the owners table and every
    // name's row names that owner once.
    expect(doc).toContain(`| owner_a, owner_b, owner_c | [${shared}]`);
    expect(doc).toContain("| Tier | Owner |");
    expect(doc).toContain("| common | owner_a |");
    expect(doc).not.toContain("| common | owner_b |");
  });

  it("keeps the owner column when the names have different owners", () => {
    const entries = [
      named("A", { title: "One", layer: "legacy_anchor" }, { owner: OWNER }),
      named(
        "B",
        { title: "Two", layer: "legacy_anchor" },
        {
          ownerAlias: "owner_b",
          owner: "0x00000000000000000000000000000000000000bb" as Address,
        },
      ),
    ];
    const runState = state(entries.map((entry) => entry.name));
    runState.actorAddresses = {
      owner_a: OWNER,
      owner_b: "0x00000000000000000000000000000000000000bb" as Address,
    };

    const doc = renderFixtureMarkdown(
      runState,
      entries.map((entry) => entry.row),
      { namespace: "sepolia", reserved: new Set(["A", "B"]) },
    );

    expect(doc).toContain("| Tier | Owner |");
    expect(doc).toContain("| common | owner_a |");
    expect(doc).toContain("| common | owner_b |");
  });

  it("names the error a reverting scenario expects, and the fuses a name burns", () => {
    const doc = render(
      [
        named(
          "A",
          {
            title: "Locked name refuses",
            layer: "legacy_anchor",
            execution: {
              scenario: "live_now",
              expected_error: "ReservedRegistrationRequired",
            },
          },
          { expectedResult: "revert", wrapped: true, locked: true, fuses: 1 },
        ),
      ],
      ["A"],
    );

    expect(doc).toContain("revert: ReservedRegistrationRequired");
    expect(doc).toContain("1 [CANNOT_UNWRAP]");
  });
});

describe("seedable selections", () => {
  it("accepts a scenario seeding can establish", () => {
    expect(() => assertSeedable([envelope({})])).not.toThrow();
  });

  it("refuses an expiry that needs a controlled clock", () => {
    expect(() =>
      assertSeedable([
        envelope({
          execution: { scenario: "fork_only", clock: "time_control" },
        }),
      ]),
    ).toThrow(/controlled clock/);
  });

  it("refuses an expiry cohort seeding cannot reach", () => {
    expect(() =>
      assertSeedable([
        envelope({
          v1: {
            registration: { duration_seconds: 31536000 },
            setup_steps: [],
            expected_pre_migration: { expiry_cohort: "near_expiry" },
          },
        }),
      ]),
    ).toThrow(/near_expiry/);
  });

  it("refuses a v2 state seeding does not create", () => {
    expect(() =>
      assertSeedable([
        envelope({ v2_premigration: { profile: "already_registered" } }),
      ]),
    ).toThrow(/already_registered/);
  });

  it("refuses a lease below the registration minimum", () => {
    expect(() =>
      assertSeedable([
        envelope({
          v1: {
            registration: { duration_seconds: 60 },
            setup_steps: [],
            expected_pre_migration: { expiry_cohort: "long" },
          },
        }),
      ]),
    ).toThrow(/below the v1 controller minimum/);
  });

  const POLYGON = 2147483785;
  const withRecords = (
    records: RecordSpec[],
    where: "records" | "target_current_records" | "setup_steps" = "records",
  ) =>
    envelope({
      v1: {
        registration: {
          duration_seconds: 31536000,
          ...(where === "setup_steps" ? {} : { [where]: records }),
        },
        setup_steps:
          where === "setup_steps" ? [{ action: "write_records", records }] : [],
        expected_pre_migration: { expiry_cohort: "long" },
      },
    });

  it("refuses an EVM coin type holding a value that is not an address", () => {
    for (const where of [
      "records",
      "target_current_records",
      "setup_steps",
    ] as const) {
      expect(() =>
        assertSeedable([
          withRecords(
            [
              {
                kind: "addr",
                coin_type: POLYGON,
                value_hex: "0x0102030405060708",
              },
            ],
            where,
          ),
        ]),
      ).toThrow(/EVM coin type 2147483785 holds 8 bytes/);
    }
  });

  it("counts a refused record once however often the scenario restates it", () => {
    const record: RecordSpec = {
      kind: "addr",
      coin_type: POLYGON,
      value_hex: "0x0102030405060708",
    };
    const row = envelope({
      v1: {
        registration: {
          duration_seconds: 31536000,
          records: [record],
          target_current_records: [record],
        },
        setup_steps: [{ action: "write_records", records: [record] }],
        expected_pre_migration: { expiry_cohort: "long" },
      },
    });

    expect(() => assertSeedable([row])).toThrow(/ 1x addr record/);
  });

  it("accepts an address, or nothing, on an EVM coin type", () => {
    expect(() =>
      assertSeedable([
        withRecords([
          {
            kind: "addr",
            coin_type: POLYGON,
            value_hex: "0x0102030405060708090a0b0c0d0e0f1011121314",
          },
          { kind: "addr", coin_type: 0x80000000, value_hex: "0x" },
        ]),
      ]),
    ).not.toThrow();
  });

  it("leaves a non-EVM coin type to hold whatever encoding its chain uses", () => {
    expect(() =>
      assertSeedable([
        withRecords([
          { kind: "addr", coin_type: 0, value_hex: "0x0102030405060708" },
        ]),
      ]),
    ).not.toThrow();
  });
});

describe("EVM coin types", () => {
  it("covers Ethereum, the default and every chain-specific coin type", () => {
    expect(isEVMCoinType(60)).toBe(true);
    expect(isEVMCoinType(0x80000000)).toBe(true);
    expect(isEVMCoinType(0x80000089)).toBe(true);
    expect(isEVMCoinType(0xffffffff)).toBe(true);
  });

  it("excludes coin types of other chains and values past 32 bits", () => {
    expect(isEVMCoinType(0)).toBe(false);
    expect(isEVMCoinType(501)).toBe(false);
    expect(isEVMCoinType(0x7fffffff)).toBe(false);
    expect(isEVMCoinType(0x100000000)).toBe(false);
  });
});

describe("the bundled corpus", () => {
  it("offers only live_now scenarios seeding can establish", () => {
    const fixtureRoot = join(
      import.meta.dir,
      "../../csv-data/migration-fixture",
    );
    let rows: FixtureEnvelope[];
    try {
      rows = loadFixture({
        fixtureRoot,
        fixtureScenarios: "live_now",
      } as CommonOptions);
    } catch (error) {
      throw new Error(
        "the bundled corpus is not extracted; run `bun run fixtures:extract`",
        { cause: error },
      );
    }

    expect(rows.length).toBeGreaterThan(0);
    expect(() => assertSeedable(rows)).not.toThrow();
  });
});

describe("retryable rpc requests", () => {
  it("retries reads", () => {
    for (const method of [
      "eth_call",
      "eth_chainId",
      "eth_getBalance",
      "eth_getTransactionReceipt",
      "eth_feeHistory",
    ]) {
      expect(isRetryableRpcRequest({ method })).toBe(true);
    }
  });

  it("refuses transaction submission", () => {
    for (const method of [
      "eth_sendTransaction",
      "eth_sendRawTransaction",
      "wallet_sendTransaction",
    ]) {
      expect(isRetryableRpcRequest({ method })).toBe(false);
    }
  });

  it("refuses state controls, whose effects accumulate", () => {
    for (const method of [
      "evm_increaseTime",
      "evm_mine",
      "anvil_setBalance",
      "tenderly_setBalance",
    ]) {
      expect(isRetryableRpcRequest({ method })).toBe(false);
    }
  });

  it("refuses batches and unparseable bodies, whose contents are unknown", () => {
    expect(isRetryableRpcRequest([{ method: "eth_call" }])).toBe(false);
    expect(isRetryableRpcRequest(null)).toBe(false);
    expect(isRetryableRpcRequest({})).toBe(false);
  });
});

const OWNER_KEY =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as const;
const KEY_ADDRESS = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as Address;
const MNEMONIC = "test test test test test test test test test test test junk";

describe("the wallet that owns the seeded names", () => {
  it("derives every actor from the mnemonic when no owner is nominated", () => {
    const derived = accounts({ fixtureActorMnemonic: MNEMONIC } as never);
    expect(derived.map((a) => a.alias)).toEqual([
      "owner_a",
      "owner_b",
      "owner_c",
      "operator",
      "attacker",
    ]);
    // Five accounts, five addresses.
    expect(new Set(derived.map((a) => a.account.address)).size).toBe(5);
  });

  it("puts the three owner aliases on the nominated key", () => {
    const derived = accounts({
      fixtureActorMnemonic: MNEMONIC,
      fixtureOwnerKey: OWNER_KEY,
    } as never);
    const address = (alias: string) =>
      derived.find((a) => a.alias === alias)!.account.address;

    for (const alias of ["owner_a", "owner_b", "owner_c"]) {
      expect(address(alias)).toBe(KEY_ADDRESS);
    }
    // The counterparties stay separate: an operator or an attacker means
    // nothing if it is the owner.
    expect(address("operator")).not.toBe(KEY_ADDRESS);
    expect(address("attacker")).not.toBe(KEY_ADDRESS);
    expect(address("operator")).not.toBe(address("attacker"));
  });

  it("still needs the mnemonic, which the counterparties come from", () => {
    expect(() => accounts({ fixtureOwnerKey: OWNER_KEY } as never)).toThrow(
      /fixture-actor-mnemonic/,
    );
  });

  it("refuses a key that is not one", () => {
    expect(() =>
      accounts({
        fixtureActorMnemonic: MNEMONIC,
        fixtureOwnerKey: "0xnope",
      } as never),
    ).toThrow(/fixture-owner-key/);
  });

  // The corpus migrates as these two to prove they are turned away. Owning the
  // names as one makes those calls authorised, and verification reads the same
  // accounts, so nothing downstream would notice.
  for (const alias of ["operator", "attacker"]) {
    it(`refuses a key that is the ${alias}`, () => {
      const index = ACTOR_ALIASES.indexOf(alias as never);
      const key = toHex(
        mnemonicToAccount(MNEMONIC, {
          accountIndex: index,
        }).getHdKey().privateKey!,
      );
      expect(() =>
        accounts({
          fixtureActorMnemonic: MNEMONIC,
          fixtureOwnerKey: key,
        } as never),
      ).toThrow(new RegExp(`"${alias}"`));
    });
  }
});

describe("the accounts a funding run tops up", () => {
  const FLOOR = "0.5";
  const floor = parseEther(FLOOR);

  it("charges one floor per account when every alias has its own", () => {
    const targets = fundingTargets(
      accounts({ fixtureActorMnemonic: MNEMONIC } as never),
      FLOOR,
    );
    expect(targets).toHaveLength(5);
    for (const target of targets) {
      expect(target.aliases).toHaveLength(1);
      expect(target.required).toBe(floor);
    }
  });

  it("charges the shared owner account every alias it carries", () => {
    const targets = fundingTargets(
      accounts({
        fixtureActorMnemonic: MNEMONIC,
        fixtureOwnerKey: OWNER_KEY,
      } as never),
      FLOOR,
    );
    // Five aliases, three accounts: the nominated wallet and two counterparties.
    expect(targets).toHaveLength(3);

    const owner = targets.find((t) => t.address === KEY_ADDRESS)!;
    // Actor order, so the receipt label a run prints is stable.
    expect(owner.aliases).toEqual(["owner_a", "owner_b", "owner_c"]);
    expect(owner.required).toBe(floor * 3n);

    for (const target of targets.filter((t) => t !== owner)) {
      expect(target.aliases).toHaveLength(1);
      expect(target.required).toBe(floor);
    }
  });

  it("covers every actor exactly once", () => {
    const derived = accounts({
      fixtureActorMnemonic: MNEMONIC,
      fixtureOwnerKey: OWNER_KEY,
    } as never);
    expect(fundingTargets(derived, FLOOR).flatMap((t) => t.aliases)).toEqual(
      derived.map((a) => a.alias),
    );
  });
});

describe("a funding run", () => {
  const FLOOR = "0.5";
  const floor = parseEther(FLOOR);
  const STRANGER = "0x00000000000000000000000000000000000000f1" as Address;
  /// The owner key of a run whose tester wallet also pays for the run.
  const SHARED_KEY = toHex(mnemonicToAccount(MNEMONIC).getHdKey().privateKey!);
  const SHARED = mnemonicToAccount(MNEMONIC).address;

  /// A run against recorded balances. Nothing is signed, so the executor only
  /// has to answer balances and collect what it was asked to send.
  const run = (opts: {
    funder: Address;
    balances?: Record<Address, bigint>;
    ownerKey?: string;
  }) => {
    const held = new Map(
      Object.entries(opts.balances ?? {}).map(([a, v]) => [a.toLowerCase(), v]),
    );
    const sent: { to: Address; value: bigint }[] = [];
    const actors = accounts({
      fixtureActorMnemonic: MNEMONIC,
      fixtureOwnerKey: opts.ownerKey,
    } as never);
    const ex = {
      opts: {},
      client: {
        getBalance: async ({ address }: { address: Address }) =>
          held.get(address.toLowerCase()) ?? 0n,
        waitForTransactionReceipt: async () => ({ status: "success" }),
      },
      wallet: {
        account: { address: opts.funder },
        sendTransaction: async (tx: { to: Address; value: bigint }) => {
          sent.push(tx);
          return "0x" as const;
        },
      },
      actors: new Map(actors.map((a) => [a.alias, a])),
    } as never;
    return { ex, sent, targets: fundingTargets(actors, FLOOR) };
  };

  it("tops each account up to what its aliases need", async () => {
    const { ex, sent, targets } = run({ funder: STRANGER });
    await fundActors(ex, FLOOR);
    expect(sent).toEqual(
      targets.map((t) => ({ to: t.address, value: t.required })),
    );
  });

  it("leaves an account already holding enough alone", async () => {
    const { targets } = run({ funder: STRANGER });
    const { ex, sent } = run({
      funder: STRANGER,
      balances: Object.fromEntries(
        targets.map((t) => [t.address, t.required]),
      ) as Record<Address, bigint>,
    });
    await fundActors(ex, FLOOR);
    expect(sent).toEqual([]);
  });

  // An account cannot be paid from itself: a transfer out and back leaves it
  // poorer by the gas. The shortfall is reported rather than sent.
  it("refuses to send the funding account its own money", async () => {
    const { ex, sent } = run({
      funder: SHARED,
      balances: { [SHARED]: floor },
      ownerKey: SHARED_KEY,
    });
    await expect(fundActors(ex, FLOOR)).rejects.toThrow(
      /is the funding account/,
    );
    expect(sent).toEqual([]);
  });

  it("funds the rest when the funding account already holds its share", async () => {
    const { ex, sent, targets } = run({
      funder: SHARED,
      balances: { [SHARED]: floor * 3n },
      ownerKey: SHARED_KEY,
    });
    await fundActors(ex, FLOOR);
    expect(sent.map((s) => s.to)).toEqual(
      targets.filter((t) => t.address !== SHARED).map((t) => t.address),
    );
  });
});

describe("the reverse claims a selection loses", () => {
  const claim = (alias: string) =>
    envelope({
      v1: {
        registration: { duration_seconds: 31536000 },
        setup_steps: [
          { action: "set_reverse_claim", address_actor: `actor.${alias}` },
        ],
        expected_pre_migration: { expiry_cohort: "long" },
      },
    });

  const warningFor = (
    rows: FixtureEnvelope[],
    opts: Record<string, unknown>,
  ) => {
    const original = console.warn;
    let warned: string | undefined;
    console.warn = (message: string) => {
      warned = message;
    };
    try {
      reportReverseClaimOverlap(rows, accounts(opts as never));
    } finally {
      console.warn = original;
    }
    return warned;
  };

  it("says nothing when each alias claims once and is its own account", () => {
    expect(
      warningFor([claim("owner_a"), claim("owner_b"), claim("owner_c")], {
        fixtureActorMnemonic: MNEMONIC,
      }),
    ).toBeUndefined();
  });

  it("counts claims from aliases the owner key collapsed as one account", () => {
    // Three aliases, one wallet: every claim writes the same reverse node, so
    // one account loses two claims rather than three accounts losing none.
    const warned = warningFor(
      [claim("owner_a"), claim("owner_b"), claim("owner_c")],
      { fixtureActorMnemonic: MNEMONIC, fixtureOwnerKey: OWNER_KEY },
    );
    expect(warned).toContain("3 reverse claims share 1 ");
    expect(warned).toContain("owner_a+owner_b+owner_c (3)");
  });

  it("still reports an alias colliding with itself", () => {
    const warned = warningFor([claim("owner_a"), claim("owner_a")], {
      fixtureActorMnemonic: MNEMONIC,
    });
    expect(warned).toContain("owner_a (2)");
  });
});

describe("the actors a run is checked against", () => {
  it("resolves aliases from the addresses the run recorded", () => {
    const recorded = { owner_a: KEY_ADDRESS, operator: OWNER };
    // No mnemonic and no owner key: reading the state back must not depend on
    // either, since nothing after seeding nominates one.
    const ctx = refContext({} as never, {}, recorded);
    expect(ctx.actors.get("owner_a")).toBe(KEY_ADDRESS);
    expect(ctx.actors.get("operator")).toBe(OWNER);
  });

  it("derives them when nothing was recorded", () => {
    const ctx = refContext({ fixtureActorMnemonic: MNEMONIC } as never, {});
    const derived = accounts({ fixtureActorMnemonic: MNEMONIC } as never);
    for (const actor of derived) {
      expect(ctx.actors.get(actor.alias)).toBe(actor.account.address);
    }
  });
});

const PLAN_BATCHER = "0x00000000000000000000000000000000000000b3" as Address;
const PLAN_WRAPPER = "0x00000000000000000000000000000000000000b2" as Address;
const PARENT_OWNER = "0x00000000000000000000000000000000000000a2" as Address;

const planCtx = {
  actors: new Map([
    ["owner_a", OWNER],
    ["owner_b", PARENT_OWNER],
  ]),
  fixtureContracts: {},
  v1Address: (name: string) => {
    if (name === "PublicResolver")
      return "0x00000000000000000000000000000000000000b6";
    throw new Error(`unexpected v1 lookup: ${name}`);
  },
  v2Address: (name: string) => {
    throw new Error(`unexpected v2 lookup: ${name}`);
  },
  batcher: PLAN_BATCHER,
  addresses: {
    baseRegistrar: "0x00000000000000000000000000000000000000b1",
    registry: "0x00000000000000000000000000000000000000b4",
    wrapper: PLAN_WRAPPER,
    controller: "0x00000000000000000000000000000000000000b5",
    publicResolver: "0x00000000000000000000000000000000000000b6",
    reverseRegistrar: "0x00000000000000000000000000000000000000b7",
    defaultReverseRegistrar: "0x00000000000000000000000000000000000000b8",
  },
} as unknown as PlanContext;

const childRow = (parentOwner?: string): FixtureEnvelope =>
  ({
    fixture_id: "FX-C01",
    source_scenario_id: "FX-C",
    label: "fxc",
    name: "sub.fxc.eth",
    scenario: {
      scenario_id: "FX-C01",
      name: "sub.fxc.eth",
      top_level_label: "fxc",
      child_label: "sub",
      tags: ["locked_child"],
      execution: { scenario: "live_now", expected_result: "success" },
      actors: { pre_migration_owner: "owner_a" },
      v1: {
        registration: { label: "fxc", owner_actor: "owner_a" },
        parent_fixture: parentOwner ? { owner_actor: parentOwner } : null,
        setup_steps: [
          {
            action: "ensure_wrapped_parent_and_child",
            wrapped_owner_actor: "owner_a",
          },
        ],
        expected_pre_migration: {},
      },
    },
  }) as unknown as FixtureEnvelope;

describe("a subname's parent", () => {
  const parentTransfer = (row: FixtureEnvelope) =>
    planSetupSteps(row, planCtx).filter((c) =>
      c.label.includes("parent owner transfer"),
    );

  it("goes to the owner the corpus declares for it", () => {
    // Creating the child needs the batcher to hold the parent, so seeding wraps
    // it there. Left there, the holder of the subname could never migrate it.
    const calls = parentTransfer(childRow("owner_b"));
    expect(calls).toHaveLength(1);
    expect(calls[0].signer).toEqual({ kind: "batcher" });
    expect(calls[0].target).toBe(PLAN_WRAPPER);
  });

  it("falls back to the child's owner when none is declared", () => {
    expect(parentTransfer(childRow())).toHaveLength(1);
  });

  it("is not emitted for a name that has no parent", () => {
    const flat = {
      ...childRow(),
      name: "fxc.eth",
      scenario: {
        ...childRow().scenario,
        name: "fxc.eth",
        child_label: null,
        tags: ["unwrapped"],
        v1: { ...childRow().scenario.v1, setup_steps: [] },
      },
    } as unknown as FixtureEnvelope;
    expect(parentTransfer(flat)).toEqual([]);
  });
});

describe("the fixture command line", () => {
  /// Parses one command line the way the CLI does, and hands back the options
  /// the command would have run with.
  ///
  /// The parse is the real one — an unregistered option throws here exactly as
  /// it does for an operator — with only the action replaced, so a dry run does
  /// not go looking for a corpus or an RPC. `exitOverride` turns a parse error
  /// into a thrown error rather than an exit that would take the runner with it.
  const run = async (argv: string[]): Promise<Record<string, unknown>> => {
    const program = addFixtureSubcommands(new Command("migration-fixture"));
    const silent = { writeErr: () => {}, writeOut: () => {} };
    let parsed: Record<string, unknown> | undefined;
    program.exitOverride().configureOutput(silent);
    for (const command of program.commands) {
      command
        .exitOverride()
        .configureOutput(silent)
        .action((raw: Record<string, unknown>) => {
          parsed = raw;
        });
    }
    await program.parseAsync(argv, { from: "user" });
    if (!parsed) throw new Error("no fixture command ran");
    return parsed;
  };

  const argvFor = (command: string, ...rest: string[]) => [
    command,
    "--network",
    "sepolia",
    "--rpc-url",
    "http://127.0.0.1:8545",
    "--fixture-root",
    "csv-data/migration-fixture",
    "--work-dir",
    ".dev/fixture",
    "--fixture-actor-mnemonic",
    MNEMONIC,
    ...rest,
  ];

  const optionsOf = (command: string) => {
    const program = addFixtureSubcommands(new Command("migration-fixture"));
    const found = program.commands.find((c) => c.name() === command);
    if (!found) throw new Error(`no such fixture command: ${command}`);
    return found.options.map((o) => o.long);
  };

  it("carries the owner key from the dry run's argv through to the actors", async () => {
    // The whole point of the dry run: the cohort it plans is the cohort seeding
    // will register, down to which account each owner alias is.
    const parsed = await run(
      argvFor("verify", "--fixture-owner-key", OWNER_KEY),
    );
    expect(parsed.fixtureOwnerKey).toBe(OWNER_KEY);

    const derived = accounts(parsed as never);
    const address = (alias: string) =>
      derived.find((a) => a.alias === alias)!.account.address;
    for (const alias of ["owner_a", "owner_b", "owner_c"]) {
      expect(address(alias)).toBe(KEY_ADDRESS);
    }
  });

  it("plans the default three-owner layout when no wallet is nominated", async () => {
    const parsed = await run(argvFor("verify"));
    expect(parsed.fixtureOwnerKey).toBeUndefined();
    // Five aliases, five accounts: the layout the dry run has always planned.
    const derived = accounts(parsed as never);
    expect(new Set(derived.map((a) => a.account.address)).size).toBe(5);
  });

  it("lets the dry run take every option the run it previews takes", () => {
    // A plan is worth previewing only if it is the plan that will run. An
    // option seeding accepts and the dry run rejects makes the two diverge with
    // nothing to show for it, which is how --fixture-owner-key came to be
    // previewable through its environment variable alone.
    for (const long of optionsOf("seed-v1")) {
      expect(optionsOf("verify")).toContain(long);
    }
  });

  it("takes the owner key everywhere the owner aliases are resolved", async () => {
    for (const command of ["verify", "fund-actors", "seed-v1"]) {
      const parsed = await run(
        argvFor(command, "--fixture-owner-key", OWNER_KEY),
      );
      expect(parsed.fixtureOwnerKey).toBe(OWNER_KEY);
    }
  });

  it("refuses the owner key once the names exist, whose owner it cannot change", async () => {
    // verify-v1 resolves each alias against the addresses the seeding run
    // recorded, so a key here could only contradict them. Its refusal is also
    // what proves this harness sees an unregistered option at all.
    await expect(
      run(argvFor("verify-v1", "--fixture-owner-key", OWNER_KEY)),
    ).rejects.toThrow(/unknown option/);
  });
});

describe("a shaping run", () => {
  const BATCHER = "0x00000000000000000000000000000000000000b0" as Address;
  const ACCEPTS = "0x00000000000000000000000000000000000000c1" as Address;
  /// Every call to this target is refused, as the v1 resolver refuses a
  /// multicoin value an EVM coin type cannot hold.
  const REFUSES = "0x00000000000000000000000000000000000000c2" as Address;
  /// Every call to this target fails to reach the chain at all.
  const UNREACHABLE = "0x00000000000000000000000000000000000000c3" as Address;
  const REFUSAL = encodeErrorResult({
    abi: Artifact_PublicResolver.abi,
    errorName: "InvalidEVMAddress",
    args: ["0x0102030405060708"],
  });
  const HASH = `0x${"11".repeat(32)}` as Hex;

  /// A node that answers what signing and estimating ask of it, applies the
  /// batcher's refusal rule to each batch, and records what was sent.
  const node = () => {
    const sent: { to: Address; data: Hex }[] = [];
    const reverted = (data: Hex) => ({
      error: { code: 3, message: "execution reverted", data },
    });
    const server = Bun.serve({
      port: 0,
      async fetch(request) {
        const { id, method, params } = (await request.json()) as {
          id: number;
          method: string;
          params: any[];
        };
        const answer = (body: object) =>
          Response.json({ jsonrpc: "2.0", id, ...body });
        switch (method) {
          case "eth_chainId":
            return answer({ result: toHex(sepolia.id) });
          case "eth_getTransactionCount":
          case "eth_maxPriorityFeePerGas":
          case "eth_gasPrice":
            return answer({ result: "0x1" });
          case "eth_getBlockByNumber":
            return answer({
              result: {
                number: "0x1",
                hash: HASH,
                baseFeePerGas: "0x1",
                gasLimit: "0x1c9c380",
                gasUsed: "0x0",
                timestamp: "0x1",
                transactions: [],
              },
            });
          case "eth_sendRawTransaction": {
            const tx = parseTransaction(params[0]);
            sent.push({ to: tx.to!, data: tx.data! });
            return answer({ result: HASH });
          }
          case "eth_estimateGas": {
            const { to, data } = params[0] as { to: Address; data: Hex };
            if (sameAddress(to, REFUSES)) return answer(reverted(REFUSAL));
            if (!sameAddress(to, BATCHER)) return answer({ result: "0x5208" });
            const { args } = decodeFunctionData({
              abi: Artifact_MigrationFixtureBatcher.abi,
              data,
            });
            const calls = args[0] as readonly { target: Address }[];
            if (calls.some((c) => sameAddress(c.target, UNREACHABLE)))
              return new Response("unavailable", { status: 503 });
            const index = calls.findIndex((c) =>
              sameAddress(c.target, REFUSES),
            );
            if (index < 0) return answer({ result: "0x5208" });
            return answer(
              reverted(
                encodeErrorResult({
                  abi: Artifact_MigrationFixtureBatcher.abi,
                  errorName: "CallFailed",
                  args: [BigInt(index), REFUSES, REFUSAL],
                }),
              ),
            );
          }
          default:
            return answer({ error: { code: -32601, message: method } });
        }
      },
    });
    return { url: server.url.href, sent, stop: () => server.stop(true) };
  };

  const call = (
    signer: Signer,
    target: Address,
    label: string,
  ): PlannedCall => ({
    signer,
    target,
    value: 0n,
    data: "0x12345678",
    allowFailure: false,
    label,
  });
  const viaBatcher = (target: Address, label: string) =>
    call({ kind: "batcher" }, target, label);
  const asOwner = (target: Address, label: string) =>
    call({ kind: "actor", alias: "owner_a" }, target, label);

  /// Shapes the planned names against a fresh node and reports what happened.
  const shape = async (perName: Record<string, PlannedCall[]>) => {
    const { url, sent, stop } = node();
    const transport = http(url, { retryCount: 0 });
    const reader = createPublicClient({ chain: sepolia, transport });
    const completed: string[] = [];
    const ex = {
      opts: { rpcUrl: url },
      chain: sepolia,
      client: {
        estimateContractGas: reader.estimateContractGas,
        waitForTransactionReceipt: async () => ({ status: "success" }),
      },
      wallet: createWalletClient({
        chain: sepolia,
        account: mnemonicToAccount(MNEMONIC, { accountIndex: 9 }),
        transport,
      }),
      batcher: BATCHER,
      actors: new Map([
        ["owner_a", { alias: "owner_a", account: mnemonicToAccount(MNEMONIC) }],
      ]),
    } as unknown as Executor;
    const outcome = executePlannedCalls(ex, new Map(Object.entries(perName)), {
      onNameComplete: (id) => {
        completed.push(id);
      },
    }).finally(stop);
    return { outcome, completed, sent };
  };

  /// The targets of the calls a sent batch carried.
  const batchTargets = (data: Hex) =>
    (
      decodeFunctionData({ abi: Artifact_MigrationFixtureBatcher.abi, data })
        .args[0] as readonly { target: Address }[]
    ).map((c) => c.target.toLowerCase());

  it("sets aside the name a batch was refused on and finishes the rest", async () => {
    const { outcome, completed, sent } = await shape({
      A: [viaBatcher(ACCEPTS, "a1"), viaBatcher(ACCEPTS, "a2")],
      B: [viaBatcher(ACCEPTS, "b1"), viaBatcher(REFUSES, "b2")],
      C: [viaBatcher(ACCEPTS, "c1")],
    });

    expect(await outcome).toEqual([
      {
        fixtureId: "B",
        call: "b2",
        reason: "InvalidEVMAddress(0x0102030405060708)",
      },
    ]);
    expect(completed).toEqual(["A", "C"]);
    // The retried batch carries A's and C's calls and none of B's.
    expect(sent).toHaveLength(1);
    expect(batchTargets(sent[0].data)).toEqual([ACCEPTS, ACCEPTS, ACCEPTS]);
  });

  it("never runs a set-aside name's later rounds", async () => {
    const { outcome, completed, sent } = await shape({
      A: [viaBatcher(ACCEPTS, "a1"), asOwner(ACCEPTS, "a2")],
      B: [
        viaBatcher(REFUSES, "b1"),
        asOwner(ACCEPTS, "b2"),
        viaBatcher(ACCEPTS, "b3"),
      ],
    });

    expect((await outcome).map((s) => s.fixtureId)).toEqual(["B"]);
    expect(completed).toEqual(["A"]);
    // A's batch, then A's own transaction; nothing of B's.
    expect(sent.map((tx) => tx.to.toLowerCase())).toEqual([BATCHER, ACCEPTS]);
    expect(batchTargets(sent[0].data)).toEqual([ACCEPTS]);
  });

  it("sets aside only the name whose own transaction is refused", async () => {
    const { outcome, completed, sent } = await shape({
      A: [asOwner(REFUSES, "a1"), asOwner(ACCEPTS, "a2")],
      B: [asOwner(ACCEPTS, "b1")],
    });

    expect(await outcome).toEqual([
      {
        fixtureId: "A",
        call: "a1",
        reason: "InvalidEVMAddress(0x0102030405060708)",
      },
    ]);
    expect(completed).toEqual(["B"]);
    // A's second call never went out.
    expect(sent.map((tx) => tx.to.toLowerCase())).toEqual([ACCEPTS]);
  });

  it("stops on a failure that is no contract's refusal", async () => {
    const { outcome, completed, sent } = await shape({
      A: [viaBatcher(ACCEPTS, "a1")],
      B: [viaBatcher(UNREACHABLE, "b1")],
    });

    await expect(outcome).rejects.toThrow(/HTTP request failed/);
    expect(completed).toEqual([]);
    expect(sent).toHaveLength(0);
  });
});

describe("the holder of a seeded name", () => {
  const REGISTRAR = "0x00000000000000000000000000000000000000e1" as Address;
  const WRAPPER = "0x00000000000000000000000000000000000000e2" as Address;
  const HOLDER = "0x00000000000000000000000000000000000000e3" as Address;

  /// A chain where the registrar answers `registrant` and the wrapper answers
  /// `wrapped` for every token.
  const chain = (registrant: Address, wrapped: Address) => ({
    readContract: async ({ address }: { address: Address }) =>
      sameAddress(address, WRAPPER) ? wrapped : registrant,
  });
  const addresses = { baseRegistrar: REGISTRAR, wrapper: WRAPPER };

  it("is the registrant of an unwrapped name", async () => {
    expect(await v1Holder(chain(HOLDER, zeroAddress), addresses, "fx")).toBe(
      getAddress(HOLDER),
    );
  });

  // Every wrapped name's registration sits with the wrapper, so reading the
  // registrar alone mistakes a name another run wrapped for one of this run's.
  it("is the wrapper token's owner for a wrapped name", async () => {
    expect(await v1Holder(chain(WRAPPER, HOLDER), addresses, "fx")).toBe(
      getAddress(HOLDER),
    );
  });
});
