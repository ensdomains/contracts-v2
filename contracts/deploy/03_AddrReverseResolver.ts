import { artifacts, execute } from "@rocketh";
import { zeroAddress } from "viem";
import { MAX_EXPIRY } from "../script/deploy-constants.js";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    namedAccounts: { deployer, owner },
  }) => {
    const ensRegistry =
      get<(typeof artifacts.ENSRegistry)["abi"]>("ENSRegistry");

    const defaultReverseRegistrar = get<
      (typeof artifacts.DefaultReverseRegistrar)["abi"]
    >("DefaultReverseRegistrar");

    const addrReverseRegistrar = get<
      (typeof artifacts.ReverseRegistrarHCAAdapter)["abi"]
    >("ReverseRegistrarHCAAdapter");

    const reverseRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ReverseRegistry");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const addrReverseResolver = await deploy("AddrReverseResolver", {
      account: deployer,
      artifact: artifacts.AddrReverseResolver,
      args: [
        ensRegistry.address,
        defaultReverseRegistrar.address,
        addrReverseRegistrar.address,
        contractNamer.address,
      ],
    });

    console.log("  - Reserving in parent");
    await write(reverseRegistry, {
      account: deployer,
      functionName: "register",
      args: [
        "addr",
        zeroAddress, // owner
        zeroAddress, // registry
        addrReverseResolver.address,
        0n,
        MAX_EXPIRY,
      ],
    });
  },
  {
    tags: ["AddrReverseResolver", "v2"],
    dependencies: [
      "ENSRegistry",
      "DefaultReverseRegistrar",
      "ReverseRegistrarHCAAdapter",
      "ReverseRegistry",
      "ContractNamer",
    ],
  },
);
