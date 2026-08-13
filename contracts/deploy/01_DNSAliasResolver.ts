import { execute } from "@rocketh";
import type { Abi_IPermissionedRegistry } from "generated/abis/IPermissionedRegistry.js";
import type { Abi_IGatewayProvider } from "generated/abis/IGatewayProvider.js";
import type { Abi_IENSIP15 } from "generated/abis/IENSIP15.js";
import type { Abi_IContractNamer } from "generated/abis/IContractNamer.js";
import { Artifact_DNSAliasResolver } from "generated/artifacts/DNSAliasResolver.js";

export default execute(
  async ({ deploy, get, getV1, namedAccounts: { deployer } }) => {
    const rootRegistry = get<Abi_IPermissionedRegistry>("RootRegistry");
    const batchGatewayProvider = await getV1<Abi_IGatewayProvider>(
      "BatchGatewayProvider",
    );
    const ensip15Proxy = get<Abi_IENSIP15>("MockENSIP15");
    const contractNamer = get<Abi_IContractNamer>("ContractNamer");

    await deploy("DNSAliasResolver", {
      account: deployer,
      artifact: Artifact_DNSAliasResolver,
      args: [
        rootRegistry.address,
        batchGatewayProvider.address,
        ensip15Proxy.address,
        contractNamer.address,
      ],
    });
  },
  {
    tags: ["DNSAliasResolver", "v2"],
    dependencies: [
      "RootRegistry",
      "BatchGatewayProvider",
      "MockENSIP15",
      "ContractNamer",
    ],
  },
);
