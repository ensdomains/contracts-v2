import { execute } from "@rocketh";
import type { Abi_IPermissionedResolver } from "generated/abis/IPermissionedResolver.js";
import type { Abi_IGatewayProvider } from "generated/abis/IGatewayProvider.js";
import type { Abi_IENSIP15 } from "generated/abis/IENSIP15.js";
import type { Abi_IContractNamer } from "generated/abis/IContractNamer.js";
import { Artifact_UniversalResolverV2 } from "generated/artifacts/UniversalResolverV2.js";

export default execute(
  async ({ deploy, get, getV1, namedAccounts: { deployer } }) => {
    const rootRegistry = get<Abi_IPermissionedResolver>("RootRegistry");
    const batchGatewayProvider = await getV1<Abi_IGatewayProvider>(
      "BatchGatewayProvider",
    );
    const ensip15 = get<Abi_IENSIP15>("MockENSIP15");
    const contractNamer = get<Abi_IContractNamer>("ContractNamer");

    await deploy("UniversalResolverV2", {
      account: deployer,
      artifact: Artifact_UniversalResolverV2,
      args: [
        rootRegistry.address,
        batchGatewayProvider.address,
        ensip15.address,
        contractNamer.address,
      ],
    });
    return true;
  },
  {
    id: "universal-resolver:deploy-universal-resolver-implementation:v1",
    tags: [
      "UniversalResolverMigration",
      "migration:phase1:deploy-v2",
      "UniversalResolverImplementation",
      "UniversalResolverV2",
      "v2",
    ],
    dependencies: [
      "RootRegistry",
      "BatchGatewayProvider",
      "MockENSIP15",
      "ContractNamer",
      "ManagedUniversalResolverProxy",
    ],
  },
);
