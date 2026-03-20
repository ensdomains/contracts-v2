import { execute } from "@rocketh";
import type { Abi_MockHCAFactoryBasic } from "generated/abis/MockHCAFactoryBasic.ts";
import { Artifact_PermissionedResolver } from 'generated/artifacts/PermissionedResolver.js';

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<Abi_MockHCAFactoryBasic>("HCAFactory");

    await deploy("PermissionedResolverImpl", {
      account: deployer,
      artifact: Artifact_PermissionedResolver,
      args: [hcaFactory.address],
    });
  },
  {
    tags: ["PermissionedResolverImpl", "v2"],
    dependencies: ["HCAFactory"],
  },
);
