import { artifacts, execute } from "@rocketh";
import { zeroAddress } from "viem";
import { dnsEncodeName } from "../../test/utils/utils.js";
import { MAX_EXPIRY } from "../../script/deploy-constants.js";

async function fetchPublicSuffixes() {
  const res = await fetch(
    "https://publicsuffix.org/list/public_suffix_list.dat",
    { headers: { Connection: "close" } },
  );
  if (!res.ok) throw new Error(`expected suffixes: ${res.status}`);
  return (await res.text())
    .split("\n")
    .map((x) => x.trim())
    .filter((x) => x && !x.startsWith("//"));
}

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    read,
    namedAccounts: { deployer },
    network,
  }) => {
    const ensRegistryV1 =
      get<(typeof artifacts.ENSRegistry)["abi"]>("ENSRegistry");

    const dnsTLDResolverV1 = get<(typeof artifacts.OffchainDNSResolver)["abi"]>(
      "OffchainDNSResolver",
    );

    const publicSuffixList = get<
      (typeof artifacts.SimplePublicSuffixList)["abi"]
    >("SimplePublicSuffixList");

    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const dnssecOracle = get<(typeof artifacts.DNSSEC)["abi"]>("DNSSECImpl");

    const batchGatewayProvider = get<(typeof artifacts.GatewayProvider)["abi"]>(
      "BatchGatewayProvider",
    );

    const dnssecGatewayProvider = get<
      (typeof artifacts.GatewayProvider)["abi"]
    >("DNSSECGatewayProvider");

    const dnsTLDResolver = await deploy("DNSTLDResolver", {
      account: deployer,
      artifact: artifacts.DNSTLDResolver,
      args: [
        ensRegistryV1.address,
        dnsTLDResolverV1.address,
        rootRegistry.address,
        dnssecOracle.address,
        dnssecGatewayProvider.address,
        batchGatewayProvider.address,
      ],
    });

    let suffixes = network.tags.local
      ? ["com", "org", "net", "xyz"]
      : await fetchPublicSuffixes();
    suffixes = (
      await Promise.all(
        suffixes.map((suffix) =>
          read(publicSuffixList, {
            functionName: "isPublicSuffix",
            args: [dnsEncodeName(suffix)],
          }).then((pub) => (pub ? suffix : "")),
        ),
      )
    ).filter(Boolean);

    // TODO: this create 1000+ transactions
    // batching is a mess in rocketh
    // anvil batching appears broken (only mines 1-2 tx)
    for (const suffix of suffixes) {
      await write(rootRegistry, {
        account: deployer,
        functionName: "register",
        args: [
          suffix,
          deployer, // TODO: ownership
          zeroAddress,
          dnsTLDResolver.address,
          0n, // TODO: roles
          MAX_EXPIRY,
        ],
      });
    }
  },
  {
    tags: ["DNSTLDResolver", "l1"],
    dependencies: [
      "RootRegistry",
      "OffchainDNSResolver", // "ENSRegistry" + "DNSSECImpl"
      "SimplePublicSuffixList",
      "BatchGatewayProvider",
      "DNSSECGatewayProvider",
    ],
  },
);
