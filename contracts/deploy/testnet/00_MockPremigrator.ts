import { execute } from "@rocketh";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.ts";
import { Artifact_MockPremigrator } from 'generated/artifacts/MockPremigrator.js';
import { ROLES } from "../../script/deploy-constants.js";

export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer }, network, tags  }) => {
    // only on testnet
    if (network.chain.id === 1) return;
    // only for dev (fresh) deployments
    if (!tags.dev) return;

    const ethRegistry =
      get<Abi_PermissionedRegistry>("ETHRegistry");

    const mockPremigrator = await deploy("MockPremigrator", {
      account: deployer,
      artifact: Artifact_MockPremigrator,
      args: [ethRegistry.address],
    });

    await write(ethRegistry, {
      account: deployer,
      functionName: "grantRootRoles",
      args: [
        ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW,
        mockPremigrator.address,
      ],
    });
  },
  {
    tags: ["MockPremigrator", "l1"],
    dependencies: [],
  },
);
