import { artifacts, execute } from "@rocketh";
import { zeroAddress } from "viem";
import { DEPLOYMENT_ROLES, MAX_EXPIRY } from "../script/deploy-constants.js";

// TODO: ownership
export default execute(
  async ({ execute: write, get, namedAccounts: { deployer } }) => {
    const reverseRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ReverseRegistry");

    const ensV1Resolver =
      get<(typeof artifacts.ENSV1Resolver)["abi"]>("ENSV1Resolver");

    // register "addr.reverse"
    await write(reverseRegistry, {
      account: deployer,
      functionName: "register",
      args: [
        "addr",
        deployer,
        zeroAddress,
        ensV1Resolver.address,
        DEPLOYMENT_ROLES.REVERSE_AND_ADDR,
        MAX_EXPIRY,
      ],
    });
  },
  {
    tags: ["AddrReverseMirror", "v2"],
    dependencies: ["ReverseRegistry", "ENSV1Resolver"],
  },
);
