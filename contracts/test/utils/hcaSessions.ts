import {
  type Address,
  concat,
  encodeAbiParameters,
  type Hex,
  keccak256,
  parseAbiParameters,
  stringToHex,
  zeroHash,
} from "viem";

export const PERMIT2_ADDRESS: Address =
  "0x000000000022D473030F116dDEE9F6B43aC78BA3";
export const PERMIT2_DOMAIN_TYPEHASH: Hex =
  "0x8cad95687ba82c2ce50e74f7b754645e5117c3a5bec8151c0726d5857980a866";
export const PERMIT2_NAME_HASH: Hex =
  "0x9ac997416e8ff9d2ff6bebeb7149f65cdae5e32e2b90440b566bb3044041d36a";
export const PERMIT2_JIT_TYPEHASH: Hex =
  "0x1b355fbc76f14a5aefe5c85df793a0f876f90d66f457273501c13ac311b5f3f8";
export const PERMIT2_MANDATE_TYPEHASH: Hex =
  "0xc988b4da10503879cf4b893fed09620229f5ade301ef5e4af6124b22823627dc";
export const EMPTY_ARRAY_HASH: Hex =
  "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
export const NO_OPS_HASH: Hex =
  "0x0c7bea50822ae8a3846eccbda4961a80e1e08aa92f2bf046be0011514ad2ddf1";

export const SESSION_GRANT_TYPEHASH = keccak256(
  stringToHex(
    "RegistrationSessionGrant(uint256 chainId,address hca,address owner,address sessionKey,uint48 validUntil,address resolver)",
  ),
);
export const PERMIT2_SESSION_GRANT_TYPEHASH = keccak256(
  stringToHex(
    "RegistrationPermit2SessionGrant(uint256 destinationChainId,address hca,address owner,address sessionKey,uint48 validUntil,address resolver)",
  ),
);

export type Permit2SessionAuthorization = {
  sourceChainId: bigint;
  permit2Contract: Address;
  arbiter: Address;
  nonce: bigint;
  expires: bigint;
};

export function permit2SessionDigest({
  chainId,
  hca,
  owner,
  sessionKey,
  validUntil,
  resolver,
  permit2,
}: {
  chainId: bigint;
  hca: Address;
  owner: Address;
  sessionKey: Address;
  validUntil: number | bigint;
  resolver: Address;
  permit2: Permit2SessionAuthorization;
}): Hex {
  const grantHash = keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "bytes32,uint256,address,address,address,uint48,address",
      ),
      [
        PERMIT2_SESSION_GRANT_TYPEHASH,
        chainId,
        hca,
        owner,
        sessionKey,
        Number(validUntil),
        resolver,
      ],
    ),
  );
  const mandate = keccak256(
    encodeAbiParameters(
      parseAbiParameters("bytes32,bytes32,uint128,bytes32,bytes32,bytes32"),
      [PERMIT2_MANDATE_TYPEHASH, zeroHash, 0n, grantHash, NO_OPS_HASH, zeroHash],
    ),
  );
  const permit2Hash = keccak256(
    encodeAbiParameters(
      parseAbiParameters("bytes32,bytes32,address,uint256,uint256,bytes32"),
      [
        PERMIT2_JIT_TYPEHASH,
        EMPTY_ARRAY_HASH,
        permit2.arbiter,
        permit2.nonce,
        permit2.expires,
        mandate,
      ],
    ),
  );
  const domainSeparator = keccak256(
    encodeAbiParameters(parseAbiParameters("bytes32,bytes32,uint256,address"), [
      PERMIT2_DOMAIN_TYPEHASH,
      PERMIT2_NAME_HASH,
      permit2.sourceChainId,
      permit2.permit2Contract,
    ]),
  );
  return keccak256(concat(["0x1901", domainSeparator, permit2Hash]));
}
