import { execute } from "@rocketh";
import { Abi_DNSTLDResolver } from "generated/abis/DNSTLDResolver.ts";
import type { Abi_IPermissionedRegistry } from "generated/abis/IPermissionedRegistry.js";
import type { Abi_PublicSuffixList } from "generated/abis/PublicSuffixList.js";
import { Artifact_TemporaryDNSRegistrar } from "generated/artifacts/TemporaryDNSRegistrar.js";

export default execute(
  async ({ get, getV1, deploy, namedAccounts: { deployer, owner }, tags }) => {
    const publicSuffixList = await getV1<Abi_PublicSuffixList>(
      "SimplePublicSuffixList",
    );
    const rootRegistry = get<Abi_IPermissionedRegistry>("RootRegistry");
    const dnsTLDResolver = get<Abi_DNSTLDResolver>("DNSTLDResolver");

    let tokenHolder = owner;
    if (tags.hasDao) {
      tokenHolder = "0x5B716D6587d241166bC8914858640F8684F3A2F3"; // dao token safe
    }

    await deploy("TemporaryDNSRegistrar", {
      account: deployer,
      artifact: Artifact_TemporaryDNSRegistrar,
      args: [
        owner,
        rootRegistry.address,
        tokenHolder,
        publicSuffixList.address,
        dnsTLDResolver.address,
      ],
    });
  },
  {
    tags: ["TemporaryDNSRegistrar", "v2"],
    dependencies: ["RootRegistry", "SimplePublicSuffixList", "DNSTLDResolver"],
  },
);
