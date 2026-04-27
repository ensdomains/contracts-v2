import { ROLES } from "../../script/deploy-constants.js";
import type { DevnetEnvironment } from "../../script/setup.js";

/// Revoke the roles that `deploy/03_ETHRegistrar.ts`,
/// `deploy/02_UnlockedMigrationController.ts`, and
/// `deploy/04_LockedMigrationController.ts` pre-grant on the .eth registry.
///
/// The devnet's deploy scripts grant the three registrars/controllers the same
/// roles that `prepareMigration` is meant to grant later in the migration
/// sequence. Calling this from a test `initialize()` puts the devnet into the
/// true pre-`prepareMigration` state so the grant path can be exercised
/// end-to-end.
export async function revertPrePrepareMigrationRoles(
  env: DevnetEnvironment,
): Promise<void> {
  const registry = env.v2.ETHRegistry;

  await registry.write.revokeRootRoles([
    ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW,
    env.v2.ETHRegistrar.address,
  ]);

  await registry.write.revokeRootRoles([
    ROLES.REGISTRY.REGISTER_RESERVED,
    env.v2.UnlockedMigrationController.address,
  ]);

  await registry.write.revokeRootRoles([
    ROLES.REGISTRY.REGISTER_RESERVED,
    env.v2.LockedMigrationController.address,
  ]);
}
