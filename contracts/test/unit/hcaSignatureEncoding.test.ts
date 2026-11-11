import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import {
  concat,
  encodeAbiParameters,
  encodePacked,
  pad,
  size,
  slice,
  toHex,
  zeroAddress,
  zeroHash,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

// Exercise the installed Bun patch, including its internal transport boundaries.
const require = createRequire(import.meta.url);
const sdkRoot = dirname(require.resolve("@rhinestone/sdk"));
const filename = join(sdkRoot, "execution/utils.js");
const internal = { exports: {} as Record<string, (...args: any[]) => any> };
new Function(
  "require",
  "module",
  "exports",
  `${readFileSync(filename, "utf8")}
Object.assign(module.exports, { hcaOwnerAuthorization, packHcaAuthorizationProof,
  packStandaloneHcaFixedSessionSignature, packStandaloneHcaPermit2SessionSignature,
  packHcaFundingPermit2SessionSignature, signIntentTypedData, signUserOp });
`,
)(createRequire(filename), internal, internal.exports);
const sdk = internal.exports;
const { getPermissionId } = require(
  join(sdkRoot, "modules/validators/index.js"),
);
const address = (value: number) => pad(toHex(value), { size: 20 });
const key = privateKeyToAccount(pad("0x1234", { size: 32 }));
const module = address(10);
const session = {
  chain: sepolia,
  account: address(11),
  salt: zeroHash,
  owners: { type: "ecdsa", accounts: [key] },
};
const permissionId = getPermissionId(session);
const eoaSignature = concat([
  pad("0x01", { size: 32 }),
  pad("0x02", { size: 32 }),
  "0x1b",
]);
const opaqueSignature = `0x${"a5".repeat(173)}` as Hex;
const ownerEnvelope = (signature: Hex) =>
  encodeAbiParameters(
    [{ type: "bytes1" }, { type: "bytes" }],
    ["0x06", signature],
  );
const userSignature = (contractOwner: boolean, signature = opaqueSignature) =>
  concat([
    zeroAddress,
    contractOwner ? ownerEnvelope(signature) : eoaSignature,
  ]);
const enableData = (contractOwner: boolean) => ({
  userSignature: userSignature(contractOwner),
  sessionToEnableIndex: 0,
  hashesAndChainIds: [{ chainId: BigInt(sepolia.id), sessionDigest: zeroHash }],
  hcaSessionNonce: 0n,
  hcaSessionConfig: {
    sessionKey: key.address,
    validUntil: 2_000_000_000,
    resolver: address(12),
    refundToken: address(13),
    maxRefundExchangeRate: 1n,
    maxRefundGasOverhead: 0,
    maxRefundAmount: 100n,
  },
});
const signers = (contractOwner: boolean) => ({
  type: "experimental_session",
  session,
  verifyExecutions: true,
  enableData: enableData(contractOwner),
});
const operation = {
  vt: pad("0x0201", { size: 32, dir: "right" }),
  ops: [{ to: address(14), value: 0n, data: "0x12345678" }],
};
const config = {
  account: {
    type: "hca",
    version: "ens-standalone-1.1.0",
    factory: address(20),
    implementation: address(21),
    validator: module,
    verifiableFactory: address(22),
    proxyLogic: address(23),
  },
  owners: { type: "ecdsa", module, accounts: [key] },
};
const packedSession = concat(["0x00", permissionId, eoaSignature]);
const claim = {
  domain: { chainId: sepolia.id },
  message: {
    spender: address(30),
    nonce: 1n,
    deadline: 2_000_000_000n,
    permitted: [{ token: address(31), amount: 100n }],
    mandate: {
      target: {
        recipient: address(32),
        targetChain: 1n,
        fillExpiry: 2_000_000_000n,
        tokenOut: [{ token: address(33), amount: 100n }],
      },
      minGas: 1n,
      originOps: operation,
      destOps: operation,
      q: zeroHash,
    },
  },
};

describe("HCA wallet signature transport", () => {
  it("preserves the legacy EOA authorization byte for byte", () => {
    expect(sdk.packHcaAuthorizationProof(enableData(false))).toBe(
      concat([
        "0x0001",
        encodePacked(["uint64", "bytes32"], [BigInt(sepolia.id), zeroHash]),
        eoaSignature,
      ]),
    );
  });
  it.each([
    0, 65, 130, 173, 65535,
  ])("preserves %i opaque signature bytes with a bounded prefix", (length) => {
    const signature = `0x${"a5".repeat(length)}` as Hex;
    const encoded = sdk.hcaOwnerAuthorization(userSignature(true, signature));
    expect(encoded.contractOwner).toBe(true);
    expect(encoded.signature).toBe(
      concat([toHex(length, { size: 2 }), signature]),
    );
  });
  it("rejects oversized, malformed, and ambiguous owner encodings", () => {
    for (const malformed of [
      "0x",
      concat([address(1), eoaSignature]),
      concat([zeroAddress, opaqueSignature]),
      concat([userSignature(true), "0x00"]),
      userSignature(true, `0x${"aa".repeat(65536)}`),
    ]) {
      expect(() => sdk.hcaOwnerAuthorization(malformed)).toThrow();
    }
    expect(() =>
      sdk.packHcaAuthorizationProof({
        ...enableData(true),
        sessionToEnableIndex: 1,
      }),
    ).toThrow();
    expect(() =>
      sdk.packHcaAuthorizationProof({
        ...enableData(true),
        hashesAndChainIds: [],
      }),
    ).toThrow();
  });
  it.each([
    false,
    true,
  ])("packs all three routes with contractOwner=%s", (contractOwner) => {
    const proof = sdk.packHcaAuthorizationProof(enableData(contractOwner));
    const same = sdk.packStandaloneHcaFixedSessionSignature(
      config,
      signers(contractOwner),
      { message: { nonce: 1n, op: operation } },
      packedSession,
    );
    const cross = sdk.packStandaloneHcaPermit2SessionSignature(
      config,
      signers(contractOwner),
      claim,
      packedSession,
    );
    const source = sdk.packHcaFundingPermit2SessionSignature(
      { experimental_sessions: { module } },
      signers(contractOwner),
      claim,
      concat([module, "0x00", permissionId, zeroHash, eoaSignature]),
      { sourceToken: address(31), destinationRecipient: address(32) },
    );
    expect(slice(same, 20, 21)).toBe(contractOwner ? "0x08" : "0x05");
    expect(slice(cross, 20, 21)).toBe(contractOwner ? "0x07" : "0x04");
    expect(slice(source, 20, 21)).toBe(contractOwner ? "0x07" : "0x04");
    expect(slice(same, 20 + 33 + 108, 20 + 33 + 108 + size(proof))).toBe(proof);
    expect(slice(cross, 20 + 33 + 108, 20 + 33 + 108 + size(proof))).toBe(
      proof,
    );
    expect(slice(source, 20 + 33, 20 + 33 + size(proof))).toBe(proof);
  });
  it("tags wallet signatures only when explicitly selected, including 65-byte wallet proofs", async () => {
    const parameters = {
      domain: { name: "HCA test", chainId: sepolia.id },
      types: { Message: [{ name: "value", type: "uint256" }] },
      primaryType: "Message",
      message: { value: 1n },
    };
    for (const signature of [eoaSignature, opaqueSignature]) {
      const wallet = { ...key, signTypedData: async () => signature };
      const walletConfig = {
        ...config,
        account: { ...config.account, ownerSignatureType: "erc1271" },
        owners: { ...config.owners, accounts: [wallet] },
      };
      const packed = await sdk.signTypedData(
        walletConfig,
        parameters,
        sepolia,
        undefined,
        { skipErc6492: true },
      );
      expect(packed).toBe(concat([zeroAddress, ownerEnvelope(signature)]));
      expect(
        await sdk.signIntentTypedData(
          walletConfig,
          undefined,
          { address: module },
          true,
          parameters,
          sepolia,
          false,
        ),
      ).toBe(packed);
      await expect(
        sdk.signUserOp(walletConfig, sepolia, undefined, {}),
      ).rejects.toThrow("UserOperations");
    }
    const ordinary = await sdk.signTypedData(
      config,
      parameters,
      sepolia,
      undefined,
      { skipErc6492: true },
    );
    expect(size(ordinary)).toBe(85);
  });
});
