import { artifacts, execute } from "@rocketh";
import { zeroAddress } from "viem";
import { MAX_EXPIRY } from "../script/deploy-constants.js";

// TODO: ownership
export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const ensRegistryV1 =
      get<(typeof artifacts.ENSRegistry)["abi"]>("ENSRegistry");

    const defaultReverseRegistrarV1 = get<
      (typeof artifacts.DefaultReverseRegistrar)["abi"]
    >("DefaultReverseRegistrar");

    const reverseRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ReverseRegistry");

    const ethReverseRegistrar = get<
      (typeof artifacts['lib/ens-contracts/contracts/reverseRegistrar/L2ReverseRegistrar.sol/L2ReverseRegistrar'])["abi"]
    >("ETHReverseRegistrar");

    // create resolver for "addr.reverse"
    const ethReverseResolver = await deploy("ETHReverseResolver", {
      account: deployer,
      artifact: artifacts.ETHReverseResolver,
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
        0n,
        MAX_EXPIRY,
      ],
    });
  },
  {
    tags: ["ETHReverseResolver", "l1"],
    dependencies: [
      "ENSRegistry",
      "ReverseRegistry", // "RootRegistry"
      "DefaultReverseRegistrar",
      "ETHReverseRegistrar",
    ],
  },
);
