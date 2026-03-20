import { execute } from "@rocketh";
import { zeroAddress } from "viem";
import type { Abi_DefaultReverseRegistrar } from "../../generated/abis/DefaultReverseRegistrar.ts";
import type { Abi_ENSRegistry } from "../../generated/abis/ENSRegistry.ts";
import type { Abi_PermissionedRegistry } from "../../generated/abis/PermissionedRegistry.ts";
import { Artifact_ETHReverseResolver } from '../../generated/artifacts/ETHReverseResolver.ts';
import type { Artifact_ReverseRegistrar } from "../../generated/artifacts/ReverseRegistrar.ts";
import { DEPLOYMENT_ROLES, MAX_EXPIRY } from "../../script/deploy-constants.ts";

// TODO: ownership
export default execute(
  async ({ deploy, execute: write, get, getV1, getOrNull, namedAccounts: { deployer } }) => {
    const ensRegistryV1 =
      await getV1<Abi_ENSRegistry>("ENSRegistry");

    const defaultReverseRegistrarV1 = await getV1<
      Abi_DefaultReverseRegistrar
    >("DefaultReverseRegistrar");

    const reverseRegistry =
      getOrNull<Abi_PermissionedRegistry>("ReverseRegistry");

    if (!reverseRegistry) {
      console.warn('    - Skipping ETHReverseResolver deployment, ReverseRegistry not deployed (assumed not enabled).')
      return
    }

    const ethReverseRegistrar = get<
      (typeof Artifact_ReverseRegistrar)["abi"]
    >("ETHReverseRegistrar");

    // create resolver for "addr.reverse"
    const ethReverseResolver = await deploy("ETHReverseResolver", {
      account: deployer,
      artifact: Artifact_ETHReverseResolver,
      args: [
        ensRegistryV1.address,
        ethReverseRegistrar.address,
        defaultReverseRegistrarV1.address,
      ],
    });

    // register "addr.reverse"
    await write(reverseRegistry, {
      account: deployer,
      functionName: "register",
      args: [
        "addr",
        deployer,
        zeroAddress,
        ethReverseResolver.address,
        DEPLOYMENT_ROLES.REVERSE_AND_ADDR,
        MAX_EXPIRY,
      ],
    });
  },
  {
    tags: ["ETHReverseResolver", "v2"],
    dependencies: [
      "ENSRegistry",
      "ReverseRegistry", // "RootRegistry"
      "DefaultReverseRegistrar",
      "ETHReverseRegistrar",
    ],
  },
);
