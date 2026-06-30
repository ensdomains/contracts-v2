import { artifacts, execute } from "@rocketh";
import {
  fetchPublicSuffixes,
  filterAvailableSuffixes,
  registerSuffixesViaBatchRegistrar,
} from "../script/publicSuffixes.js";

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
    const ensRegistry =
      await getV1<(typeof artifacts.ENSRegistry)["abi"]>("ENSRegistry");

    const dnsTLDResolverV1 = await getV1<
      (typeof artifacts.OffchainDNSResolver)["abi"]
    >("OffchainDNSResolver");

    const publicSuffixList = await getV1<
      (typeof artifacts.SimplePublicSuffixList)["abi"]
    >("SimplePublicSuffixList");

    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const dnssecOracle =
      await getV1<(typeof artifacts.DNSSECImpl)["abi"]>("DNSSECImpl");

    const batchGatewayProvider = await getV1<
      (typeof artifacts.GatewayProvider)["abi"]
    >("BatchGatewayProvider");

    const dnssecGatewayProvider = get<
      (typeof artifacts.GatewayProvider)["abi"]
    >("DNSSECGatewayProvider");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const dnsTLDResolver = await deploy("DNSTLDResolver", {
      account: deployer,
      artifact: artifacts.DNSTLDResolver,
      args: [
        ensRegistry.address,
        dnsTLDResolverV1.address,
        rootRegistry.address,
        dnssecOracle.address,
        dnssecGatewayProvider.address,
        batchGatewayProvider.address,
        contractNamer.address,
      ],
    });

    const candidates = tags.local
      ? ["com", "org", "net", "xyz"]
      : await fetchPublicSuffixes();
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

    const batchRegistrar = await deploy("RootBatchRegistrar", {
      account: deployer,
      artifact: artifacts.BatchRegistrar,
      args: [rootRegistry.address, deployer],
    });

    await registerSuffixesViaBatchRegistrar({
      write,
      account: deployer,
      rootRegistry,
      batchRegistrar,
      resolver: dnsTLDResolver.address,
      suffixes,
    });
  },
  {
    tags: ["DNSTLDResolver", "v2"],
    dependencies: [
      "RootRegistry",
      "ENSRegistry",
      "DNSSECImpl",
      "OffchainDNSResolver",
      "SimplePublicSuffixList",
      "BatchGatewayProvider",
      "DNSSECGatewayProvider",
      "ContractNamer",
      // Run the v1 root-TLD mirror first so it claims root TLDs for v1 fallback;
      // this resolver then registers only the remaining (non-root) public suffixes.
      "DNSV1MirrorTLDs",
    ],
  },
);
