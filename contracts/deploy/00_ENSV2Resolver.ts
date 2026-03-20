import { artifacts, execute } from "@rocketh";
import { namehash } from "viem";

export default execute(
  async ({
    get,
    deploy,
    execute: write,
    read,
    namedAccounts: { deployer, owner },
  }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const batchGatewayProvider = get<(typeof artifacts.GatewayProvider)["abi"]>(
      "BatchGatewayProvider",
    );

    const ensRegistry =
      get<(typeof artifacts.ENSRegistry)["abi"]>("ENSRegistry");

    const registrarSecurityController = get<
      (typeof artifacts.RegistrarSecurityController)["abi"]
    >("RegistrarSecurityController");

    console.log("Deploying ENSV2Resolver");
    console.log("  - Getting ENSv1 .eth resolver");
    const ethResolver = await read(ensRegistry, {
      functionName: "resolver",
      args: [namehash("eth")],
    });
    console.log(`  - Got: ${ethResolver}`);

    const ensV2Resolver = await deploy("ENSV2Resolver", {
      account: deployer,
      artifact: artifacts.ENSV2Resolver,
      args: [rootRegistry.address, batchGatewayProvider.address, ethResolver],
    });

    console.log("  - Setting ENSv1 .eth resolver to ENSV2Resolver");
    await write(registrarSecurityController, {
      account: owner,
      functionName: "setRegistrarResolver",
      args: [ensV2Resolver.address],
    });
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
