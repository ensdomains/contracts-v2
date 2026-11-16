import { execute } from "@rocketh";
import type { Abi_DNSTLDResolver } from "generated/abis/DNSTLDResolver.js";
import type { Abi_IPermissionedRegistry } from "generated/abis/IPermissionedRegistry.js";
import type { Abi_PublicSuffixList } from "generated/abis/PublicSuffixList.js";
import { Artifact_TemporaryDNSRegistrar } from "generated/artifacts/TemporaryDNSRegistrar.js";
import {
  DAO_TOKEN_SAFE,
  DEPLOYMENT_ROLES,
  toRequiredGrantRevokeRoles,
} from "../script/deploy-constants.js";

export default execute(
  async ({
    get,
    getV1,
    deploy,
    execute: write,
    read,
    namedAccounts: { deployer, owner },
    tags,
  }) => {
    const publicSuffixList = await getV1<Abi_PublicSuffixList>(
      "SimplePublicSuffixList",
    );
    const rootRegistry = get<Abi_IPermissionedRegistry>("RootRegistry");
    const dnsTLDResolver = get<Abi_DNSTLDResolver>("DNSTLDResolver");

    let tokenOwner = owner;
    if (tags.hasDao) {
      tokenOwner = DAO_TOKEN_SAFE;
    }

    const dnsRegistrar = await deploy("TemporaryDNSRegistrar", {
      account: deployer,
      artifact: Artifact_TemporaryDNSRegistrar,
      args: [
        owner,
        rootRegistry.address,
        tokenOwner,
        publicSuffixList.address,
        dnsTLDResolver.address,
      ],
    });

    if (dnsRegistrar.newlyDeployed) {
      const roles = DEPLOYMENT_ROLES.TEMPORARY_DNS_REGISTRAR_ROOT;
      const canGrant = await read(rootRegistry, {
        functionName: "hasRootRoles",
        args: [toRequiredGrantRevokeRoles(roles), deployer],
      });
      if (canGrant) {
        await write(rootRegistry, {
          account: deployer,
          functionName: "grantRootRoles",
          args: [
            DEPLOYMENT_ROLES.TEMPORARY_DNS_REGISTRAR_ROOT,
            dnsRegistrar.address,
          ],
        });
      } else {
        console.warn(`  -- Warn: TemporaryDNSRegistrar requires root roles`);
      }
    }
  },
  {
    tags: ["TemporaryDNSRegistrar", "v2", "migration:phase1:deploy-v2"],
    dependencies: ["RootRegistry", "SimplePublicSuffixList", "DNSTLDResolver"],
  },
);
