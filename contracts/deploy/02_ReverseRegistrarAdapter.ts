import { execute } from "@rocketh";
import type { Abi_ReverseRegistrar } from "generated/abis/ReverseRegistrar.js";
import type { Abi_IContractNamer } from "generated/abis/IContractNamer.js";
import { Artifact_ReverseRegistrarAdapter } from "generated/artifacts/ReverseRegistrarAdapter.js";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    getV1,
    read,
    namedAccounts: { deployer, owner, v1Owner },
  }) => {
    const reverseRegistrar =
      await getV1<Abi_ReverseRegistrar>("ReverseRegistrar");
    const contractNamer = get<Abi_IContractNamer>("ContractNamer");

    const adapter = await deploy("ReverseRegistrarAdapter", {
      account: deployer,
      artifact: Artifact_ReverseRegistrarAdapter,
      args: [reverseRegistrar.address, contractNamer.address],
    });

    const adapterIsReverseController = await read(reverseRegistrar, {
      functionName: "controllers",
      args: [adapter.address],
    });

    if (!adapterIsReverseController) {
      // The v1 ReverseRegistrar is owned by the v1 owner, not the v2 admin, so
      // route the controller grant through v1Owner (honouring the deferred
      // v1-owner transaction flow, which only captures v1Owner sends).
      await write(reverseRegistrar, {
        account: v1Owner ?? owner,
        functionName: "setController",
        args: [adapter.address, true],
      });
    }
  },
  {
    tags: ["ReverseRegistrarAdapter", "migration:phase1:deploy-v2", "v2"],
    dependencies: ["ContractNamer"],
  },
);
