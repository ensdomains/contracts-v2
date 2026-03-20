import { execute } from "@rocketh";
import type { Abi_MockHCAFactoryBasic } from "generated/abis/MockHCAFactoryBasic.ts";
import type { Abi_SimpleRegistryMetadata } from "generated/abis/SimpleRegistryMetadata.ts";
import { Artifact_UserRegistry } from 'generated/artifacts/UserRegistry.js';

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<Abi_MockHCAFactoryBasic>("HCAFactory");

    const registryMetadata = get<
      Abi_SimpleRegistryMetadata
    >("SimpleRegistryMetadata");

    await deploy("UserRegistryImpl", {
      account: deployer,
      artifact: Artifact_UserRegistry,
      args: [hcaFactory.address, registryMetadata.address],
    });
  },
  {
    tags: ["UserRegistryImpl", "v2"],
    dependencies: ["HCAFactory", "RegistryMetadata"],
  },
);
