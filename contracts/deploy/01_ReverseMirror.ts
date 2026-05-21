import { artifacts, execute } from "@rocketh";
import { zeroAddress } from "viem";
import { DEPLOYMENT_ROLES, MAX_EXPIRY } from "../script/deploy-constants.js";

// TODO: ownership
export default execute(
  async ({ execute: write, get, namedAccounts: { deployer, owner } }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const ensV1Resolver =
      get<(typeof artifacts.ENSV1Resolver)["abi"]>("ENSV1Resolver");

    await write(rootRegistry, {
      account: deployer,
      functionName: "register",
      args: [
        "reverse",
        owner,
        zeroAddress,
        ensV1Resolver.address,
        DEPLOYMENT_ROLES.REVERSE_TOKEN,
        MAX_EXPIRY,
      ],
    });
  },
  {
    tags: ["ReverseMirror", "v2"],
    dependencies: ["RootRegistry", "SetupHCAFactory", "ENSV1Resolver"],
  },
);
