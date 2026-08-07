import { artifacts, execute } from "@rocketh";
import { isAddressEqual, labelhash, zeroAddress } from "viem";
import { DEPLOYMENT_ROLES, MAX_EXPIRY } from "../script/deploy-constants.js";

// TODO: ownership
export default execute(
  async ({ execute: write, get, read, namedAccounts: { deployer, owner } }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const ensV1Resolver =
      get<(typeof artifacts.ENSV1Resolver)["abi"]>("ENSV1Resolver");

    // Phase-tagged scripts re-run on every `deploy-v2 --resume`, and
    // registering an existing name reverts, so only register when the name
    // is absent (same guard as the eth registration in 01_ETHRegistry).
    const currentStatus = await read(rootRegistry, {
      functionName: "getStatus",
      args: [BigInt(labelhash("reverse"))],
    });

    if (currentStatus === 0) {
      console.log("  - Registering reverse in root");
      await write(rootRegistry, {
        account: deployer,
        functionName: "register",
        args: [
          "reverse",
          owner,
          zeroAddress,
          ensV1Resolver.address,
          DEPLOYMENT_ROLES.REVERSE_REGISTRY_ROOT,
          MAX_EXPIRY,
        ],
      });
      return;
    }

    // A resume can redeploy ENSV1Resolver, leaving reverse pointing at the
    // old one; repoint it so reverse resolution follows the live resolver.
    const currentResolver = await read(rootRegistry, {
      functionName: "getResolver",
      args: ["reverse"],
    });

    if (isAddressEqual(currentResolver, ensV1Resolver.address)) return;

    console.log("  - Updating reverse resolver to current ENSV1Resolver");
    const tokenId = await read(rootRegistry, {
      functionName: "findTokenId",
      args: ["reverse"],
    });
    // setResolver comes from `owner` — the name owner holds the full
    // REVERSE_REGISTRY_ROOT bitmap; `deployer` only has registrar rights.
    await write(rootRegistry, {
      account: owner,
      functionName: "setResolver",
      args: [tokenId, ensV1Resolver.address],
    });
  },
  {
    // The phase1 tag is required for live rotations: `phase deploy-v2` runs
    // only `migration:phase1:deploy-v2` scripts, and this is the sole script
    // that registers reverse on the root.
    tags: ["ReverseMirror", "migration:phase1:deploy-v2", "v2"],
    dependencies: ["RootRegistry", "ENSV1Resolver"],
  },
);
