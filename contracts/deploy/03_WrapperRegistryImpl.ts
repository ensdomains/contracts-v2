import { execute } from "@rocketh";
import type { Abi_ENSV1Resolver } from "generated/abis/ENSV1Resolver.ts";
import type { Abi_MockHCAFactoryBasic } from "generated/abis/MockHCAFactoryBasic.ts";
import type { Abi_NameWrapper } from "generated/abis/NameWrapper.ts";
import type { Abi_SimpleRegistryMetadata } from "generated/abis/SimpleRegistryMetadata.ts";
import type { Abi_VerifiableFactory } from "generated/abis/VerifiableFactory.ts";
import { Artifact_WrapperRegistry } from 'generated/artifacts/WrapperRegistry.js';

export default execute(
  async ({ deploy, get, getV1, namedAccounts: { deployer } }) => {
    const nameWrapper =
      await getV1<Abi_NameWrapper>("NameWrapper");

    const hcaFactory =
      get<Abi_MockHCAFactoryBasic>("HCAFactory");

    const registryMetadata = get<
      Abi_SimpleRegistryMetadata
    >("SimpleRegistryMetadata");

    const verifiableFactory =
      get<Abi_VerifiableFactory>("VerifiableFactory");

    const ensV1Resolver =
      get<Abi_ENSV1Resolver>("ENSV1Resolver");

    await deploy("WrapperRegistryImpl", {
      account: deployer,
      artifact: Artifact_WrapperRegistry,
      args: [
        nameWrapper.address,
        verifiableFactory.address,
        ensV1Resolver.address,
        hcaFactory.address,
        registryMetadata.address,
      ],
    });
  },
  {
    tags: ["WrapperRegistryImpl", "v2"],
    dependencies: [
      "NameWrapper",
      "HCAFactory",
      "SimpleRegistryMetadata",
      "VerifiableFactory",
      "ENSV1Resolver",
    ],
  },
);
