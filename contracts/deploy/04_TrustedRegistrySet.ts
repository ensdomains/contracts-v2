import { execute } from "@rocketh";
import { isAddressEqual } from "viem";
import { Artifact_PermissionedAddressSet } from "generated/artifacts/PermissionedAddressSet.js";

const NAMES = [
  "RootRegistry",
  "ETHRegistry",
  "UserRegistryImpl",
  "WrapperRegistryImpl",
];

export default execute(
  async ({
    deploy,
    get,
    execute: write,
    read,
    namedAccounts: { deployer, owner },
  }) => {
    const set = await deploy("TrustedRegistrySet", {
      account: deployer,
      artifact: Artifact_PermissionedAddressSet,
      args: [deployer],
    });

    const roles = await read(set, {
      functionName: "roles",
      args: [0n, deployer],
    });
    if (roles) {
      for (const name of NAMES) {
        console.log(`  - Adding ${name}`);
        await write(set, {
          account: deployer,
          functionName: "approve",
          args: [get(name).address, true],
        });
      }
    }

    if (!isAddressEqual(deployer, owner)) {
      await write(set, {
        account: deployer,
        functionName: "grantRootRoles",
        args: [roles, owner],
      });
      await write(set, {
        account: deployer,
        functionName: "revokeRootRoles",
        args: [roles, deployer],
      });
    }
  },
  {
    tags: ["TrustedRegistrySet", "v2"],
    dependencies: [...NAMES],
  },
);
