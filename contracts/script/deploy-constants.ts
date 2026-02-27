export const MAX_EXPIRY = (1n << 64n) - 1n; // see: DatastoreUtils.sol

export const LOCAL_BATCH_GATEWAY_URL = "x-batch-gateway:true";

interface Flags {
  [key: string]: bigint | Flags;
}

const FLAGS = {
  // see: EnhancedAccessControl.sol / EACBaseRolesLib.sol
  ALL: 0x1111111111111111111111111111111111111111111111111111111111111111n,
  // see: PermissionedRegistry.sol / RegistryRolesLib.sol
  REGISTRY: {
    REGISTRAR: 1n << 0n,
    REGISTER_RESERVED: 1n << 4n,
    RENEW: 1n << 8n,
    UNREGISTER: 1n << 12n,
    SET_SUBREGISTRY: 1n << 16n,
    SET_RESOLVER: 1n << 20n,
    CAN_TRANSFER: 1n << 24n,
    UPGRADE: 1n << 124n,
  },
  // see: ETHRegistrar.sol
  REGISTRAR: {
    SET_ORACLE: 1n << 0n,
  },
  // see: PermissionedResolver.sol / PermissionedResolverLib.sol
  RESOLVER: {
    SET_ADDR: 1n << 0n,
    SET_TEXT: 1n << 4n,
    SET_CONTENTHASH: 1n << 8n,
    SET_PUBKEY: 1n << 12n,
    SET_ABI: 1n << 16n,
    SET_INTERFACE: 1n << 20n,
    SET_NAME: 1n << 24n,
    SET_ALIAS: 1n << 28n,
    CLEAR: 1n << 32n,
    UPGRADE: 1n << 124n,
  },
} as const satisfies Flags;

function adminify(flags: Flags): Flags {
  return Object.fromEntries(
    Object.entries(flags).map(([k, x]) => [
      k,
      typeof x === "bigint" ? x << 128n : adminify(x),
    ]),
  );
}

export const ROLES = {
  ...FLAGS,
  ADMIN: adminify(FLAGS),
} as const satisfies Flags;

// see: IPermissionedRegistry.sol
export const STATUS = {
  AVAILABLE: 0,
  RESERVED: 1,
  REGISTERED: 2,
};
