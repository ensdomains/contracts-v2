import { artifacts, execute } from "@rocketh";
import { zeroAddress } from "viem";
import { ROLES } from "../../script/deploy-constants.js";

const PREMIGRATION_ROLE_BITMAP = ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW;

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    getV1,
    namedAccounts: { deployer },
    network,
    read,
    tags,
  }) => {
    if (
      network.chain.id === 1 ||
      (!tags.tenderly && !tags["testnet-premigration-registrar"])
    ) return;

    const baseRegistrar = await getV1<
      (typeof artifacts.BaseRegistrarImplementation)["abi"]
    >("BaseRegistrarImplementation");
    const ensRegistry =
      await getV1<(typeof artifacts.ENSRegistry)["abi"]>("ENSRegistry");
    const reverseRegistrar =
      await getV1<(typeof artifacts.ReverseRegistrar)["abi"]>(
        "ReverseRegistrar",
      );
    const defaultReverseRegistrar = await getV1<
      (typeof artifacts.DefaultReverseRegistrar)["abi"]
    >("DefaultReverseRegistrar");

    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");
    const ensV1Resolver =
      get<(typeof artifacts.ENSV1Resolver)["abi"]>("ENSV1Resolver");

    const registrar = await deploy("TestnetV1PremigrationRegistrar", {
      account: deployer,
      artifact: artifacts.TestnetV1PremigrationRegistrar,
      args: [
        baseRegistrar.address,
        ensRegistry.address,
        reverseRegistrar.address,
        defaultReverseRegistrar.address,
        ethRegistry.address,
        zeroAddress,
        ensV1Resolver.address,
      ],
    });

    const hasPremigrationRoles = await read(ethRegistry, {
      functionName: "hasRootRoles",
      args: [PREMIGRATION_ROLE_BITMAP, registrar.address],
    });
    if (!hasPremigrationRoles) {
      await write(ethRegistry, {
        account: deployer,
        functionName: "grantRootRoles",
        args: [PREMIGRATION_ROLE_BITMAP, registrar.address],
      });
    }
  },
  {
    tags: [
      "TestnetV1PremigrationRegistrar",
      "migration:phase1:deploy-v2",
      "migration:testnet:v1-premigration-registrar",
      "testnet",
    ],
    dependencies: [],
  },
);
