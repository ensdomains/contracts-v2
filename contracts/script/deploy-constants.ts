export const MAX_EXPIRY = (1n << 64n) - 1n; // see: DatastoreUtils.sol

export const LOCAL_BATCH_GATEWAY_URL = "x-batch-gateway:true";

interface Flags {
  [key: string]: bigint | Flags;
}
const FLAGS = {
  // see: LibRegistryRoles.sol
  EAC: {
    REGISTRAR: 1n << 0n,
    RENEW: 1n << 4n,
    SET_SUBREGISTRY: 1n << 8n,
    SET_RESOLVER: 1n << 12n,
    SET_TOKEN_OBSERVER: 1n << 16n,
    BURN: 1n << 20n,
  },
  // see: L2/ETHRegistry.sol
  ETH: {
    SET_PRICE_ORACLE: 1n << 20n,
    SET_COMMITMENT_AGES: 1n << 24n,
  },
  // see: L2/UserRegistry.sol
  USER: {
    UPGRADE: 1n << 20n,
  },
  // see: LibBridgeRoles.sol
  BRIDGE: {
    EJECTOR: 1n << 0n,
  },
} as const satisfies Flags;
function mapFlags(flags: Flags, fn: (x: bigint) => bigint): Flags {
  return Object.fromEntries(
    Object.entries(flags).map(([k, x]) => [
      k,
      typeof x === "bigint" ? fn(x) : mapFlags(x, fn),
    ]),
  );
}
export const ROLES = {
  OWNER: FLAGS,
  ADMIN: Object.fromEntries(
    Object.entries(FLAGS).map(([k, v]) => [k, mapFlags(v, (x) => x << 128n)]),
  ),
  ALL: 0x1111111111111111111111111111111111111111111111111111111111111111n, // see: EnhancedAccessControl.sol
  ADMIN_ROLES:
    0x1111111111111111111111111111111100000000000000000000000000000000n, // see: EnhancedAccessControl.sol
} as const;

// see: IPermissionedRegistry.sol
export const STATUS = {
  AVAILABLE: 0,
  RESERVED: 1,
  REGISTERED: 2,
};
