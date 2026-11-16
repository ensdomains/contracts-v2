import { execute } from "@rocketh";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.js";
import type { Abi_IGatewayProvider } from "generated/abis/IGatewayProvider.js";
import type { Abi_IContractNamer } from "generated/abis/IContractNamer.js";
import { Artifact_CompositeHelper } from "generated/artifacts/CompositeHelper.js";

export default execute(
  async ({ get, getV1, deploy, namedAccounts: { deployer } }) => {
    const rootRegistry = get<Abi_PermissionedRegistry>("RootRegistry");
    const batchGatewayProvider = await getV1<Abi_IGatewayProvider>(
      "BatchGatewayProvider",
    );
    const contractNamer = get<Abi_IContractNamer>("ContractNamer");

    await deploy("CompositeHelper", {
      account: deployer,
      artifact: Artifact_CompositeHelper,
      args: [
        rootRegistry.address,
        batchGatewayProvider.address,
        contractNamer.address,
      ],
    });
  },
  {
    tags: ["CompositeHelper", "v2", "migration:phase1:deploy-v2"],
    dependencies: ["RootRegistry", "BatchGatewayProvider", "ContractNamer"],
  },
);
