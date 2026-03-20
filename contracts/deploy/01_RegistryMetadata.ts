import { execute } from "@rocketh";
import type { Abi_MockHCAFactoryBasic } from "generated/abis/MockHCAFactoryBasic.ts";
import { Artifact_SimpleRegistryMetadata } from 'generated/artifacts/SimpleRegistryMetadata.js';

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<Abi_MockHCAFactoryBasic>("HCAFactory");

    await deploy("SimpleRegistryMetadata", {
      account: deployer,
      artifact: Artifact_SimpleRegistryMetadata,
      args: [hcaFactory.address],
    });
  },
  { tags: ["RegistryMetadata", "v2"], dependencies: ["HCAFactory"] },
);
