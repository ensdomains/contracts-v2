import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { encodeFunctionData, getAddress, parseAbi, type Address } from "viem";

import {
  buildDaoProposal,
  decodeProposalCalls,
  indexDeploymentArtifacts,
  mergeProposalCalls,
} from "../../script/migrations/daoProposal.js";
import {
  executePreparedOwnerTransactions,
  printPreparedCall,
  readPreparedOwnerTransactions,
  recordPreparedCallsTo,
  type PreparedOwnerTransaction,
} from "../../script/migrations/ownerTx.js";

const REGISTRAR_ABI = parseAbi([
  "function setController(address controller, bool enabled)",
]);
const PROXY_ABI = parseAbi(["function upgradeTo(address implementation)"]);

const REGISTRAR = getAddress("0x00000000000000000000000000000000000000aa");
const PROXY = getAddress("0x00000000000000000000000000000000000000bb");
const UNKNOWN = getAddress("0x00000000000000000000000000000000000000cc");
const CONTROLLER = getAddress("0x00000000000000000000000000000000000000c1");
const IMPLEMENTATION = getAddress("0x00000000000000000000000000000000000000d1");

const setController = (enabled: boolean) =>
  encodeFunctionData({
    abi: REGISTRAR_ABI,
    functionName: "setController",
    args: [CONTROLLER, enabled],
  });
const upgradeTo = encodeFunctionData({
  abi: PROXY_ABI,
  functionName: "upgradeTo",
  args: [IMPLEMENTATION],
});

const contracts = new Map([
  [REGISTRAR.toLowerCase(), { name: "ReverseRegistrar", abi: REGISTRAR_ABI }],
  [PROXY.toLowerCase(), { name: "TopProxy", abi: PROXY_ABI }],
]);

function tx(
  to: Address,
  data: `0x${string}`,
  extra: Partial<PreparedOwnerTransaction> = {},
): PreparedOwnerTransaction {
  return { to, data, value: "0", ...extra };
}

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "dao-proposal-"));
});
afterEach(() => {
  recordPreparedCallsTo(undefined);
  rmSync(dir, { recursive: true, force: true });
});

describe("mergeProposalCalls", () => {
  it("keeps file order and drops a repeated call", () => {
    const merged = mergeProposalCalls([
      [tx(REGISTRAR, setController(true)), tx(PROXY, upgradeTo)],
      [
        tx(REGISTRAR, setController(true), { label: "again" }),
        tx(REGISTRAR, setController(false)),
      ],
    ]);
    expect(merged.map((call) => call.data)).toEqual([
      setController(true),
      upgradeTo,
      setController(false),
    ]);
  });

  it("treats the same calldata with a different value as a different call", () => {
    const merged = mergeProposalCalls([
      [tx(PROXY, upgradeTo), tx(PROXY, upgradeTo, { value: "1" })],
    ]);
    expect(merged).toHaveLength(2);
  });
});

describe("decodeProposalCalls", () => {
  it("decodes each call against the contract at its target", () => {
    const [first, second] = decodeProposalCalls(
      [
        tx(REGISTRAR, setController(true), { label: "authorize adapter" }),
        tx(PROXY, upgradeTo, {
          deployment: "TopProxy",
          functionName: "upgradeTo",
        }),
      ],
      contracts,
    );
    expect(first).toMatchObject({
      index: 1,
      contract: "ReverseRegistrar",
      signature: "setController(address,bool)",
      label: "authorize adapter",
      args: [CONTROLLER, true],
    });
    expect(second).toMatchObject({
      index: 2,
      contract: "TopProxy",
      label: "TopProxy.upgradeTo",
    });
  });

  it("refuses a call to an unknown contract", () => {
    expect(() =>
      decodeProposalCalls([tx(UNKNOWN, upgradeTo)], contracts),
    ).toThrow(/#1 .* is not a known contract/);
  });

  it("refuses calldata that does not decode against its target", () => {
    expect(() =>
      decodeProposalCalls([tx(REGISTRAR, upgradeTo)], contracts),
    ).toThrow(/does not decode against ReverseRegistrar/);
  });

  it("lists every offender, not just the first", () => {
    expect(() =>
      decodeProposalCalls(
        [tx(UNKNOWN, upgradeTo), tx(REGISTRAR, upgradeTo)],
        contracts,
      ),
    ).toThrow(/#1[\s\S]*#2/);
  });
});

describe("recordPreparedCallsTo", () => {
  it("records printed calls in the prepared-transaction format", () => {
    const file = join(dir, "nested", "calls.jsonl");
    recordPreparedCallsTo(file);
    printPreparedCall("authorize adapter", REGISTRAR, setController(true));
    printPreparedCall("switch proxy", PROXY, upgradeTo);
    recordPreparedCallsTo(undefined);
    printPreparedCall("not recorded", PROXY, upgradeTo);

    const calls = readPreparedOwnerTransactions(file);
    expect(calls.map((call) => call.label)).toEqual([
      "authorize adapter",
      "switch proxy",
    ]);
    expect(calls[0]).toMatchObject({
      to: REGISTRAR,
      value: "0",
      data: setController(true),
    });
  });
});

describe("buildDaoProposal", () => {
  function writeArtifact(
    root: string,
    name: string,
    address: Address,
    abi: unknown,
  ) {
    mkdirSync(root, { recursive: true });
    writeFileSync(join(root, `${name}.json`), JSON.stringify({ address, abi }));
  }

  it("writes the ordered calls, the Governor arrays and a readable summary", () => {
    const v2 = join(dir, "deployments", "mainnet");
    const v1 = join(dir, "v1", "mainnet");
    writeArtifact(v2, "TopProxy", PROXY, PROXY_ABI);
    writeArtifact(v1, "ReverseRegistrar", REGISTRAR, REGISTRAR_ABI);

    const deferred = join(dir, "deferred.jsonl");
    writeFileSync(
      deferred,
      `${JSON.stringify({ account: "v1Owner", from: UNKNOWN, ...tx(REGISTRAR, setController(true)), functionName: "setController" })}\n`,
    );
    const prepared = join(dir, "prepared.jsonl");
    writeFileSync(
      prepared,
      [
        JSON.stringify(
          tx(REGISTRAR, setController(true), { label: "duplicate" }),
        ),
        JSON.stringify(tx(PROXY, upgradeTo, { label: "switch proxy" })),
      ].join("\n"),
    );

    const out = join(dir, "proposal");
    const calls = buildDaoProposal({
      files: [deferred, prepared],
      outDir: out,
      contractDirs: [v2, v1],
    });
    expect(calls).toHaveLength(2);

    const proposal = JSON.parse(
      readFileSync(join(out, "proposal.json"), "utf8"),
    );
    expect(proposal).toEqual({
      targets: [REGISTRAR, PROXY],
      values: ["0", "0"],
      calldatas: [setController(true), upgradeTo],
      signatures: ["setController(address,bool)", "upgradeTo(address)"],
    });

    const replayable = readPreparedOwnerTransactions(join(out, "calls.jsonl"));
    expect(replayable.map((call) => [call.to, call.data])).toEqual([
      [REGISTRAR, setController(true)],
      [PROXY, upgradeTo],
    ]);
    expect(replayable.every((call) => call.from === undefined)).toBe(true);

    const markdown = readFileSync(join(out, "proposal.md"), "utf8");
    expect(markdown).toContain("these 2 calls");
    expect(markdown).toContain("| 2 | TopProxy");
  });

  it("refuses to write an empty proposal", () => {
    const empty = join(dir, "empty.jsonl");
    writeFileSync(empty, "");
    expect(() =>
      buildDaoProposal({
        files: [empty],
        outDir: join(dir, "out"),
        contractDirs: [],
      }),
    ).toThrow(/empty proposal/);
  });

  it("indexes the first directory that records an address", () => {
    const first = join(dir, "first");
    const second = join(dir, "second");
    writeArtifact(first, "Preferred", PROXY, PROXY_ABI);
    writeArtifact(second, "Shadowed", PROXY, PROXY_ABI);
    expect(
      indexDeploymentArtifacts([first, second]).get(PROXY.toLowerCase())?.name,
    ).toBe("Preferred");
  });
});

describe("executePreparedOwnerTransactions", () => {
  it("refuses to impersonate on a remote RPC", async () => {
    const file = join(dir, "calls.jsonl");
    writeFileSync(file, `${JSON.stringify(tx(PROXY, upgradeTo))}\n`);
    await expect(
      executePreparedOwnerTransactions({
        network: "mainnet",
        rpcUrl: "https://example.invalid",
        file,
        impersonateAccount: UNKNOWN,
      }),
    ).rejects.toThrow(/needs a local fork/);
  });
});
