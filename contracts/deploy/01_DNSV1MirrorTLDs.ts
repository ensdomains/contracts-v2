import { execute } from "@rocketh";
import type { Abi_SimplePublicSuffixList } from "generated/abis/SimplePublicSuffixList.js";
import type { Abi_IPermissionedRegistry } from "generated/abis/IPermissionedRegistry.js";
import type { Abi_ENSV1Resolver } from "generated/abis/ENSV1Resolver.js";
import { Artifact_BatchRegistrar } from "generated/artifacts/BatchRegistrar.js";
import {
  fetchPublicSuffixes,
  filterAvailableSuffixes,
  registerSuffixesViaBatchRegistrar,
} from "../script/publicSuffixes.js";

function rootTLDs(suffixes: string[]) {
  return suffixes.filter(
    (suffix) =>
      !suffix.startsWith("!") &&
      !suffix.startsWith("*.") &&
      !suffix.includes("."),
  );
}

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    getV1,
    read,
    namedAccounts: { deployer },
    tags,
  }) => {
    const publicSuffixList = await getV1<Abi_SimplePublicSuffixList>(
      "SimplePublicSuffixList",
    );
    const rootRegistry = get<Abi_IPermissionedRegistry>("RootRegistry");
    const ensV1Resolver = get<Abi_ENSV1Resolver>("ENSV1Resolver");

    if (tags["clean-testnet"]) {
      console.warn("  - Skipping v1 mirror TLD registration on clean-testnet");
      return;
    }

    const candidates = tags.local
      ? ["com", "org", "net", "xyz"]
      : rootTLDs(await fetchPublicSuffixes());
    const suffixes = await filterAvailableSuffixes({
      read,
      publicSuffixList,
      rootRegistry,
      candidates,
    });

    if (suffixes.length === 0) {
      console.warn("  - No suffixes found");
      return;
    }

    const batchRegistrar = await deploy("DNSV1MirrorRootBatchRegistrar", {
      account: deployer,
      artifact: Artifact_BatchRegistrar,
      args: [rootRegistry.address, deployer],
    });

    await registerSuffixesViaBatchRegistrar({
      write,
      account: deployer,
      rootRegistry,
      batchRegistrar,
      resolver: ensV1Resolver.address,
      suffixes,
    });
  },
  {
    tags: ["DNSV1MirrorTLDs", "migration:phase1:deploy-v2"],
    dependencies: ["RootRegistry", "ENSV1Resolver", "SimplePublicSuffixList"],
  },
);
