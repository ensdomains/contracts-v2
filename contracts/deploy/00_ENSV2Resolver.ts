import { execute } from "@rocketh";
import type { Abi_ENSRegistry } from "generated/abis/ENSRegistry.ts";
import type { Abi_GatewayProvider } from "generated/abis/GatewayProvider.ts";
import type { Abi_OwnedResolver } from "generated/abis/OwnedResolver.ts";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.ts";
import type { Abi_RegistrarSecurityController } from "generated/abis/RegistrarSecurityController.ts";
import { Artifact_ENSV2Resolver } from 'generated/artifacts/ENSV2Resolver.js';
import { getAddress, namehash } from "viem";

export default execute(
  async ({
    get,
    getV1,
    deploy,
    execute: write,
    read,
    namedAccounts: { deployer, owner },
  }) => {
    const rootRegistry =
      get<Abi_PermissionedRegistry>("RootRegistry");

    const batchGatewayProvider = await getV1<Abi_GatewayProvider>(
      "BatchGatewayProvider",
    );

    const ensRegistry =
      await getV1<Abi_ENSRegistry>("ENSRegistry");

    const registrarSecurityController = await getV1<
      Abi_RegistrarSecurityController
    >("RegistrarSecurityController");

    console.log("Deploying ENSV2Resolver");
    console.log("  - Getting ENSv1 .eth resolver");
    const ethResolver = await getV1<Abi_OwnedResolver>('OwnedResolver')
    console.log(`  - Got: ${ethResolver.address}`);

    const ensV2Resolver = await deploy("ENSV2Resolver", {
      account: deployer,
      artifact: Artifact_ENSV2Resolver,
      args: [rootRegistry.address, batchGatewayProvider.address, ethResolver.address],
    });

    const currentResolver = await read(ensRegistry, {
      functionName: "resolver",
      args: [namehash("eth")],
    })

    if (currentResolver !== getAddress(ensV2Resolver.address)) {
      console.log("  - Setting ENSv1 .eth resolver to ENSV2Resolver");
      await write(registrarSecurityController, {
        account: owner,
        functionName: "setRegistrarResolver",
        args: [ensV2Resolver.address],
      });
    }
  },
  {
    tags: ["ENSV2Resolver", "v2"],
    dependencies: [
      "RootRegistry",
      "BatchGatewayProvider",
      "EthOwnedResolver", // BaseRegistrarImplementation:setup => eventually setup as OwnedResolver
      "RegistrarSecurityController",
    ],
  },
);
