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
    SET_PARENT: 1n << 8n,
    UNREGISTER: 1n << 12n,
    RENEW: 1n << 16n,
    SET_SUBREGISTRY: 1n << 20n,
    SET_RESOLVER: 1n << 24n,
    CAN_TRANSFER: 1n << 28n,
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

const ADMIN = adminify(FLAGS) as typeof FLAGS;

export const ROLES = {
  ...FLAGS,
  ADMIN,
} as const;

// Role bitmaps for static deployment per README Static Deployment Permissions.
export const DEPLOYMENT_ROLES = {
  // RootRegistry root: REGISTRAR✓✓, REGISTER_RESERVED✓✓, SET_PARENT✓✓, RENEW✓✓
  ROOT_REGISTRY_ROOT:
    ROLES.REGISTRY.REGISTRAR |
    ROLES.ADMIN.REGISTRY.REGISTRAR |
    ROLES.REGISTRY.REGISTER_RESERVED |
    ROLES.ADMIN.REGISTRY.REGISTER_RESERVED |
    ROLES.REGISTRY.SET_PARENT |
    ROLES.ADMIN.REGISTRY.SET_PARENT |
    ROLES.REGISTRY.RENEW |
    ROLES.ADMIN.REGISTRY.RENEW,
  // .eth token: SET_SUBREGISTRY AR, SET_RESOLVER AR
  ETH_TOKEN:
    ROLES.REGISTRY.SET_SUBREGISTRY |
    ROLES.ADMIN.REGISTRY.SET_SUBREGISTRY |
    ROLES.REGISTRY.SET_RESOLVER |
    ROLES.ADMIN.REGISTRY.SET_RESOLVER,
  // Full registry role bitmap for ReverseRegistry root, .reverse token, and .addr token.
  // Granting all roles is harmless; some (e.g. REGISTRAR) are root-only and don't apply to tokens.
  REVERSE_AND_ADDR: FLAGS.ALL,
  // ETHRegistry root deployer: REGISTRAR✓, REGISTER_RESERVED✓, SET_PARENT✓✓, RENEW✓
  ETH_REGISTRY_ROOT:
    ROLES.ADMIN.REGISTRY.REGISTRAR |
    ROLES.ADMIN.REGISTRY.REGISTER_RESERVED |
    ROLES.REGISTRY.SET_PARENT |
    ROLES.ADMIN.REGISTRY.SET_PARENT |
    ROLES.ADMIN.REGISTRY.RENEW,
  // UnlockedMigrationController and LockedMigrationController
  // only need to register() pre-migrated reservations on ETHRegistry (see: "ENSv2 Migration Case Study")
  MIGRATION_CONTROLLER_ROOT: ROLES.REGISTRY.REGISTER_RESERVED,
} as const;

// see: IPermissionedRegistry.sol
export const STATUS = {
  AVAILABLE: 0,
  RESERVED: 1,
  REGISTERED: 2,
};

// see: INameWrapper.sol
export const FUSES = {
  CANNOT_UNWRAP: 1 << 0,
  CANNOT_BURN_FUSES: 1 << 1,
  CANNOT_TRANSFER: 1 << 2,
  CANNOT_SET_RESOLVER: 1 << 3,
  CANNOT_SET_TTL: 1 << 4,
  CANNOT_CREATE_SUBDOMAIN: 1 << 5,
  CANNOT_APPROVE: 1 << 6,
  PARENT_CANNOT_CONTROL: 1 << 16,
  IS_DOT_ETH: 1 << 17,
  CAN_EXTEND_EXPIRY: 1 << 18,
  CAN_DO_EVERYTHING: 0,
} as const;

export const FUSE_MASKS = {
  PARENT_CONTROLLED: 0xffff0000,
  PARENT_RESERVED: 0x0000ff80, // bits 7-15 (docs say 17-32)
  USER_SETTABLE: 0xfffdffff, // ~IS_DOT_ETH
} as const;
