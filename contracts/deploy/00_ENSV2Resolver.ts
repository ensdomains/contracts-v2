import { artifacts, execute } from "@rocketh";
import { getAddress, namehash, zeroAddress } from "viem";

export default execute(
  async ({
    get,
    getOrNull,
    getV1,
    deploy,
    execute: write,
    read,
    namedAccounts: { deployer, owner, v1Owner },
  }) => {
    const batchGatewayProvider = await getV1<
      (typeof artifacts.GatewayProvider)["abi"]
    >(
      "BatchGatewayProvider",
    );

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const ensRegistry =
      await getV1<(typeof artifacts.ENSRegistry)["abi"]>("ENSRegistry");

    const registrarSecurityController = await getV1<
      (typeof artifacts.RegistrarSecurityController)["abi"]
    >("RegistrarSecurityController").catch(() => null);

    console.log("Deploying ENSV2Resolver");
    console.log("  - Getting ENSv1 .eth resolver");
    const currentResolver = await read(ensRegistry, {
      functionName: "resolver",
      args: [namehash("eth")],
    });
    const ethResolver = getAddress(currentResolver) === getAddress(zeroAddress)
      ? await getV1<(typeof artifacts.OwnedResolver)["abi"]>("OwnedResolver")
        .then((deployment) => deployment.address)
        .catch(() => currentResolver)
      : currentResolver;
    console.log(`  - Got: ${ethResolver}`);

    const existingEnsV2Resolver = getOrNull<
      (typeof artifacts.ENSV2Resolver)["abi"]
    >("ENSV2Resolver");
    const ensV2Resolver = existingEnsV2Resolver ?? await deploy("ENSV2Resolver", {
      account: deployer,
      artifact: artifacts.ENSV2Resolver,
      args: [
        batchGatewayProvider.address,
        contractNamer.address,
        rootRegistry.address,
        ethResolver,
      ],
    });

    if (getAddress(currentResolver) === getAddress(ensV2Resolver.address)) return;

    console.log("  - Setting ENSv1 .eth resolver to ENSV2Resolver");
    if (registrarSecurityController) {
      await write(registrarSecurityController, {
        account: v1Owner ?? owner,
        functionName: "setRegistrarResolver",
        args: [ensV2Resolver.address],
      });
    } else {
      const baseRegistrar = await getV1<
        (typeof artifacts.BaseRegistrarImplementation)["abi"]
      >("BaseRegistrarImplementation");
      await write(baseRegistrar, {
        account: v1Owner ?? owner,
        functionName: "setResolver",
        args: [ensV2Resolver.address],
      });
    }
  },
  {
    tags: ["ENSV2Resolver", "migration:phase1:deploy-v2", "v2"],
    dependencies: [
      "BatchGatewayProvider",
      "ContractNamer",
      "RootRegistry",
      "EthOwnedResolver", // BaseRegistrarImplementation:setup => eventually setup as OwnedResolver
      "RegistrarSecurityController",
    ],
  },
);
