import { execute } from "@rocketh";
import type { Abi_IPermissionedRegistry } from "generated/abis/IPermissionedRegistry.js";
import { Artifact_ReservedNameResolverUpdater } from "generated/artifacts/ReservedNameResolverUpdater.js";

// Deployed only by `phase rereserve-dns-tlds`, which points the root registry's
// reserved DNS top-level names at a new DNSTLDResolver. A fresh deployment reserves
// them with the current resolver from the start, so it never needs this contract,
// and local devnets, which run every deploy script, skip it.
export default execute(
  async ({ deploy, get, namedAccounts: { deployer }, tags }) => {
    if (tags.local) return;
    const rootRegistry = get<Abi_IPermissionedRegistry>("RootRegistry");
    const dnsTLDResolver = get("DNSTLDResolver");

    await deploy("ReservedNameResolverUpdater", {
      account: deployer,
      artifact: Artifact_ReservedNameResolverUpdater,
      args: [rootRegistry.address, dnsTLDResolver.address, deployer],
    });
  },
  {
    tags: ["ReservedNameResolverUpdater"],
  },
);
